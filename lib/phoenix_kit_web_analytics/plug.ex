defmodule PhoenixKitWebAnalytics.Plug do
  @moduledoc """
  Records one page view per HTML response — the whole tracker, server-side.

  Add it once to the host's browser pipeline:

      # lib/my_app_web/router.ex
      pipeline :browser do
        # … existing plugs …
        plug PhoenixKitWebAnalytics.Plug
      end

  That's the entire installation. **No script tag, no client-side bundle, no
  cookie**, and nothing added to the rendered page — pages stay byte-for-byte
  what they were.

  ## Cost to a request

  The plug does three cheap things in the request process: a method/path check,
  one ETS read for settings, and `register_before_send/2`. When the response is
  on its way out it builds a map and hands it to
  `PhoenixKitWebAnalytics.Collector`, which does the settings-dependent
  enrichment, the session-stitch query, and the insert **in a supervised task**.
  No database work happens while the client is waiting.

  ## What is skipped

  Anything that isn't a person looking at a page:

    * non-`GET` requests, and non-2xx responses (a redirect isn't a page view)
    * responses that aren't `text/html`, so assets, JSON APIs, and file
      downloads never appear in reports
    * paths matching the exclusion patterns in settings (`/admin*` by default)
    * requests sending `DNT: 1` or `Sec-GPC: 1`, when
      `web_analytics_respect_dnt` is on (it is by default)
    * automated User-Agents, unless `web_analytics_track_bots` is on
    * anything explicitly marked with `skip/1`

  ## Options

    * `:exclude` — extra path patterns on top of the ones in settings, e.g.
      `plug PhoenixKitWebAnalytics.Plug, exclude: ["/healthz", "/internal*"]`.
      A trailing `*` makes a pattern a prefix match.

  ## Client IP

  `conn.remote_ip` is used as visitor-hash input (and only that — no IP is ever
  stored). Behind a proxy or load balancer that is the proxy's address, which
  would collapse every visitor into one. The right fix is a plug that rewrites
  `remote_ip` from the forwarding headers your infrastructure actually
  controls — [`remote_ip`](https://hex.pm/packages/remote_ip) — placed **before**
  this one in the pipeline. Failing that:

      config :phoenix_kit_web_analytics, trust_x_forwarded_for: true

  reads the first entry of `X-Forwarded-For`. That header is client-settable, so
  only turn it on when something upstream is guaranteed to overwrite it.
  """

  @behaviour Plug

  import Plug.Conn

  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config

  @utm_params ~w(utm_source utm_medium utm_campaign utm_term utm_content)
  @country_headers ~w(cf-ipcountry x-vercel-ip-country fastly-geo-country x-country-code)
  @skip_key :phoenix_kit_web_analytics_skip

  @impl Plug
  def init(opts) do
    Keyword.put(opts, :exclude, List.wrap(Keyword.get(opts, :exclude, [])))
  end

  @impl Plug
  def call(conn, opts) do
    # Cheapest checks first: no settings read at all for asset requests, POSTs,
    # or anything already marked to skip.
    if conn.method == "GET" and not skipped?(conn) do
      maybe_register(conn, opts)
    else
      conn
    end
  end

  @doc """
  Marks a request as not-to-be-tracked.

  Useful for endpoints that render HTML but aren't pages — a preview iframe, a
  health check that returns a status page, a LiveView upload target:

      conn |> PhoenixKitWebAnalytics.Plug.skip() |> render("preview.html")

  Also honoured when set before this plug runs, e.g. from an earlier plug.
  """
  @spec skip(Plug.Conn.t()) :: Plug.Conn.t()
  def skip(conn), do: put_private(conn, @skip_key, true)

  @doc "Whether this request has been marked to skip tracking."
  @spec skipped?(Plug.Conn.t()) :: boolean()
  def skipped?(conn), do: conn.private[@skip_key] == true

  # ── internals ─────────────────────────────────────────────────────────────

  defp maybe_register(conn, opts) do
    config = Config.collection_config()
    path = conn.request_path

    if config.enabled? and trackable_path?(path, config, opts) and not opted_out?(conn, config) do
      started_at = System.monotonic_time(:microsecond)
      register_before_send(conn, &track(&1, started_at))
    else
      conn
    end
  end

  defp trackable_path?(path, config, opts) do
    not Config.excluded?(path, config.exclusions) and
      not Config.excluded?(path, Keyword.get(opts, :exclude, []))
  end

  defp opted_out?(conn, %{respect_dnt?: true}) do
    header(conn, "dnt") == "1" or header(conn, "sec-gpc") == "1"
  end

  defp opted_out?(_conn, _config), do: false

  # Runs in the request process, so it must stay allocation-light and must
  # return the conn untouched.
  defp track(conn, started_at) do
    if html_pageview?(conn) and not skipped?(conn) do
      duration_ms = div(System.monotonic_time(:microsecond) - started_at, 1000)
      Collector.track_async(build_hit(conn, duration_ms))
    end

    conn
  rescue
    # Nothing in the analytics path may break a response that was otherwise
    # about to be sent successfully.
    _ -> conn
  end

  defp html_pageview?(conn) do
    conn.status in 200..299 and html_response?(conn)
  end

  defp html_response?(conn) do
    case get_resp_header(conn, "content-type") do
      [content_type | _] -> String.contains?(content_type, "text/html")
      [] -> false
    end
  end

  defp build_hit(conn, duration_ms) do
    query_params = fetch_utm_params(conn)

    %{
      event_type: "pageview",
      path: conn.request_path,
      site: conn.host,
      referrer: header(conn, "referer"),
      query_params: query_params,
      ip: client_ip(conn),
      user_agent: header(conn, "user-agent"),
      language: header(conn, "accept-language"),
      user_uuid: current_user_uuid(conn),
      status: conn.status,
      duration_ms: duration_ms,
      location: edge_location(conn)
    }
  end

  # Only the campaign parameters are read out; the rest of the query string is
  # deliberately never looked at, let alone stored (see `Collector`).
  defp fetch_utm_params(conn) do
    case conn.query_params do
      %Plug.Conn.Unfetched{} -> conn.query_string |> URI.decode_query() |> Map.take(@utm_params)
      params when is_map(params) -> Map.take(params, @utm_params)
    end
  rescue
    _ -> %{}
  end

  defp client_ip(conn) do
    if Application.get_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for, false) do
      forwarded_ip(conn) || conn.remote_ip
    else
      conn.remote_ip
    end
  end

  defp forwarded_ip(conn) do
    with header when is_binary(header) <- header(conn, "x-forwarded-for"),
         [first | _] <- String.split(header, ","),
         {:ok, ip} <- first |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      ip
    else
      _ -> nil
    end
  end

  # Most CDNs already resolved the country at the edge; using it avoids needing
  # an IP database at all.
  defp edge_location(conn) do
    case country_header(conn) do
      nil ->
        nil

      code ->
        %{
          country_code: code,
          region: header(conn, "x-vercel-ip-country-region"),
          city: conn |> header("x-vercel-ip-city") |> decode_city()
        }
    end
  end

  defp country_header(conn) do
    Enum.find_value(@country_headers, fn name ->
      case header(conn, name) do
        code when is_binary(code) and byte_size(code) == 2 and code != "XX" -> String.upcase(code)
        _ -> nil
      end
    end)
  end

  defp decode_city(nil), do: nil

  defp decode_city(city) do
    URI.decode(city)
  rescue
    _ -> nil
  end

  defp current_user_uuid(conn) do
    case conn.assigns do
      %{phoenix_kit_current_user: %{uuid: uuid}} -> uuid
      %{phoenix_kit_current_scope: %{user: %{uuid: uuid}}} -> uuid
      _ -> nil
    end
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
