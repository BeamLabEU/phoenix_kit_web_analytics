defmodule PhoenixKitWebAnalytics.RequestVisitorTest do
  @moduledoc """
  `PhoenixKitWebAnalytics.visitor/1` names the visitor a request's page view
  is stored under — the collector's own recipe, prefetch included.
  """

  use PhoenixKitWebAnalytics.DataCase, async: false

  import Plug.Test, only: [conn: 2]

  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Plug, as: TrackingPlug
  alias PhoenixKitWebAnalytics.RequestVisitor
  alias PhoenixKitWebAnalytics.Schemas.Event

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  setup do
    enable_tracking()
    assert is_binary(Config.hash_salt())
    clear_settings_cache()
    :ok
  end

  defp request(path, headers) do
    Enum.reduce([{"user-agent", @chrome} | headers], conn(:get, path), fn {k, v}, conn ->
      Plug.Conn.put_req_header(conn, k, v)
    end)
  end

  defp page_view(conn) do
    conn
    |> TrackingPlug.call(TrackingPlug.init([]))
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, "<html></html>")
  end

  test "is the visitor the request's page view is stored under" do
    conn = request("/pricing", [])
    page_view(conn)

    assert [%Event{visitor_id: stored}] = Repo.all(Event)
    visitor = PhoenixKitWebAnalytics.visitor(conn)

    assert visitor.visitor_id == stored
    assert visitor.ip == {127, 0, 0, 1}
    assert visitor.network == "127.0.0.1"
    refute visitor.prefetch?
  end

  test "behind a local proxy, the forwarded address names the visitor" do
    conn = request("/pricing", [{"x-forwarded-for", "198.51.100.4, 203.0.113.9"}])
    page_view(conn)

    assert [%Event{visitor_id: stored}] = Repo.all(Event)
    visitor = PhoenixKitWebAnalytics.visitor(conn)

    assert visitor.visitor_id == stored
    assert visitor.ip == {203, 0, 113, 9}
    assert visitor.network == "203.0.113.9"
  end

  test "an IPv6 visitor's network is its /64" do
    conn = %{request("/", []) | remote_ip: {0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}}
    assert PhoenixKitWebAnalytics.visitor(conn).network == "2001:db8:1:2::/64"
  end

  test "a speculative prefetch is the prefetch's own visitor, as stored" do
    plain = request("/pricing", [])
    prefetch = request("/pricing", [{"sec-purpose", "prefetch;prerender"}])
    page_view(prefetch)

    assert [%Event{visitor_id: stored, is_bot: true}] = Repo.all(Event)
    visitor = PhoenixKitWebAnalytics.visitor(prefetch)

    assert visitor.prefetch?
    assert visitor.visitor_id == stored
    refute visitor.visitor_id == PhoenixKitWebAnalytics.visitor(plain).visitor_id
  end

  test "follows the configured rotation" do
    conn = request("/", [])
    daily = PhoenixKitWebAnalytics.visitor(conn).visitor_id

    enable_tracking(%{"web_analytics_visitor_rotation" => "weekly"})
    page_view(conn)

    assert [%Event{visitor_id: stored}] = Repo.all(Event)
    assert PhoenixKitWebAnalytics.visitor(conn).visitor_id == stored
    refute stored == daily
  end

  test "put/1 keeps it for the rest of the request; fetch/1 reads only a kept one" do
    conn = request("/", [])
    assert RequestVisitor.fetch(conn) == :error

    kept = PhoenixKitWebAnalytics.put_visitor(conn)
    assert {:ok, visitor} = RequestVisitor.fetch(kept)
    assert PhoenixKitWebAnalytics.visitor(kept) == visitor
    # Putting again leaves the kept one alone.
    assert PhoenixKitWebAnalytics.put_visitor(kept) == kept

    # What a later caller gets is what was kept, not a fresh computation.
    marked =
      Plug.Conn.put_private(conn, :phoenix_kit_web_analytics_visitor, %{
        visitor
        | visitor_id: "kept"
      })

    assert PhoenixKitWebAnalytics.visitor(marked).visitor_id == "kept"
  end

  test "without a salt the visitor ID is nil, and nothing is written" do
    Repo.delete_all(
      from(s in "phoenix_kit_settings", where: s.key == "web_analytics_hash_secret")
    )

    clear_settings_cache()

    visitor = PhoenixKitWebAnalytics.visitor(request("/", []))

    assert visitor.visitor_id == nil
    assert visitor.ip == {127, 0, 0, 1}
    assert Config.cached_hash_salt() == nil
  end
end
