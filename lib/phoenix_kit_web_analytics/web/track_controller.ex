defmodule PhoenixKitWebAnalytics.Web.TrackController do
  @moduledoc """
  Two optional client-side entry points, for the cases the plug can't see.

  Neither is needed for ordinary server-rendered traffic — that's
  `PhoenixKitWebAnalytics.Plug`, which needs no client cooperation at all.
  Both are **off by default**: they only accept hits when
  `web_analytics_beacon_enabled` is on.

    * `POST /phoenix-kit/analytics/event` — custom events (`"signup"`,
      `"add_to_cart"`) reported by `window.phoenixKitAnalytics(name, props)`,
      from the `<.beacon />` snippet or the optional client script; and the
      client script's clicks, scroll depth and page exits. Page views and
      custom events need `web_analytics_beacon_enabled`; the client script's
      hits need `web_analytics_client_script`.

    * `GET /phoenix-kit/analytics/pixel.gif` — a 1×1 GIF for pages the plug
      never runs for: full-page CDN caches, statically exported pages, AMP.

    * `GET` / `POST /phoenix-kit/analytics/recording` — session recordings:
      whether to record this visitor on this page, and the recorded chunks.
      Off unless `web_analytics_recording` is on; see
      `PhoenixKitWebAnalytics.Recordings`.

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
  alias PhoenixKitWebAnalytics.Recordings
  alias PhoenixKitWebAnalytics.Referrer
  alias PhoenixKitWebAnalytics.Tracking
  alias PhoenixKitWebAnalytics.Web.BeaconPayload

  # 43-byte transparent 1×1 GIF.
  @pixel Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
  # A beacon payload is a few hundred bytes; anything much larger isn't one.
  @max_body 16_384
  # A recording chunk: up to a couple of thousand short frames.
  @max_recording_body 131_072

  @doc "Records a hit reported by the beacon or the client script."
  def event(conn, params) do
    {conn, params} = with_body_params(conn, params)
    track(conn, params)

    send_resp(conn, :no_content, "")
  end

  @doc "Records a page view and returns a 1×1 GIF."
  def pixel(conn, params) do
    params =
      params
      |> Map.put("e", "pageview")
      |> Map.put_new_lazy("p", fn -> same_origin_referer_path(conn) end)

    track(conn, params)

    conn
    |> put_resp_content_type("image/gif")
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, private")
    |> put_resp_header("pragma", "no-cache")
    |> send_resp(200, @pixel)
  end

  @doc """
  Whether the client script should record this page: `{"record": true}` or
  `false`. Private and short-lived in caches — the answer depends on the
  visitor (sampling) and on a setting that can change.
  """
  def recording_config(conn, params) do
    record? = Recordings.record?(recording_client(conn), params["p"])

    conn
    |> put_resp_header("cache-control", "private, max-age=60")
    |> json(%{record: record?})
  end

  @doc "Stores a chunk of a session recording."
  def recording(conn, params) do
    {conn, params} = with_body_params(conn, params, @max_recording_body)
    _ = Recordings.store(recording_client(conn), params)

    send_resp(conn, :no_content, "")
  end

  defp recording_client(conn) do
    %{
      ip: Tracking.client_ip(conn),
      user_agent: conn |> get_req_header("user-agent") |> List.first(),
      site: Referrer.normalize_host(conn.host),
      opted_out?: get_req_header(conn, "dnt") == ["1"] or get_req_header(conn, "sec-gpc") == ["1"]
    }
  end

  defp track(conn, params) do
    config = Config.collection_config()

    if reported?(params) and accepted?(params, config) and not opted_out?(conn, config) do
      hit = BeaconPayload.to_hit(conn, params)
      unless Config.excluded?(hit.path, config.exclusions), do: Collector.track_async(hit)
    end

    :ok
  end

  # A payload must say what it reports in a shape we know. An empty or
  # undecodable body, an unknown type, or an event without a name is dropped —
  # never stored as a page view of "/".
  defp reported?(params), do: BeaconPayload.kind(params) != :unknown

  # Page views ride on the beacon switch; clicks, scroll and leaves on the
  # client-script switch; custom events (`phoenixKitAnalytics(...)`, which
  # both scripts provide) on either.
  defp accepted?(params, config) do
    case BeaconPayload.kind(params) do
      :event -> config.beacon_enabled? or config.client_script?
      :pageview -> config.beacon_enabled?
      _client_script -> config.client_script?
    end
  end

  defp opted_out?(conn, %{respect_dnt?: true}) do
    get_req_header(conn, "dnt") == ["1"] or get_req_header(conn, "sec-gpc") == ["1"]
  end

  defp opted_out?(_conn, _config), do: false

  # `navigator.sendBeacon(url, string)` posts `text/plain`, which the JSON
  # parser leaves alone — so the body is read and decoded here. A JSON body
  # was already parsed into `params`.
  defp with_body_params(conn, params, max \\ @max_body) do
    if params_empty?(params) do
      case read_body(conn, length: max) do
        {:ok, body, conn} -> {conn, decode(body)}
        {_other, _body, conn} -> {conn, %{}}
        {:error, _reason} -> {conn, %{}}
      end
    else
      {conn, params}
    end
  end

  defp params_empty?(params), do: params |> Map.drop(["_format"]) |> map_size() == 0

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  # A pixel on a cached page usually can't say which page it's on; the
  # browser's Referer can, when it points at this same site.
  defp same_origin_referer_path(conn) do
    with [referer | _] <- get_req_header(conn, "referer"),
         %URI{host: host, path: "/" <> _ = path} <- URI.parse(referer),
         true <- Referrer.normalize_host(host) == Referrer.normalize_host(conn.host) do
      path
    else
      _ -> nil
    end
  end
end
