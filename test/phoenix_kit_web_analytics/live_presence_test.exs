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
