defmodule PhoenixKitWebAnalytics.TrafficFlagsCollectorTest do
  @moduledoc """
  The collector marking the site's own traffic: each flag, several at once,
  a visit flagged whole going forward and back, and the plug feeding it.
  """

  use PhoenixKitWebAnalytics.DataCase, async: false

  import Plug.Test, only: [conn: 2]

  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.InternalTraffic
  alias PhoenixKitWebAnalytics.Plug, as: TrackingPlug
  alias PhoenixKitWebAnalytics.Schemas.Event

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @firefox "Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0"

  setup do
    start_supervised!(InternalTraffic)
    enable_tracking()
    Application.delete_env(:phoenix_kit_web_analytics, :internal_networks)
    on_exit(fn -> Application.delete_env(:phoenix_kit_web_analytics, :internal_networks) end)
    :ok
  end

  defp hit(attrs \\ %{}) do
    Map.merge(
      %{path: "/pricing", site: "myapp.com", ip: {203, 0, 113, 5}, user_agent: @chrome},
      attrs
    )
  end

  defp flags_by_path, do: Event |> Repo.all() |> Map.new(&{&1.path, &1.traffic_flags})

  describe "each flag" do
    test "an ordinary visitor's hit has none" do
      assert {:ok, %{traffic_flags: 0}} = Collector.track(hit())
    end

    test "internal_network: the address is in a configured network" do
      Application.put_env(:phoenix_kit_web_analytics, :internal_networks, ["203.0.113.0/24"])

      assert {:ok, %{traffic_flags: 1}} = Collector.track(hit())
      assert {:ok, %{traffic_flags: 0}} = Collector.track(hit(%{ip: {198, 51, 100, 1}}))
    end

    test "admin: the signed-in user holds a staff role" do
      assert {:ok, %{traffic_flags: 2}} =
               Collector.track(hit(%{user_uuid: UUIDv7.generate(), roles: ["Owner"]}))

      assert {:ok, %{traffic_flags: 0}} =
               Collector.track(hit(%{ip: {198, 51, 100, 2}, roles: ["User"]}))
    end

    test "admin follows the staff-roles setting" do
      enable_tracking(%{"web_analytics_internal_roles" => "Editor"})

      assert {:ok, %{traffic_flags: 0}} = Collector.track(hit(%{roles: ["Admin"]}))

      assert {:ok, %{traffic_flags: 2}} =
               Collector.track(hit(%{ip: {198, 51, 100, 3}, roles: ["Editor"]}))
    end

    test "admin_network: a staff member's hit marks the network for everyone on it" do
      {:ok, _} = Collector.track(hit(%{roles: ["Admin"], user_uuid: UUIDv7.generate()}))

      # Another browser on the same address — another visitor.
      assert {:ok, %{traffic_flags: 4}} = Collector.track(hit(%{user_agent: @firefox}))
      assert {:ok, %{traffic_flags: 0}} = Collector.track(hit(%{ip: {198, 51, 100, 9}}))
    end

    test "admin_network is off with zero hours" do
      enable_tracking(%{"web_analytics_admin_network_hours" => "0"})
      {:ok, _} = Collector.track(hit(%{roles: ["Admin"]}))

      assert {:ok, %{traffic_flags: 0}} = Collector.track(hit(%{user_agent: @firefox}))
    end

    test "several at once" do
      Application.put_env(:phoenix_kit_web_analytics, :internal_networks, ["203.0.113.0/24"])
      InternalTraffic.note_admin_network({203, 0, 113, 5}, Config.collection_config())

      assert {:ok, %{traffic_flags: 7}} = Collector.track(hit(%{roles: ["Owner"]}))
    end
  end

  describe "a visit is flagged whole" do
    test "later hits inherit the visit's flags" do
      {:ok, first} = Collector.track(hit(%{path: "/a", roles: ["Admin"]}))
      enable_tracking(%{"web_analytics_admin_network_hours" => "0"})
      # Same visitor, no scope this time (a leave, a beacon).
      {:ok, later} = Collector.track(hit(%{path: "/b", event_type: "leave"}))

      assert later.session_id == first.session_id
      assert later.traffic_flags == 2
    end

    test "a bit that first appears mid-visit goes back to the visit's earlier hits" do
      {:ok, a} = Collector.track(hit(%{path: "/a"}))
      {:ok, b} = Collector.track(hit(%{path: "/b"}))
      # Someone else's visit on another address stays as it was.
      {:ok, _} = Collector.track(hit(%{path: "/other", ip: {198, 51, 100, 7}}))
      assert a.traffic_flags == 0 and b.traffic_flags == 0

      # The visitor signs in as an admin.
      {:ok, c} =
        Collector.track(hit(%{path: "/c", roles: ["Admin"], user_uuid: UUIDv7.generate()}))

      assert c.session_id == a.session_id
      assert %{"/a" => 2, "/b" => 2, "/c" => 2, "/other" => 0} = flags_by_path()
    end

    test "the write-back adds a bit and keeps the ones there" do
      Application.put_env(:phoenix_kit_web_analytics, :internal_networks, ["203.0.113.0/24"])
      {:ok, _} = Collector.track(hit(%{path: "/a"}))
      {:ok, _} = Collector.track(hit(%{path: "/b", roles: ["Admin"]}))

      assert %{"/a" => 3, "/b" => 3} = flags_by_path()
    end
  end

  describe "the column" do
    test "is a smallint, NOT NULL, 0 by default" do
      %{rows: [[type, nullable, default]]} =
        Repo.query!("""
        SELECT data_type, is_nullable, column_default FROM information_schema.columns
        WHERE table_name = 'phoenix_kit_web_analytics_events' AND column_name = 'traffic_flags'
        """)

      assert {type, nullable, default} == {"smallint", "NO", "0"}
      assert insert_event().traffic_flags == 0
    end
  end

  describe "the plug" do
    defp respond(conn) do
      conn
      |> TrackingPlug.call(TrackingPlug.init([]))
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, "<html></html>")
    end

    defp request(path, scope \\ nil) do
      conn(:get, path)
      |> Map.put(:remote_ip, {203, 0, 113, 5})
      |> Plug.Conn.put_req_header("user-agent", @chrome)
      |> Plug.Conn.assign(:phoenix_kit_current_scope, scope)
    end

    test "a staff member's page view is flagged admin" do
      "/pricing"
      |> request(PhoenixKitWebAnalytics.LiveCase.fake_scope(roles: [:admin]))
      |> respond()

      assert [%Event{traffic_flags: 6}] = Repo.all(Event)
    end

    test "flags by the roles held, not the one being acted as" do
      scope =
        PhoenixKitWebAnalytics.LiveCase.fake_scope(roles: ["User"], held_roles: [:owner, "User"])

      "/pricing" |> request(scope) |> respond()

      assert [%Event{traffic_flags: flags}] = Repo.all(Event)
      assert Bitwise.band(flags, 2) == 2
    end

    test "a staff member on an excluded path still marks the network" do
      "/admin/settings" |> request(PhoenixKitWebAnalytics.LiveCase.fake_scope()) |> respond()
      assert Repo.all(Event) == []

      "/pricing" |> request() |> respond()
      assert [%Event{traffic_flags: 4, user_uuid: nil}] = Repo.all(Event)
    end

    test "an ordinary signed-in user marks nothing" do
      "/admin/x"
      |> request(PhoenixKitWebAnalytics.LiveCase.fake_scope(roles: [:user]))
      |> respond()

      "/pricing" |> request() |> respond()

      assert [%Event{traffic_flags: 0}] = Repo.all(Event)
    end

    test "Tidewave's diagnostic re-fetch is not a page view" do
      "/pricing"
      |> request()
      |> Plug.Conn.put_req_header("x-tidewave-diagnostic", "1")
      |> respond()

      assert Repo.all(Event) == []

      "/pricing" |> request() |> respond()
      assert [_] = Repo.all(Event)
    end
  end
end
