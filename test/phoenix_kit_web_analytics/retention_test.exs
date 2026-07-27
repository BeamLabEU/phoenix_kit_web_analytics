defmodule PhoenixKitWebAnalytics.RetentionTest do
  use PhoenixKitWebAnalytics.DataCase, async: false

  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Retention
  alias PhoenixKitWebAnalytics.Schemas.DailyStat
  alias PhoenixKitWebAnalytics.Schemas.Event

  describe "rollup_day/1" do
    test "aggregates one day into a single row per site" do
      date = Date.add(Date.utc_today(), -2)
      at = DateTime.new!(date, ~T[10:00:00], "Etc/UTC")
      session = UUIDv7.generate()

      insert_event(%{visitor_id: "a", session_id: session, path: "/", inserted_at: at})

      insert_event(%{
        visitor_id: "a",
        session_id: session,
        path: "/pricing",
        inserted_at: DateTime.add(at, 120, :second)
      })

      insert_event(%{visitor_id: "b", path: "/", inserted_at: at})
      insert_event(%{event_type: "event", event_name: "signup", inserted_at: at})

      assert :ok = Retention.rollup_day(date)

      assert [stat] = Repo.all(DailyStat)
      assert stat.date == date
      assert stat.site == "example.com"
      assert stat.pageviews == 3
      assert stat.visitors == 3
      assert stat.sessions == 2
      assert stat.bounces == 1
      assert stat.events == 1
      assert stat.total_session_seconds == 120
    end

    test "is idempotent — re-running replaces rather than duplicating" do
      date = Date.add(Date.utc_today(), -2)
      insert_event(%{inserted_at: DateTime.new!(date, ~T[10:00:00], "Etc/UTC")})

      assert :ok = Retention.rollup_day(date)
      assert :ok = Retention.rollup_day(date)

      assert Repo.aggregate(DailyStat, :count) == 1
    end
  end

  describe "rollup_pending_days/0" do
    test "rolls up completed days and leaves today alone" do
      insert_event(%{inserted_at: days_ago(2)})
      insert_event(%{inserted_at: days_ago(1)})
      insert_event(%{inserted_at: DateTime.utc_now()})

      assert Retention.rollup_pending_days() == 2

      dates = DailyStat |> Repo.all() |> Enum.map(& &1.date)

      refute Date.utc_today() in dates
      assert Date.add(Date.utc_today(), -1) in dates
    end

    test "a day already rolled up is not processed twice" do
      insert_event(%{inserted_at: days_ago(2)})

      assert Retention.rollup_pending_days() == 1
      assert Retention.rollup_pending_days() == 0
    end
  end

  describe "prune_old_events/0" do
    test "keeps everything when retention is 0" do
      enable_tracking(%{"web_analytics_retention_days" => "0"})
      insert_event(%{inserted_at: days_ago(400)})

      assert Retention.prune_old_events() == 0
      assert Repo.aggregate(Event, :count) == 1
    end

    test "deletes events past the horizon and keeps newer ones" do
      enable_tracking(%{"web_analytics_retention_days" => "30"})

      insert_event(%{inserted_at: days_ago(40)})
      insert_event(%{inserted_at: days_ago(35)})
      insert_event(%{inserted_at: days_ago(2)})

      # Roll up first: pruning never runs ahead of the aggregation that
      # preserves the trend line.
      Retention.rollup_pending_days()

      assert Retention.prune_old_events() == 2
      assert Repo.aggregate(Event, :count) == 1
    end

    test "does not delete days that have not been rolled up yet" do
      enable_tracking(%{"web_analytics_retention_days" => "30"})
      insert_event(%{inserted_at: days_ago(40)})

      assert Retention.prune_old_events() == 0
      assert Repo.aggregate(Event, :count) == 1
    end
  end

  describe "run/0" do
    test "rolls up and prunes in one pass, and the trend survives the prune" do
      enable_tracking(%{"web_analytics_retention_days" => "10"})

      old_day = days_ago(20)
      insert_event(%{inserted_at: old_day})
      insert_event(%{inserted_at: old_day})
      insert_event(%{inserted_at: days_ago(1)})

      # One pass does both: rollup runs first, which is what then allows the
      # prune in the same pass to touch the now-aggregated day.
      result = Retention.run()

      assert result.rolled_up == 2
      assert result.pruned == 2
      assert Repo.aggregate(Event, :count) == 1

      # The raw rows for the old day are gone, but its page views still appear
      # in the daily series via the rollup.
      series = Reports.daily_timeseries(Reports.filter(period: "30d"))
      old_date = DateTime.to_date(old_day)

      assert %{pageviews: 2, source: :rollup} =
               Enum.find(series, &(&1.date == old_date))
    end
  end
end
