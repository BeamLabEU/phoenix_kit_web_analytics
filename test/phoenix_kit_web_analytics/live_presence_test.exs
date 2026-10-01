defmodule PhoenixKitWebAnalytics.LivePresenceTest do
  @moduledoc """
  `PhoenixKitWebAnalytics.LivePresence`: the "on the site now" table and the
  leave events it records when a watched LiveView process ends or patches to
  another path.

  The leave is written from the presence server's own process; the sandbox is
  shared (non-async), so it lands on the test's connection.
  """

  use PhoenixKitWebAnalytics.DataCase, async: false

  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.LivePresence
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Test.Repo

  @ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36"
  @client %{ip: {1, 2, 3, 4}, user_agent: @ua, language: nil}

  describe "with the server running" do
    setup do
      enable_tracking()
      server = start_supervised!(LivePresence)
      {:ok, server: server}
    end

    test "watch/3 lists the page with its path, site and client" do
      pid = spawn_page()
      LivePresence.watch(pid, @client, %{path: "/pricing", site: "example.com"})

      wait_until(fn -> LivePresence.count(nil) == 1 end)

      assert LivePresence.running?()
      assert [visit] = LivePresence.list()
      assert visit.pid == pid
      assert visit.path == "/pricing"
      assert visit.site == "example.com"
      assert visit.browser == "Chrome"
      assert visit.os == "macOS"
      assert visit.device_type == "desktop"

      assert LivePresence.count("example.com") == 1
      assert [_] = LivePresence.list("example.com")
      assert LivePresence.list("other.site") == []
      assert LivePresence.count("other.site") == 0
    end

    test "the process ending records a leave with the time spent, and drops the row" do
      pid = spawn_page()
      started = System.monotonic_time(:millisecond)
      LivePresence.watch(pid, @client, %{path: "/pricing", site: "example.com"})
      wait_until(fn -> LivePresence.count(nil) == 1 end)

      Process.sleep(50)
      Process.exit(pid, :kill)
      elapsed = System.monotonic_time(:millisecond) - started

      leave = wait_for_leave("/pricing")
      assert leave.site == "example.com"
      assert leave.metadata["source"] == "live_presence"
      assert leave.engaged_ms >= 50
      assert leave.engaged_ms <= elapsed + 1_000

      wait_until(fn -> LivePresence.list() == [] end)
      assert LivePresence.count(nil) == 0
    end

    test "navigate/2 to a new path records a leave for the old one and moves the row" do
      pid = spawn_page()
      LivePresence.watch(pid, @client, %{path: "/a", site: "example.com"})
      wait_until(fn -> LivePresence.count(nil) == 1 end)

      LivePresence.navigate(pid, "/b")

      assert wait_for_leave("/a").path == "/a"
      # The leave is written before the row moves; let the cast finish.
      _ = :sys.get_state(LivePresence)
      assert [%{path: "/b"}] = LivePresence.list()
      assert leaves() |> Enum.map(& &1.path) == ["/a"]
    end

    test "navigate/2 to the same path records nothing", %{server: server} do
      pid = spawn_page()
      LivePresence.watch(pid, @client, %{path: "/a", site: "example.com"})
      wait_until(fn -> LivePresence.count(nil) == 1 end)

      LivePresence.navigate(pid, "/a")
      # A synchronous call behind the cast: once it returns, the cast is done.
      _ = :sys.get_state(server)

      assert leaves() == []
      assert [%{path: "/a"}] = LivePresence.list()
    end

    test "a leave joins the session its page view opened, even past the inactivity window",
         %{server: server} do
      opened = DateTime.add(DateTime.utc_now(), -45 * 60, :second)

      {:ok, pageview} =
        Collector.track(%{
          path: "/long-read",
          site: "example.com",
          ip: @client.ip,
          user_agent: @ua,
          inserted_at: opened
        })

      # `watch/3` stamps "now"; the cast is sent directly so the page can have
      # been opened 45 minutes ago — longer than the 30-minute session window.
      pid = spawn_page()

      GenServer.cast(
        server,
        {:watch, pid, @client, %{path: "/long-read", site: "example.com"}, opened}
      )

      _ = :sys.get_state(server)
      Process.exit(pid, :kill)

      leave = wait_for_leave("/long-read")
      assert leave.session_id == pageview.session_id
      assert leave.visitor_id == pageview.visitor_id
    end

    test "a single reading is capped at max_engaged_ms/0", %{server: server} do
      opened = DateTime.add(DateTime.utc_now(), -5 * 60 * 60, :second)
      pid = spawn_page()

      GenServer.cast(
        server,
        {:watch, pid, @client, %{path: "/forgotten", site: "example.com"}, opened}
      )

      _ = :sys.get_state(server)
      Process.exit(pid, :kill)

      assert wait_for_leave("/forgotten").engaged_ms == LivePresence.max_engaged_ms()
      assert LivePresence.max_engaged_ms() == 4 * 60 * 60 * 1000
    end

    test "an unknown message doesn't crash the server", %{server: server} do
      send(server, :garbage)
      send(server, {:DOWN, make_ref(), :process, self(), :normal})
      _ = :sys.get_state(server)

      assert Process.alive?(server)
      assert Process.whereis(LivePresence) == server
      assert leaves() == []
    end
  end

  describe "paging (a busy site)" do
    setup do
      enable_tracking()
      start_supervised!(LivePresence)
      :ok
    end

    test "page/1 returns the newest pages first, a page at a time, with a cursor" do
      pids =
        for i <- 1..5 do
          pid = spawn_page()
          LivePresence.watch(pid, @client, %{path: "/p#{i}", site: "example.com"})
          # Distinct start times, so the order is defined.
          wait_until(fn -> LivePresence.count(nil) == i end)
          Process.sleep(2)
          pid
        end

      {first, cursor} = LivePresence.page(limit: 2)
      assert Enum.map(first, & &1.path) == ["/p5", "/p4"]
      assert cursor

      {second, cursor} = LivePresence.page(limit: 2, after: cursor)
      assert Enum.map(second, & &1.path) == ["/p3", "/p2"]

      {third, cursor} = LivePresence.page(limit: 2, after: cursor)
      assert Enum.map(third, & &1.path) == ["/p1"]
      assert cursor == nil

      Enum.each(pids, &Process.exit(&1, :kill))
    end

    test "by_path/1 keeps only the most open paths when there are more than the limit" do
      pages =
        for {path, n} <- [{"/one", 1}, {"/five", 5}, {"/three", 3}, {"/two", 2}, {"/four", 4}],
            _ <- 1..n do
          pid = spawn_page()
          LivePresence.watch(pid, @client, %{path: path, site: "example.com"})
          pid
        end

      wait_until(fn -> LivePresence.count(nil) == 15 end)

      assert LivePresence.by_path(3) == [{"/five", 5}, {"/four", 4}, {"/three", 3}]

      Enum.each(pages, &Process.exit(&1, :kill))
    end

    test "by_path/1 counts open pages per path, following navigation and exits" do
      a = spawn_page()
      b = spawn_page()
      c = spawn_page()
      LivePresence.watch(a, @client, %{path: "/pricing", site: "example.com"})
      LivePresence.watch(b, @client, %{path: "/pricing", site: "example.com"})
      LivePresence.watch(c, @client, %{path: "/blog", site: "example.com"})
      wait_until(fn -> LivePresence.count(nil) == 3 end)

      assert LivePresence.by_path(10) == [{"/pricing", 2}, {"/blog", 1}]

      LivePresence.navigate(b, "/blog")
      _ = :sys.get_state(LivePresence)
      assert Enum.sort(LivePresence.by_path(10)) == [{"/blog", 2}, {"/pricing", 1}]

      Process.exit(a, :kill)
      wait_until(fn -> LivePresence.count(nil) == 2 end)
      assert LivePresence.by_path(10) == [{"/blog", 2}]
    end
  end

  describe "reconnects (found in review)" do
    setup do
      enable_tracking()
      Application.put_env(:phoenix_kit_web_analytics, :presence_reconnect_grace_ms, 300)

      on_exit(fn ->
        Application.put_env(:phoenix_kit_web_analytics, :presence_reconnect_grace_ms, 0)
      end)

      start_supervised!(LivePresence)
      :ok
    end

    # A dropped connection ends the LiveView process and the client rejoins
    # with a new one. That used to record a leave for the old process and,
    # later, another for the new one — two exits for one view.
    test "a rejoin of the same page within the grace period is one view, one leave" do
      first = spawn_page()
      LivePresence.watch(first, @client, %{path: "/pricing", site: "example.com"})
      wait_until(fn -> LivePresence.count(nil) == 1 end)
      [%{since: since}] = LivePresence.list()

      Process.exit(first, :kill)
      wait_until(fn -> LivePresence.count(nil) == 0 end)

      second = spawn_page()
      LivePresence.watch(second, @client, %{path: "/pricing", site: "example.com"})
      wait_until(fn -> LivePresence.count(nil) == 1 end)

      # The grace period passes with the page still open: no leave yet, and
      # the view keeps its original start.
      Process.sleep(400)
      assert leaves() == []
      assert [%{since: ^since}] = LivePresence.list()

      Process.exit(second, :kill)
      assert [%{path: "/pricing"}] = wait_for_leave_list(1)
      Process.sleep(400)
      assert length(leaves()) == 1
    end

    test "a page left for good records its leave once the grace period ends" do
      pid = spawn_page()
      LivePresence.watch(pid, @client, %{path: "/pricing", site: "example.com"})
      wait_until(fn -> LivePresence.count(nil) == 1 end)

      Process.exit(pid, :kill)
      Process.sleep(100)
      assert leaves() == []

      assert [%{path: "/pricing"}] = wait_for_leave_list(1)
    end
  end

  describe "a reload whose old connection closes after the new page opens" do
    setup do
      enable_tracking()
      Application.put_env(:phoenix_kit_web_analytics, :presence_supersede_ms, 300)

      on_exit(fn ->
        Application.put_env(:phoenix_kit_web_analytics, :presence_supersede_ms, 0)
      end)

      start_supervised!(LivePresence)
      :ok
    end

    # Firefox opens the reloaded page's connection before closing the old
    # one, so for a few seconds the same visitor had the same page open twice.
    test "is one page and one view, with no leave for the old connection" do
      old = spawn_page()
      LivePresence.watch(old, @client, %{path: "/pricing", site: "example.com"})
      wait_until(fn -> LivePresence.count(nil) == 1 end)
      [%{since: since}] = LivePresence.list()

      new = spawn_page()
      LivePresence.watch(new, @client, %{path: "/pricing", site: "example.com"})

      # Straight away: one page, the new one, keeping the view's start.
      wait_until(fn -> match?([%{pid: ^new}], LivePresence.list()) end)
      assert [%{since: ^since}] = LivePresence.list()
      assert LivePresence.by_path(10) == [{"/pricing", 1}]

      Process.exit(old, :kill)
      Process.sleep(400)

      assert [%{pid: ^new, since: ^since}] = LivePresence.list()
      assert leaves() == []

      Process.exit(new, :kill)
      assert [%{path: "/pricing"}] = wait_for_leave_list(1)
    end

    test "a second tab that stays open is shown again, with its own start" do
      first = spawn_page()
      LivePresence.watch(first, @client, %{path: "/pricing", site: "example.com"})
      wait_until(fn -> LivePresence.count(nil) == 1 end)

      second = spawn_page()
      LivePresence.watch(second, @client, %{path: "/pricing", site: "example.com"})
      wait_until(fn -> match?([%{pid: ^second}], LivePresence.list()) end)

      wait_until(fn -> LivePresence.count(nil) == 2 end)
      [newer, older] = LivePresence.list()
      assert newer.pid == second and older.pid == first
      assert DateTime.compare(newer.since, older.since) == :gt
      assert LivePresence.by_path(10) == [{"/pricing", 2}]

      Enum.each([first, second], &Process.exit(&1, :kill))
    end

    test "a hidden page that navigates is a real tab, shown again" do
      first = spawn_page()
      LivePresence.watch(first, @client, %{path: "/pricing", site: "example.com"})
      wait_until(fn -> LivePresence.count(nil) == 1 end)

      second = spawn_page()
      LivePresence.watch(second, @client, %{path: "/pricing", site: "example.com"})
      wait_until(fn -> match?([%{pid: ^second}], LivePresence.list()) end)

      LivePresence.navigate(first, "/blog", @client, %{site: "example.com"})

      wait_until(fn ->
        Enum.sort(LivePresence.by_path(10)) == [{"/blog", 1}, {"/pricing", 1}]
      end)

      assert LivePresence.count(nil) == 2

      Enum.each([first, second], &Process.exit(&1, :kill))
    end
  end

  describe "a presence server that restarted while pages stayed open" do
    setup do
      enable_tracking()
      start_supervised!(LivePresence)
      :ok
    end

    # Found in review: navigate/2 for a page the server no longer knew was
    # ignored, so the page vanished from presence and never recorded a leave.
    test "navigate/4 starts watching an unknown page instead of losing it" do
      pid = spawn_page()
      LivePresence.navigate(pid, "/after-restart", @client, %{site: "example.com"})

      wait_until(fn -> LivePresence.count(nil) == 1 end)
      assert [%{path: "/after-restart"}] = LivePresence.list()

      Process.exit(pid, :kill)
      assert wait_for_leave("/after-restart")
    end
  end

  describe "without the server running" do
    test "list/1 and a site count are empty, and running?/0 is false" do
      refute LivePresence.running?()
      assert LivePresence.count("example.com") == 0
      assert LivePresence.list() == []
      assert LivePresence.list("example.com") == []
      # watch/navigate are no-ops rather than crashes.
      assert LivePresence.watch(self(), @client, %{path: "/"}) == :ok
      assert LivePresence.navigate(self(), "/x") == :ok
    end

    # Regression: `:ets.info/2` on a missing table answers `:undefined`, which
    # `count/1` used to return; `Filters.online/1` then took `max(:undefined,
    # n)` and the overview's "online" badge disappeared.
    test "count(nil) is 0 when the server isn't running" do
      refute LivePresence.running?()
      assert LivePresence.count(nil) == 0
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp spawn_page do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp leaves do
    Repo.all(from(e in Event, where: e.event_type == "leave", order_by: [asc: e.inserted_at]))
  end

  defp wait_for_leave(path) do
    wait_until(fn -> Enum.find(leaves(), &(&1.path == path)) end)
  end

  defp wait_for_leave_list(count) do
    wait_until(fn -> length(leaves()) == count end)
    leaves()
  end

  defp wait_until(fun, attempts \\ 100) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      _ ->
        flunk("condition not met within 1s")
    end
  end
end
