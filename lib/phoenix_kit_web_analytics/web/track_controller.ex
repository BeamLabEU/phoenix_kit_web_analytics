defmodule PhoenixKitWebAnalytics.Web.TrackController do
  @moduledoc """
  Two optional client-side entry points, for the cases the plug can't see.

  Neither is needed for ordinary server-rendered traffic — that's
  `PhoenixKitWebAnalytics.Plug`, which needs no client cooperation at all.
  Both are **off by default**: they only accept hits when
  `web_analytics_beacon_enabled` is on.

    * `POST /phoenix-kit/analytics/event` — custom events (`"signup"`,
      `"add_to_cart"`) reported by `window.phoenixKitAnalytics(name, props)`,
      the small snippet rendered by
      `PhoenixKitWebAnalytics.Web.Beacon.beacon/1`.

    * `GET /phoenix-kit/analytics/pixel.gif` — a 1×1 GIF for pages the plug
      never runs for: full-page CDN caches, statically exported pages, AMP.

  ## Trust boundary

  These endpoints are public and unauthenticated. What a payload can and cannot
  influence is enforced in `PhoenixKitWebAnalytics.Web.BeaconPayload`.

  Beyond that: anyone can POST here and inflate counts, exactly as with every
  client-side analytics product. Leave the beacon off unless you need custom
  events, and put per-IP rate limiting in front of it if you do.

  Both actions answer the same way whether or not the beacon is enabled — a
  disabled beacon is not an error the page should surface, and the response
  tells a caller nothing about the site's configuration.
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Web.BeaconPayload

  # 43-byte transparent 1×1 GIF.
  @pixel Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")

  @doc "Records a custom event (or a client-reported page view) from the beacon."
  def event(conn, params) do
    track(conn, params)

    send_resp(conn, :no_content, "")
  end

  @doc "Records a page view and returns a 1×1 GIF."
  def pixel(conn, params) do
    track(conn, Map.put(params, "e", "pageview"))

    conn
    |> put_resp_content_type("image/gif")
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, private")
    |> put_resp_header("pragma", "no-cache")
    |> send_resp(200, @pixel)
  end

  defp track(conn, params) do
    if Config.beacon_enabled?() do
      conn |> BeaconPayload.to_hit(params) |> Collector.track_async()
    end

    :ok
  end
end
