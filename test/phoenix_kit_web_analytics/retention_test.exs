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
      # A visitor is someone who viewed a page; the custom event's own
      # visitor hash doesn't count as a visit.
      assert stat.visitors == 2
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

  # ── watermark ───────────────────────────────────────────────────────────────

  defp yesterday, do: Date.add(Date.utc_today(), -1)
  defp date_ago(days), do: Date.add(Date.utc_today(), -days)

  defp set_watermark(%Date{} = date) do
    {:ok, _} =
      PhoenixKit.Settings.update_setting_with_module(
        "web_analytics_rolled_through",
        Date.to_iso8601(date),
        "web_analytics"
      )

    clear_settings_cache()
  end

  defp stat_dates, do: DailyStat |> Repo.all() |> Enum.map(& &1.date) |> Enum.sort(Date)

  describe "the watermark" do
    test "is nil before anything was rolled up" do
      assert Retention.rolled_through() == {:ok, nil}
    end

    test "reaches yesterday after rollup_pending_days/0" do
      insert_event(%{inserted_at: days_ago(3)})

      Retention.rollup_pending_days()

      assert Retention.rolled_through() == {:ok, yesterday()}
    end

    # REGRESSION: a backlog longer than two passes used to stop rolling.
    test "history longer than 120 days keeps rolling until yesterday" do
      event_days = Enum.to_list(200..10//-10) ++ [1]
      Enum.each(event_days, &insert_event(%{inserted_at: days_ago(&1)}))

      {passes, total} =
        Enum.reduce_while(1..10, {0, 0}, fn pass, {_passes, total} ->
          total = total + Retention.rollup_pending_days()

          if Retention.rolled_through() == {:ok, yesterday()},
            do: {:halt, {pass, total}},
            else: {:cont, {pass, total}}
        end)

      assert Retention.rolled_through() == {:ok, yesterday()}
      # 200 days at 60 per pass is four passes, not more.
      assert passes == 4
      assert total == length(event_days)

      expected = event_days |> Enum.map(&date_ago/1) |> Enum.sort(Date)
      assert stat_dates() == expected
      assert yesterday() in stat_dates()
    end

    test "a single pass handles at most 60 days" do
      insert_event(%{inserted_at: days_ago(100)})
      insert_event(%{inserted_at: days_ago(1)})

      assert Retention.rollup_pending_days() == 1
      assert Retention.rolled_through() == {:ok, date_ago(100 - 59)}
      refute yesterday() in stat_dates()
    end

    test "empty days advance the watermark but create no rows and aren't counted" do
      insert_event(%{inserted_at: days_ago(6)})
      insert_event(%{inserted_at: days_ago(3)})

      assert Retention.rollup_pending_days() == 2
      assert Retention.rolled_through() == {:ok, yesterday()}
      assert stat_dates() == [date_ago(6), date_ago(3)]
    end

    test "a stored watermark is resumed from, not recomputed from the oldest event" do
      insert_event(%{inserted_at: days_ago(10)})
      insert_event(%{inserted_at: days_ago(4)})
      set_watermark(date_ago(5))

      assert Retention.rollup_pending_days() == 1
      assert stat_dates() == [date_ago(4)]
    end
  end

  describe "prune and the watermark" do
    test "never deletes past the watermark, and does once it has been rolled up" do
      enable_tracking(%{"web_analytics_retention_days" => "30"})
      insert_event(%{inserted_at: days_ago(40)})
      set_watermark(date_ago(45))

      assert Retention.prune_old_events() == 0
      assert Repo.aggregate(Event, :count) == 1

      Retention.rollup_pending_days()

      assert Retention.prune_old_events() == 1
      assert Repo.aggregate(Event, :count) == 0
      assert [_] = Repo.all(DailyStat)
    end

    test "does nothing when the watermark was never written, even if a rollup row exists" do
      enable_tracking(%{"web_analytics_retention_days" => "30"})
      insert_event(%{inserted_at: days_ago(40)})
      # The day's aggregate exists, but no watermark says the chain is complete.
      assert :ok = Retention.rollup_day(date_ago(40))

      assert Retention.rolled_through() == {:ok, nil}
      assert Retention.prune_old_events() == 0
      assert Repo.aggregate(Event, :count) == 1
    end

    test "an unparseable watermark deletes nothing" do
      enable_tracking(%{"web_analytics_retention_days" => "30"})
      insert_event(%{inserted_at: days_ago(40)})

      {:ok, _} =
        PhoenixKit.Settings.update_setting_with_module(
          "web_analytics_rolled_through",
          "garbage",
          "web_analytics"
        )

      clear_settings_cache()

      assert Retention.rolled_through() == {:ok, nil}
      assert Retention.prune_old_events() == 0
      assert Repo.aggregate(Event, :count) == 1
    end
  end

  describe "re-rolling recent days" do
    test "a late event in yesterday is picked up by the next pass" do
      insert_event(%{inserted_at: days_ago(2)})
      insert_event(%{inserted_at: days_ago(1)})

      assert Retention.rollup_pending_days() == 2
      assert %{pageviews: 1} = Repo.get_by!(DailyStat, date: yesterday())

      # A hit written as midnight passed lands in yesterday after its rollup.
      insert_event(%{inserted_at: days_ago(1)})

      assert Retention.rollup_pending_days() == 0
      assert %{pageviews: 2} = Repo.get_by!(DailyStat, date: yesterday())
    end

    # Regression, fixed in lib/phoenix_kit_web_analytics/retention.ex:280-285:
    # `reroll_recent/2` only re-rolls days that already have a DailyStat row
    # (`day_has_rows?/1`). If yesterday had no traffic when it was first rolled
    # up, a late hit that lands in it afterwards is never aggregated, and the
    # watermark is already past it — so the day stays missing from the trend
    # line and its raw row is later pruned without a rollup.
    test "a late event in a previously empty yesterday is picked up by the next pass" do
      insert_event(%{inserted_at: days_ago(2)})

      assert Retention.rollup_pending_days() == 1
      assert Retention.rolled_through() == {:ok, yesterday()}
      refute yesterday() in stat_dates()

      insert_event(%{inserted_at: days_ago(1)})
      Retention.rollup_pending_days()

      assert %{pageviews: 1} = Repo.get_by!(DailyStat, date: yesterday())
    end
  end

  describe "rollup_day/1 counting rules" do
    setup do
      date = Date.add(Date.utc_today(), -2)
      %{date: date, at: DateTime.new!(date, ~T[10:00:00], "Etc/UTC")}
    end

    test "visitors are counted among page views only", %{date: date, at: at} do
      insert_event(%{visitor_id: "viewer", inserted_at: at})

      insert_event(%{
        visitor_id: "clicker",
        event_type: "interaction",
        event_name: "click",
        inserted_at: at
      })

      insert_event(%{visitor_id: "leaver", event_type: "leave", inserted_at: at})

      assert :ok = Retention.rollup_day(date)
      assert %{visitors: 1, pageviews: 1, events: 0} = Repo.one!(DailyStat)
    end

    test "a session made only of events is not a session", %{date: date, at: at} do
      insert_event(%{inserted_at: at})

      events_only = UUIDv7.generate()

      insert_event(%{
        session_id: events_only,
        event_type: "event",
        event_name: "signup",
        inserted_at: at
      })

      insert_event(%{
        session_id: events_only,
        event_type: "event",
        event_name: "purchase",
        inserted_at: DateTime.add(at, 600, :second)
      })

      assert :ok = Retention.rollup_day(date)

      stat = Repo.one!(DailyStat)
      assert stat.sessions == 1
      assert stat.bounces == 1
      assert stat.events == 2
      # The event-only session's 600 seconds must not be counted.
      assert stat.total_session_seconds == 0
    end

    test "session seconds include a trailing leave", %{date: date, at: at} do
      session = UUIDv7.generate()
      insert_event(%{session_id: session, inserted_at: at})

      insert_event(%{
        session_id: session,
        event_type: "leave",
        engaged_ms: 180_000,
        inserted_at: DateTime.add(at, 180, :second)
      })

      assert :ok = Retention.rollup_day(date)

      assert %{sessions: 1, bounces: 1, total_session_seconds: 180, pageviews: 1} =
               Repo.one!(DailyStat)
    end

    test "only that UTC day's events are counted", %{date: date} do
      insert_event(%{inserted_at: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")})
      insert_event(%{inserted_at: DateTime.new!(date, ~T[23:59:59], "Etc/UTC")})
      insert_event(%{inserted_at: DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")})

      assert :ok = Retention.rollup_day(date)
      assert %{pageviews: 2} = Repo.one!(DailyStat)
    end
  end

  describe "the GenServer" do
    test "an unknown message is ignored without crashing" do
      assert {:noreply, %{some: :state}} = Retention.handle_info(:unexpected, %{some: :state})
      assert {:noreply, %{}} = Retention.handle_info({:weird, make_ref()}, %{})
    end

    test "a running process survives an unknown message" do
      pid =
        case Process.whereis(Retention) do
          nil -> start_supervised!(Retention)
          pid -> pid
        end

      send(pid, :unexpected)
      # A synchronous probe: :sys.get_state returns only after the message
      # above has been handled.
      assert :sys.get_state(pid) == %{}
      assert Process.alive?(pid)
    end
  end
end
