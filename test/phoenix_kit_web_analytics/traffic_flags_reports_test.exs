defmodule PhoenixKitWebAnalytics.TrafficFlagsReportsTest do
  @moduledoc """
  Reading with the site's own traffic left out: rollups hold only unflagged
  hits, the default report leaves flagged hits out (from rollups), and
  counting any flag in — by a setting or by the report's switch — reads raw
  events. The visit lists and "Right now" leave them out too.
  """

  use PhoenixKitWebAnalytics.DataCase, async: false

  alias PhoenixKitWebAnalytics.LivePresence
  alias PhoenixKitWebAnalytics.ReportCache
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Retention
  alias PhoenixKitWebAnalytics.RollupReader
  alias PhoenixKitWebAnalytics.Schemas.DailyStat

  # Per finished day (3 days ago … yesterday) and today: one ordinary visit,
  # one staff visit (2), one from an internal network (1), one staff visit
  # from an internal network (3) and one from a staff network (4).
  @kinds [clean: 0, admin: 2, internal: 1, both: 3, admin_network: 4]

  setup do
    enable_tracking()

    for day <- 0..3, {kind, flags} <- @kinds do
      at = DateTime.new!(Date.add(Date.utc_today(), -day), ~T[00:10:00], "Etc/UTC")
      session = UUIDv7.generate()
      base = %{visitor_id: "#{kind}-#{day}", session_id: session, traffic_flags: flags}

      insert_event(Map.merge(base, %{path: "/#{kind}", inserted_at: at}))
      insert_event(Map.merge(base, %{path: "/#{kind}/2", inserted_at: DateTime.add(at, 30)}))
    end

    :ok
  end

  defp pageviews(filter), do: Reports.overview(filter).pageviews

  describe "rollups" do
    test "hold only unflagged traffic" do
      assert Retention.rollup_pending_days() > 0

      assert Repo.aggregate(DailyStat, :sum, :pageviews) == 3 * 2
    end

    test "a default report reads them and leaves flagged traffic out of today too" do
      Retention.rollup_pending_days()
      filter = Reports.filter(period: "7d")

      assert filter.excluded_flags == 7
      assert RollupReader.plan(filter).dates != nil
      assert pageviews(filter) == 4 * 2

      assert Enum.map(Reports.top_paths(filter), & &1.label) |> Enum.sort() == [
               "/clean",
               "/clean/2"
             ]
    end
  end

  describe "counting flagged traffic in" do
    setup do
      Retention.rollup_pending_days()
      :ok
    end

    test "the report's switch shows everything, read raw" do
      filter = Reports.filter(period: "7d", flagged: true)

      assert filter.excluded_flags == 0
      assert RollupReader.plan(filter).dates == nil
      assert pageviews(filter) == 4 * 5 * 2
    end

    test "a setting counting one flag in reads raw and counts that flag only" do
      enable_tracking(%{"web_analytics_exclude_admin" => "false"})
      filter = Reports.filter(period: "7d")

      assert filter.excluded_flags == 5
      assert RollupReader.plan(filter).dates == nil
      # clean + admin-only; "both" still carries the internal bit.
      assert pageviews(filter) == 4 * 2 * 2
    end

    test "bots and flagged traffic switch separately" do
      insert_event(%{visitor_id: "bot", is_bot: true, path: "/", inserted_at: hours_ago(1)})

      assert pageviews(Reports.filter(period: "7d", bots: true)) == 4 * 2 + 1
      assert pageviews(Reports.filter(period: "7d", flagged: true)) == 4 * 5 * 2
      assert pageviews(Reports.filter(period: "7d", flagged: true, bots: true)) == 4 * 5 * 2 + 1
    end

    test "a cached report is keyed by the mask" do
      Application.put_env(:phoenix_kit_web_analytics, :report_cache_ms, 30_000)
      on_exit(fn -> Application.put_env(:phoenix_kit_web_analytics, :report_cache_ms, 0) end)
      start_supervised!(ReportCache)

      assert pageviews(Reports.filter(period: "7d")) == 8
      assert pageviews(Reports.filter(period: "7d", flagged: true)) == 40
    end
  end

  describe "visit lists" do
    test "the visits list leaves flagged visits out unless asked" do
      labels = fn filter ->
        filter |> Reports.sessions() |> Enum.map(& &1.entry_path) |> Enum.uniq()
      end

      assert labels.(Reports.filter(period: "7d")) == ["/clean"]

      assert labels.(Reports.filter(period: "7d", flagged: true)) |> Enum.sort() ==
               Enum.sort(for {kind, _} <- @kinds, do: "/#{kind}")
    end

    test "recent visits leave flagged visits out by default" do
      {recent, _} = Reports.recent_sessions(60 * 24)
      assert Enum.map(recent, & &1.entry_path) == ["/clean"]

      {all, _} = Reports.recent_sessions(60 * 24, excluded_flags: 0)
      assert length(all) == 5

      {admin_too, _} = Reports.recent_sessions(60 * 24, excluded_flags: 5)
      assert Enum.map(admin_too, & &1.entry_path) |> Enum.sort() == ["/admin", "/clean"]
    end

    test "a flagged visit doesn't take a clean visit's place on a page" do
      insert_event(%{visitor_id: "clean-now", path: "/clean-now", inserted_at: hours_ago(0)})
      insert_event(%{visitor_id: "staff-now", traffic_flags: 2, inserted_at: DateTime.utc_now()})

      assert {[%{entry_path: "/clean-now"}], _next} = Reports.recent_sessions(60, limit: 1)
    end

    test "the active visitor count leaves them out" do
      insert_event(%{visitor_id: "now-clean", inserted_at: DateTime.utc_now()})
      insert_event(%{visitor_id: "now-admin", traffic_flags: 2, inserted_at: DateTime.utc_now()})

      assert Reports.active_visitors(5) == 1
      assert Reports.active_visitors(5, nil, 0) == 2
    end

    test "a visit's own summary names its flags" do
      [%{session_id: id}] =
        Reports.recent_sessions(60 * 24, excluded_flags: 0)
        |> elem(0)
        |> Enum.filter(&(&1.entry_path == "/both"))

      assert Reports.session_summary(id).traffic_flags == 3
    end
  end

  describe "right now" do
    @client %{ip: {203, 0, 113, 9}, user_agent: "Mozilla/5.0 Chrome/141.0", language: nil}

    setup do
      start_supervised!(LivePresence)
      :ok
    end

    defp open_page(path, flags) do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      LivePresence.watch(pid, @client, %{path: path, site: "example.com", flags: flags})
      :sys.get_state(LivePresence)
      pid
    end

    test "open pages leave out the masked flags" do
      open_page("/a", 0)
      open_page("/a", 2)
      open_page("/b", 4)
      open_page("/b", 1)

      assert LivePresence.count(nil) == 4
      assert LivePresence.count(nil, 7) == 1
      assert LivePresence.count(nil, 5) == 2
      assert LivePresence.count("example.com", 7) == 1

      {visits, nil} = LivePresence.page(mask: 7)
      assert Enum.map(visits, & &1.flags) == [0]
      {visits, nil} = LivePresence.page(mask: 0)
      assert length(visits) == 4

      assert LivePresence.by_path(10, 7) == [{"/a", 1}]
      assert LivePresence.by_path(10, 2) == [{"/b", 2}, {"/a", 1}]
      assert LivePresence.by_path(10) == [{"/b", 2}, {"/a", 2}]
    end

    test "pages past the masked ones" do
      for _ <- 1..3, do: open_page("/x", 0)
      open_page("/staff", 2)

      {first, cursor} = LivePresence.page(limit: 2, mask: 7)
      assert length(first) == 2 and cursor
      {second, nil} = LivePresence.page(limit: 2, mask: 7, after: cursor)
      assert Enum.map(second, & &1.path) == ["/x"]
    end

    test "a closed flagged page leaves no count behind" do
      pid = open_page("/a", 2)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      wait_until(fn -> LivePresence.count(nil, 0) == 0 end)

      assert LivePresence.count(nil, 0) == 0
      assert LivePresence.count(nil, 7) == 0
      assert :ets.tab2list(:phoenix_kit_web_analytics_live_presence_flagged) == []
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts > 0 -> Process.sleep(10) && wait_until(fun, attempts - 1)
      true -> :timeout
    end
  end
end
