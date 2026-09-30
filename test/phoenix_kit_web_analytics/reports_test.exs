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

  # ── engagement ──────────────────────────────────────────────────────────────

  describe "engagement/1" do
    test "exits count leave rows; avg time comes from their engaged_ms" do
      insert_event(%{path: "/a"})
      insert_event(%{event_type: "leave", path: "/a", engaged_ms: 1_000, scroll_depth: 50})
      insert_event(%{event_type: "leave", path: "/b", engaged_ms: 3_000, scroll_depth: 100})
      # A pageview's engaged_ms must not leak into the leave-only average.
      insert_event(%{path: "/b", engaged_ms: 90_000})

      result = Reports.engagement(Reports.filter(period: "7d"))

      assert result.exits == 2
      assert_in_delta result.avg_time_ms, 2_000.0, 0.01
      assert_in_delta result.avg_scroll, 75.0, 0.01
    end

    test "avg_scroll is nil when nothing recorded a scroll depth" do
      insert_event(%{event_type: "leave", engaged_ms: 500})

      result = Reports.engagement(Reports.filter(period: "7d"))

      assert result.exits == 1
      assert_in_delta result.avg_time_ms, 500.0, 0.01
      assert result.avg_scroll == nil
    end

    test "an empty window has zero exits and nil averages" do
      insert_event(%{path: "/only-a-pageview"})

      assert %{exits: 0, avg_time_ms: nil, avg_scroll: nil} =
               Reports.engagement(Reports.filter(period: "7d"))
    end
  end

  describe "exit_pages/2" do
    test "ranks paths by leave count, ignoring page views" do
      for _ <- 1..3, do: insert_event(%{event_type: "leave", path: "/pricing"})
      insert_event(%{event_type: "leave", path: "/"})
      # Many page views on "/" must not lift it above /pricing.
      for _ <- 1..5, do: insert_event(%{path: "/"})

      assert [%{label: "/pricing", pageviews: 3}, %{label: "/", pageviews: 1}] =
               Reports.exit_pages(Reports.filter(period: "7d"))
    end
  end

  describe "page_engagement/2" do
    test "maps each requested path to its engagement" do
      insert_event(%{event_type: "leave", path: "/a", engaged_ms: 2_000, scroll_depth: 40})
      insert_event(%{event_type: "leave", path: "/a", engaged_ms: 4_000, scroll_depth: 60})
      insert_event(%{event_type: "leave", path: "/b", engaged_ms: 1_000})
      insert_event(%{event_type: "leave", path: "/not-requested", engaged_ms: 1})

      result = Reports.page_engagement(Reports.filter(period: "7d"), ["/a", "/b", "/none"])

      assert Map.keys(result) |> Enum.sort() == ["/a", "/b"]
      assert result["/a"].exits == 2
      assert_in_delta result["/a"].avg_time_ms, 3_000.0, 0.01
      assert_in_delta result["/a"].avg_scroll, 50.0, 0.01
      assert result["/b"].avg_scroll == nil
    end

    test "paths with page views but no leave are absent" do
      insert_event(%{path: "/viewed"})

      assert Reports.page_engagement(Reports.filter(period: "7d"), ["/viewed"]) == %{}
    end

    # Regression, fixed in lib/phoenix_kit_web_analytics/reports.ex:465: the query
    # selects `event_type in ["leave", "interaction"]`, so a path that only has
    # an interaction (e.g. a click) appears with `exits: 0`, contradicting the
    # documented "Paths with no leave recorded are absent."
    test "paths with interactions but no leave are absent" do
      insert_event(%{event_type: "interaction", event_name: "click", path: "/clicked"})

      assert Reports.page_engagement(Reports.filter(period: "7d"), ["/clicked"]) == %{}
    end

    test "an empty path list returns an empty map" do
      insert_event(%{event_type: "leave", path: "/a", engaged_ms: 1})

      assert Reports.page_engagement(Reports.filter(period: "7d"), []) == %{}
    end
  end

  describe "top_interactions/2" do
    test "groups by name and target, excludes scroll, and labels rows" do
      for _ <- 1..2 do
        insert_event(%{
          event_type: "interaction",
          event_name: "outbound",
          target: "github.com/x"
        })
      end

      insert_event(%{event_type: "interaction", event_name: "outbound", target: "gitlab.com/y"})
      insert_event(%{event_type: "interaction", event_name: "add_to_cart"})
      insert_event(%{event_type: "interaction", event_name: "scroll", target: "75"})
      # Custom events are not interactions.
      insert_event(%{event_type: "event", event_name: "signup"})

      rows = Reports.top_interactions(Reports.filter(period: "7d"))

      assert [%{label: "outbound · github.com/x", pageviews: 2} | rest] = rows
      assert length(rows) == 3

      labels = Enum.map(rest, & &1.label) |> Enum.sort()
      assert labels == ["add_to_cart", "outbound · gitlab.com/y"]

      assert %{name: "add_to_cart", target: nil} = Enum.find(rest, &(&1.label == "add_to_cart"))
      refute Enum.any?(rows, &(&1.name in ["scroll", "signup"]))
    end
  end

  # ── sessions ────────────────────────────────────────────────────────────────

  describe "sessions/2" do
    test "one row per session with at least one page view" do
      s1 = UUIDv7.generate()
      leave_only = UUIDv7.generate()

      insert_event(%{session_id: s1, path: "/"})
      insert_event(%{session_id: leave_only, event_type: "leave", path: "/", engaged_ms: 10})

      assert [%{session_id: ^s1}] = Reports.sessions(Reports.filter(period: "7d"))
    end

    test "entry/exit paths, first-page source, and counts" do
      session = UUIDv7.generate()
      t0 = hours_ago(2)

      insert_event(%{
        session_id: session,
        path: "/landing",
        referrer_source: "Google",
        referrer_medium: "organic",
        inserted_at: t0
      })

      insert_event(%{
        session_id: session,
        path: "/middle",
        referrer_source: "Internal",
        referrer_medium: "internal",
        inserted_at: DateTime.add(t0, 30, :second)
      })

      insert_event(%{
        session_id: session,
        event_type: "interaction",
        event_name: "click",
        path: "/middle",
        inserted_at: DateTime.add(t0, 40, :second)
      })

      insert_event(%{
        session_id: session,
        event_type: "event",
        event_name: "signup",
        path: "/middle",
        inserted_at: DateTime.add(t0, 45, :second)
      })

      insert_event(%{
        session_id: session,
        path: "/checkout",
        referrer_medium: "internal",
        inserted_at: DateTime.add(t0, 60, :second)
      })

      # A later leave on another path must not become the exit path.
      insert_event(%{
        session_id: session,
        event_type: "leave",
        path: "/elsewhere",
        inserted_at: DateTime.add(t0, 90, :second)
      })

      assert [row] = Reports.sessions(Reports.filter(period: "7d"))

      assert row.entry_path == "/landing"
      assert row.exit_path == "/checkout"
      assert row.source == "Google"
      assert row.medium == "organic"
      assert row.pageviews == 3
      assert row.interactions == 2
      assert row.seconds == 90
    end

    test "seconds span every event type — a trailing leave counts" do
      session = UUIDv7.generate()
      t0 = hours_ago(1)

      insert_event(%{session_id: session, inserted_at: t0})

      insert_event(%{
        session_id: session,
        event_type: "leave",
        engaged_ms: 180_000,
        inserted_at: DateTime.add(t0, 180, :second)
      })

      assert [%{seconds: 180, pageviews: 1}] = Reports.sessions(Reports.filter(period: "7d"))
    end

    test "newest first, :limit and :before paging" do
      old = UUIDv7.generate()
      mid = UUIDv7.generate()
      new = UUIDv7.generate()

      insert_event(%{session_id: old, inserted_at: hours_ago(5)})
      insert_event(%{session_id: mid, inserted_at: hours_ago(3)})
      # `mid` continues after `new` starts — paging is by start, not end.
      insert_event(%{
        session_id: mid,
        inserted_at: DateTime.add(DateTime.utc_now(), -1800, :second)
      })

      insert_event(%{session_id: new, inserted_at: hours_ago(1)})

      filter = Reports.filter(period: "7d")

      assert Enum.map(Reports.sessions(filter), & &1.session_id) == [new, mid, old]
      assert Enum.map(Reports.sessions(filter, limit: 2), & &1.session_id) == [new, mid]

      assert Enum.map(Reports.sessions(filter, before: hours_ago(2)), & &1.session_id) ==
               [mid, old]

      assert Enum.map(Reports.sessions(filter, before: hours_ago(4)), & &1.session_id) == [old]
    end

    test ":user_uuid returns every session the user appears in, anonymous hits included" do
      user = UUIDv7.generate()
      theirs = UUIDv7.generate()
      also_theirs = UUIDv7.generate()
      someone_else = UUIDv7.generate()

      # Anonymous first page, then signed in within the same session.
      insert_event(%{session_id: theirs, path: "/anon", inserted_at: hours_ago(2)})
      insert_event(%{session_id: theirs, path: "/in", user_uuid: user, inserted_at: hours_ago(1)})
      insert_event(%{session_id: also_theirs, user_uuid: user, inserted_at: hours_ago(3)})
      insert_event(%{session_id: someone_else, user_uuid: UUIDv7.generate()})

      filter = Reports.filter(period: "7d")
      rows = Reports.sessions(filter, user_uuid: user)

      assert Enum.map(rows, & &1.session_id) == [theirs, also_theirs]

      theirs_row = Enum.find(rows, &(&1.session_id == theirs))
      assert theirs_row.pageviews == 2
      assert theirs_row.entry_path == "/anon"
      assert theirs_row.user_uuid == user
    end

    test ":user_uuid with an invalid uuid string returns nothing" do
      insert_event(%{user_uuid: UUIDv7.generate()})

      assert Reports.sessions(Reports.filter(period: "7d"), user_uuid: "not-a-uuid") == []
    end
  end

  describe "session_timeline/1" do
    test "returns the session's events oldest first, and only that session's" do
      session = UUIDv7.generate()

      insert_event(%{session_id: session, path: "/second", inserted_at: hours_ago(1)})
      insert_event(%{session_id: session, path: "/first", inserted_at: hours_ago(2)})

      insert_event(%{
        session_id: session,
        event_type: "leave",
        path: "/second",
        inserted_at: DateTime.add(DateTime.utc_now(), -1800, :second)
      })

      insert_event(%{path: "/other-session"})

      assert ["/first", "/second", "/second"] ==
               session |> Reports.session_timeline() |> Enum.map(& &1.path)

      assert List.last(Reports.session_timeline(session)).event_type == "leave"
    end

    test "[] for a non-UUID and for an unknown UUID" do
      insert_event(%{})

      assert Reports.session_timeline("nope") == []
      assert Reports.session_timeline("") == []
      assert Reports.session_timeline(UUIDv7.generate()) == []
    end
  end

  # ── bots ────────────────────────────────────────────────────────────────────

  describe "bot traffic" do
    setup do
      insert_event(%{path: "/human", visitor_id: "h"})
      insert_event(%{path: "/bot", visitor_id: "b", is_bot: true, device_type: "bot"})
      :ok
    end

    test "is excluded from overview, top_paths and sessions by default" do
      filter = Reports.filter(period: "7d")

      assert Reports.overview(filter).pageviews == 1
      assert Reports.overview(filter).visitors == 1
      assert [%{label: "/human"}] = Reports.top_paths(filter)
      assert [%{entry_path: "/human"}] = Reports.sessions(filter)
    end

    test "is included with bots: true" do
      filter = Reports.filter(period: "7d", bots: true)

      assert Reports.overview(filter).pageviews == 2
      assert Reports.overview(filter).visitors == 2

      assert filter |> Reports.top_paths() |> Enum.map(& &1.label) |> Enum.sort() == [
               "/bot",
               "/human"
             ]

      assert length(Reports.sessions(filter)) == 2
    end

    test "only a literal true opts in" do
      assert Reports.filter(period: "7d", bots: "true").bots == false
      assert Reports.overview(Reports.filter(period: "7d", bots: "true")).pageviews == 1
    end
  end

  describe "overview/1 session length" do
    test "includes a trailing leave, and a one-page session still bounces" do
      session = UUIDv7.generate()
      t0 = hours_ago(1)

      insert_event(%{session_id: session, inserted_at: t0})

      insert_event(%{
        session_id: session,
        event_type: "leave",
        inserted_at: DateTime.add(t0, 120, :second)
      })

      overview = Reports.overview(Reports.filter(period: "7d"))

      assert overview.sessions == 1
      assert overview.pageviews == 1
      assert_in_delta overview.avg_session_seconds, 120.0, 0.01
      assert overview.bounce_rate == 100.0
    end

    test "a session of only a leave is not a session" do
      insert_event(%{event_type: "leave"})

      overview = Reports.overview(Reports.filter(period: "7d"))

      assert overview.sessions == 0
      assert overview.avg_session_seconds == nil
    end
  end

  describe "active_visitors/2" do
    test "ignores leave rows" do
      insert_event(%{event_type: "leave", visitor_id: "leaver"})
      assert Reports.active_visitors(5) == 0

      insert_event(%{visitor_id: "viewer"})
      assert Reports.active_visitors(5) == 1
    end

    test "only counts the last `minutes`, and restricts by site" do
      insert_event(%{visitor_id: "stale", inserted_at: hours_ago(1)})
      insert_event(%{visitor_id: "fresh", site: "a.com"})
      insert_event(%{visitor_id: "fresh2", site: "b.com"})

      assert Reports.active_visitors(5) == 2
      assert Reports.active_visitors(5, "a.com") == 1
    end
  end

  describe "storage_stats/0 counts" do
    test "is exact and not estimated for a small table, and counts rollup days" do
      for _ <- 1..7, do: insert_event(%{})

      assert %{events: 7, events_estimated?: false, rollup_days: 0} = Reports.storage_stats()
    end

    test "an empty table reports zero and no oldest" do
      assert %{events: 0, events_estimated?: false, oldest: nil} = Reports.storage_stats()
    end
  end

  describe "timeseries/2 for all time" do
    test "monthly series starts at the oldest event's month, not 1970" do
      today = Date.utc_today()
      three_months_ago = Date.shift(today, month: -3)

      insert_event(%{inserted_at: DateTime.new!(three_months_ago, ~T[12:00:00], "Etc/UTC")})
      insert_event(%{})

      series = Reports.timeseries(Reports.filter(period: "all"), :month)

      assert [%{bucket: first, pageviews: 1} | _] = series
      assert DateTime.to_date(first) == Date.beginning_of_month(three_months_ago)
      assert length(series) == 4
      assert List.last(series).pageviews == 1
      assert DateTime.to_date(List.last(series).bucket) == Date.beginning_of_month(today)
    end

    test "with no data the series is short, never the 1970 backlog" do
      series = Reports.timeseries(Reports.filter(period: "all"), :month)

      assert length(series) <= 1
      assert Enum.all?(series, &(&1.pageviews == 0))
    end

    test "with no data mid-month the series is the current month only" do
      filter = Reports.filter(period: "all", now: ~U[2026-01-15 12:00:00Z])

      assert [%{pageviews: 0, bucket: ~U[2026-01-01 00:00:00Z]}] =
               Reports.timeseries(filter, :month)
    end

    # Regression, fixed in lib/phoenix_kit_web_analytics/reports.ex:915: with no
    # data, `first_month/1` falls back to `DateTime.to_date(filter.to)` — the
    # EXCLUSIVE end, i.e. tomorrow. On the last day of a month tomorrow is next
    # month, which is past `to_month`, so the series is `[]` instead of the
    # current month (one bucket on every other day of the month).
    test "with no data on the last day of a month the series is still the current month" do
      filter = Reports.filter(period: "all", now: ~U[2026-01-31 12:00:00Z])

      assert [%{pageviews: 0, bucket: ~U[2026-01-01 00:00:00Z]}] =
               Reports.timeseries(filter, :month)
    end
  end

  describe "recent_hits/2 event types" do
    test "filters to interaction and to leave" do
      insert_event(%{path: "/pv"})
      insert_event(%{event_type: "interaction", event_name: "click", path: "/i"})
      insert_event(%{event_type: "leave", path: "/l"})

      filter = Reports.filter(period: "7d")

      assert [%{path: "/i", event_type: "interaction"}] =
               Reports.recent_hits(filter, event_type: "interaction")

      assert [%{path: "/l", event_type: "leave"}] =
               Reports.recent_hits(filter, event_type: "leave")

      # An unknown type is ignored rather than matching nothing.
      assert length(Reports.recent_hits(filter, event_type: "bogus")) == 3
    end
  end

  describe "recent_sessions/2" do
    test "the most recently active visits first, a page at a time" do
      now = DateTime.utc_now()

      ids =
        for i <- 0..4 do
          id = UUIDv7.generate()

          insert_event(%{
            session_id: id,
            visitor_id: "r#{i}",
            inserted_at: DateTime.add(now, -i * 10, :second)
          })

          id
        end

      # An old visit outside the window never shows.
      insert_event(%{visitor_id: "old", inserted_at: DateTime.add(now, -3600, :second)})

      {first, cursor} = Reports.recent_sessions(5, limit: 2)
      assert Enum.map(first, & &1.session_id) == Enum.take(ids, 2)
      assert cursor

      {second, _} = Reports.recent_sessions(5, limit: 2, before: cursor)
      assert Enum.map(second, & &1.session_id) == Enum.slice(ids, 2, 2)

      {all, nil} = Reports.recent_sessions(5, limit: 50)
      assert length(all) == 5
    end
  end

  describe "sessions_page/2" do
    test "pages through visit starts and hands back the next cursor" do
      now = DateTime.utc_now()

      for i <- 0..2 do
        insert_event(%{visitor_id: "s#{i}", inserted_at: DateTime.add(now, -i * 60, :second)})
      end

      filter = Reports.filter(period: "today")
      {page, next} = Reports.sessions_page(filter, limit: 2)
      assert length(page) == 2
      assert %DateTime{} = next

      {rest, nil} = Reports.sessions_page(filter, limit: 2, before: next)
      assert length(rest) == 1
    end
  end

  describe "session_summary/1" do
    test "totals the whole visit, not just the rows a timeline page shows" do
      session = UUIDv7.generate()
      start = DateTime.add(DateTime.utc_now(), -120, :second)

      insert_event(%{session_id: session, visitor_id: "x", inserted_at: start})

      insert_event(%{
        session_id: session,
        visitor_id: "x",
        event_type: "interaction",
        event_name: "click",
        inserted_at: DateTime.add(start, 30, :second)
      })

      insert_event(%{
        session_id: session,
        visitor_id: "x",
        event_type: "leave",
        scroll_depth: 70,
        inserted_at: DateTime.add(start, 90, :second)
      })

      assert %{pageviews: 1, actions: 1, max_scroll: 70, seconds: 90} =
               Reports.session_summary(session)

      assert Reports.session_summary("not-a-uuid") == nil
    end
  end
end
