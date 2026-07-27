defmodule PhoenixKitWebAnalytics.ReportsTest do
  use PhoenixKitWebAnalytics.DataCase, async: false

  alias PhoenixKitWebAnalytics.Reports

  describe "overview/1" do
    setup do
      # Two visitors: one bounces, one reads two pages in the same session.
      session = UUIDv7.generate()

      insert_event(%{visitor_id: "alice", session_id: session, path: "/", duration_ms: 10})

      insert_event(%{
        visitor_id: "alice",
        session_id: session,
        path: "/pricing",
        duration_ms: 30,
        inserted_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

      insert_event(%{visitor_id: "bob", path: "/", duration_ms: 20})

      %{filter: Reports.filter(period: "7d")}
    end

    test "counts page views, visitors, and sessions", %{filter: filter} do
      overview = Reports.overview(filter)

      assert overview.pageviews == 3
      assert overview.visitors == 2
      assert overview.sessions == 2
    end

    test "bounce rate counts single-page-view sessions", %{filter: filter} do
      assert Reports.overview(filter).bounce_rate == 50.0
    end

    test "average response time comes from the recorded durations", %{filter: filter} do
      assert_in_delta Reports.overview(filter).avg_response_ms, 20.0, 0.01
    end

    test "custom events are not counted as page views", %{filter: filter} do
      insert_event(%{event_type: "event", event_name: "signup", visitor_id: "alice"})

      overview = Reports.overview(filter)

      assert overview.pageviews == 3
      assert overview.events == 1
    end

    test "an empty window reports zeros, not nils" do
      overview = Reports.overview(Reports.filter(period: "yesterday"))

      assert overview.pageviews == 0
      assert overview.visitors == 0
      assert overview.sessions == 0
      assert overview.bounce_rate == nil
    end
  end

  describe "breakdowns" do
    setup do
      insert_event(%{path: "/", visitor_id: "a"})
      insert_event(%{path: "/", visitor_id: "b"})
      insert_event(%{path: "/pricing", visitor_id: "a"})

      insert_event(%{
        path: "/blog",
        visitor_id: "c",
        referrer_source: "Hacker News",
        referrer_medium: "social",
        browser: "Firefox",
        os: "Linux",
        device_type: "desktop",
        country_code: "EE"
      })

      %{filter: Reports.filter(period: "7d")}
    end

    test "top_paths/2 ranks by page views and reports distinct visitors", %{filter: filter} do
      assert [%{label: "/", pageviews: 2, visitors: 2} | rest] = Reports.top_paths(filter)
      assert length(rest) == 2
    end

    test "top_referrers/2 excludes direct and internal traffic", %{filter: filter} do
      assert [%{label: "Hacker News", pageviews: 1}] = Reports.top_referrers(filter)
    end

    test "browsers/2 labels missing values instead of dropping them", %{filter: filter} do
      labels = filter |> Reports.browsers() |> Enum.map(& &1.label)

      assert "Firefox" in labels
      assert "Unknown" in labels
    end

    test "countries/2 only includes hits that have a country", %{filter: filter} do
      assert [%{label: "EE", pageviews: 1}] = Reports.countries(filter)
    end

    test "the limit option is honoured and capped", %{filter: filter} do
      assert length(Reports.top_paths(filter, limit: 1)) == 1
      assert length(Reports.top_paths(filter, limit: 0)) <= 10
    end

    test "site filtering restricts every report", %{filter: _filter} do
      insert_event(%{path: "/other", site: "other.com"})

      assert [%{label: "/other"}] =
               Reports.filter(period: "7d", site: "other.com") |> Reports.top_paths()
    end
  end

  describe "timeseries/2" do
    test "fills empty buckets with zeros and keeps them in order" do
      insert_event(%{inserted_at: days_ago(2)})
      insert_event(%{inserted_at: days_ago(2)})

      series = Reports.timeseries(Reports.filter(period: "7d"), :day)

      assert length(series) == 7
      assert Enum.map(series, & &1.pageviews) |> Enum.sum() == 2

      buckets = Enum.map(series, & &1.bucket)
      assert buckets == Enum.sort(buckets, DateTime)
    end

    test "hourly buckets never run past the current hour" do
      insert_event(%{inserted_at: hours_ago(1)})

      series = Reports.timeseries(Reports.filter(period: "today"), :hour)
      now = DateTime.utc_now()

      assert Enum.all?(series, &(DateTime.compare(&1.bucket, now) != :gt))
    end
  end

  describe "recent_hits/2" do
    test "returns newest first and can filter by event type" do
      insert_event(%{path: "/old", inserted_at: hours_ago(3)})
      insert_event(%{path: "/new"})
      insert_event(%{event_type: "event", event_name: "signup"})

      filter = Reports.filter(period: "7d")

      assert [%{path: path} | _] = Reports.recent_hits(filter)
      assert path in ["/new", "/"]

      assert [%{event_name: "signup"}] = Reports.recent_hits(filter, event_type: "event")
      assert length(Reports.recent_hits(filter, event_type: "pageview")) == 2
    end
  end

  describe "storage_stats/0" do
    test "reports the stored row count and the oldest event" do
      insert_event(%{inserted_at: days_ago(3)})
      insert_event(%{})

      stats = Reports.storage_stats()

      assert stats.events == 2
      assert DateTime.to_date(stats.oldest) == Date.add(Date.utc_today(), -3)
    end
  end
end
