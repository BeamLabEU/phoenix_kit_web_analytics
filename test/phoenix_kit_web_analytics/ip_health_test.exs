defmodule PhoenixKitWebAnalytics.IpHealthTest do
  @moduledoc """
  The in-memory sample of client addresses, and its verdict.
  """

  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 2]

  alias PhoenixKitWebAnalytics.IpHealth
  alias PhoenixKitWebAnalytics.Ring

  setup do
    start_supervised!(Ring)
    :ok
  end

  defp sample(peer, headers, client) do
    conn =
      Enum.reduce(headers, %{conn(:get, "/") | remote_ip: peer}, fn {k, v}, conn ->
        Plug.Conn.put_req_header(conn, k, v)
      end)

    IpHealth.sample(conn, client)
  end

  test "too small a sample says nothing" do
    for _ <- 1..5, do: sample({127, 0, 0, 1}, [], {127, 0, 0, 1})

    assert %{status: :not_enough, sample: 5} = IpHealth.report()
  end

  test "a proxy that sends no X-Forwarded-For makes every visitor one internal address" do
    for _ <- 1..30, do: sample({172, 18, 0, 7}, [], {172, 18, 0, 7})

    assert %{
             status: :one_internal,
             sample: 30,
             private_peers: 30,
             forwarded: 0,
             private_clients: 30,
             distinct_clients: 1
           } = PhoenixKitWebAnalytics.ip_health()
  end

  test "visitors forwarded by the proxy are many addresses" do
    for n <- 1..30 do
      sample({127, 0, 0, 1}, [{"x-forwarded-for", "203.0.113.#{n}"}], {203, 0, 113, n})
    end

    assert %{status: :ok, forwarded: 30, private_clients: 0, distinct_clients: 30} =
             IpHealth.report()
  end

  test "an intranet with many private visitors is fine" do
    for n <- 1..30, do: sample({10, 0, 0, n}, [], {10, 0, 0, n})

    assert %{status: :ok, distinct_clients: 30} = IpHealth.report()
  end

  test "one public address for every page view is flagged once the sample is large" do
    for _ <- 1..30, do: sample({198, 51, 100, 1}, [], {198, 51, 100, 1})
    assert IpHealth.report().status == :ok

    for _ <- 1..30, do: sample({198, 51, 100, 1}, [], {198, 51, 100, 1})
    assert IpHealth.report().status == :one_address
  end

  test "keeps only the last 200, and no address" do
    for n <- 1..250, do: sample({127, 0, 0, 1}, [], {203, 0, rem(n, 250), 1})

    assert IpHealth.report().sample == 200
    # Booleans and a hash: no address tuple, no address string.
    for entry <- Ring.list(:ip_health, 200) do
      assert {peer?, forwarded?, private?, hash} = entry
      assert is_boolean(peer?) and is_boolean(forwarded?) and is_boolean(private?)
      assert is_integer(hash)
    end
  end

  test "without its process, sampling is a no-op" do
    stop_supervised!(Ring)

    assert sample({127, 0, 0, 1}, [], {127, 0, 0, 1}) == :ok
    assert IpHealth.report().status == :not_enough
  end
end

defmodule PhoenixKitWebAnalytics.IpHealthIntegrationTest do
  @moduledoc """
  The plug samples what it tracks, and Settings says what the sample shows.
  """

  use PhoenixKitWebAnalytics.LiveCase, async: false

  alias PhoenixKitWebAnalytics.IpHealth
  alias PhoenixKitWebAnalytics.Plug, as: TrackingPlug
  alias PhoenixKitWebAnalytics.Ring

  setup do
    start_supervised!(Ring)
    enable_tracking()
    :ok
  end

  defp page_view(peer) do
    %{Plug.Test.conn(:get, "/pricing") | remote_ip: peer}
    |> Plug.Conn.put_req_header("user-agent", "Mozilla/5.0 Firefox/120.0")
    |> TrackingPlug.call(TrackingPlug.init([]))
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, "<html></html>")
  end

  test "each tracked page view is sampled; an excluded one is not" do
    page_view({172, 18, 0, 7})

    %{Plug.Test.conn(:get, "/admin/x") | remote_ip: {172, 18, 0, 7}}
    |> TrackingPlug.call(TrackingPlug.init([]))
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, "")

    assert %{sample: 1, private_peers: 1, private_clients: 1} = IpHealth.report()
  end

  test "Settings warns when every visitor is one internal address", %{conn: conn} do
    for _ <- 1..25, do: page_view({172, 18, 0, 7})

    {:ok, view, _html} = live(conn, "/admin/web-analytics/settings")
    html = view |> element("#web-analytics-ip-health") |> render()

    assert html =~ "All your visitors look like one internal address."
    assert html =~ "X-Forwarded-For"
  end

  test "Settings says so when addresses look right", %{conn: conn} do
    for n <- 1..25, do: page_view({203, 0, 113, n})

    {:ok, view, _html} = live(conn, "/admin/web-analytics/settings")
    assert view |> element("#web-analytics-ip-health") |> render() =~ "look right"
  end
end
