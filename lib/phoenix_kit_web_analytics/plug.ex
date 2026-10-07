defmodule PhoenixKitWebAnalytics.Plug do
  @moduledoc """
  Records one page view per HTML response — the whole tracker, server-side.

  Add it once to the host's browser pipeline:

      # lib/my_app_web/router.ex
      pipeline :browser do
        # … existing plugs …
        plug PhoenixKitWebAnalytics.Plug
      end

  That's all page views need. **No script tag, no client-side bundle, no
  cookie**, and nothing added to the rendered page — pages stay byte-for-byte
  what they were. LiveView navigation, interactions and exits come from
  `PhoenixKitWebAnalytics.LiveHook`, which has its own (small) setup.

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
    * requests from Tidewave's development tooling (an `x-tidewave-diagnostic`
      header): it fetches the page again after every live navigation, which
      would count each one twice

  ## The site's own people

  A request by a signed-in user holding a staff role
  (`web_analytics_internal_roles`) marks the client's network as a staff
  network — for any path, excluded ones included, since staff mostly work in
  `/admin`. See `PhoenixKitWebAnalytics.InternalTraffic`. Their page views
  are stored with the `admin` flag (`PhoenixKitWebAnalytics.TrafficFlags`).

  Who is signed in is read when the response is sent, not when this plug
  runs, so the plug may sit anywhere in the pipeline: PhoenixKit's own routes
  pipe through the host's `:browser` first and only then load the user
  (`:phoenix_kit_auto_setup`) and, for the admin, the scope. With a scope the
  roles come from it; with only `:phoenix_kit_current_user` (core's
  auto-setup) they come from a five-minute cache of the user's roles, looked
  up off the request on a miss — that request goes unnoted, the next one
  counts.

  ## Options

    * `:exclude` — extra path patterns on top of the ones in settings, e.g.
      `plug PhoenixKitWebAnalytics.Plug, exclude: ["/healthz", "/internal*"]`.
      A trailing `*` makes a pattern a prefix match. These apply to this
      plug's page views only: the LiveView hook can't see plug options, so a
      LiveView page to leave out entirely belongs in the
      `web_analytics_exclude_paths` setting, which both honour.

  ## Client IP

  The client address is visitor-hash input (and only that — no IP is ever
  stored). It is read the way PhoenixKit reads it for a login
  (`PhoenixKit.Utils.IpAddress.client_address/1`): a public
  `conn.remote_ip` is the visitor; a private or loopback one is a reverse
  proxy on the same box or network, and the visitor is the **last**
  `X-Forwarded-For` entry — the one that proxy appended; a visitor can send
  their own header, but not control what the proxy adds after it — then
  `X-Real-IP` when there is no readable `X-Forwarded-For`. A proxy that
  appends the port (`203.0.113.7:51234`, `[2001:db8::7]:443`) is read too.

  That trust needs no configuration, so the proxy must set or append
  `X-Forwarded-For` itself: one that only sets `X-Real-IP` passes the
  visitor's own header through. On an intranet where visitors have private
  addresses and reach the app directly, each of them can send it.

  Behind a chain — a CDN in front of a load balancer — the last entry is the
  CDN's address, not the visitor's. There, put a plug that rewrites
  `remote_ip` from the headers your infrastructure controls —
  [`remote_ip`](https://hex.pm/packages/remote_ip) — **before** this one; a
  public `remote_ip` is taken as is. The same goes for a CDN or proxy with a
  public address in front of the app: as a public peer its headers are
  ignored, and without `RemoteIp` every visitor is one of its addresses.

  `config :phoenix_kit_web_analytics, trust_x_forwarded_for: true` is
  deprecated and does nothing: the forwarded header from a private peer is
  always read.
  """

  @behaviour Plug

  import Plug.Conn

  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.InternalTraffic
  alias PhoenixKitWebAnalytics.Tracking

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
    if conn.method == "GET" and not skipped?(conn) and not replay_frame?(conn) and
         not diagnostic?(conn) do
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

  # The session-recording player loads the recorded page behind the replay;
  # an admin watching a visit is not a page view of it.
  defp replay_frame?(conn), do: String.contains?(conn.query_string, "pk_replay=1")

  # Tidewave (development) re-fetches a page after each live navigation to
  # diagnose it; that fetch is not a visitor's.
  defp diagnostic?(conn), do: get_req_header(conn, "x-tidewave-diagnostic") != []

  defp maybe_register(conn, opts) do
    config = Config.collection_config()

    conn
    |> register_tracking(config, opts)
    |> register_staff_note(config)
  end

  defp register_tracking(conn, config, opts) do
    cond do
      not config.enabled? ->
        conn

      # Noted whatever the path: a visitor who arrives on an excluded page
      # and live-navigates on is still to be left alone by the hook.
      opted_out?(conn, config) ->
        remember_opt_out(conn)

      not trackable_path?(conn.request_path, config, opts) ->
        conn

      true ->
        started_at = System.monotonic_time(:microsecond)
        register_before_send(conn, &track(&1, started_at))
    end
  end

  # Whatever the path or opt-out: staff mostly work on excluded paths, and
  # their network counts whatever they ask for. Registered last so it runs
  # first (before_send callbacks run in reverse): the page view of the
  # request that marks the network already carries the mark.
  defp register_staff_note(conn, %{enabled?: true, admin_network_hours: hours} = config)
       when hours > 0,
       do: register_before_send(conn, &note_staff(&1, config))

  defp register_staff_note(conn, _config), do: conn

  # As the response goes out — after the pipeline and the controller have put
  # the user (or scope) in assigns. In the request process, from memory: no
  # query; a broadcast only when the network is new or past half its time.
  #
  # On a role-cache miss the lookup runs off the request and notes the
  # address itself when the user turns out to be staff.
  defp note_staff(conn, config) do
    case Tracking.current_user_uuid(conn.assigns) do
      nil ->
        conn

      user_uuid ->
        ip = Tracking.client_ip(conn)
        hit = %{roles: Tracking.current_roles(conn.assigns), user_uuid: user_uuid, ip: ip}

        if InternalTraffic.staff_hit?(hit, config),
          do: InternalTraffic.note_admin_network(ip, config)

        conn
    end
  rescue
    _ -> conn
  catch
    :exit, _ -> conn
  end

  # The LiveView socket can't see request headers, so a DNT / GPC visitor is
  # noted in the session for `PhoenixKitWebAnalytics.LiveHook` to honour. Only
  # opted-out visitors get the key, and only when the host already fetched a
  # session — this plug never starts one.
  defp remember_opt_out(conn) do
    key = Tracking.dnt_session_key()

    if session_fetched?(conn) and get_session(conn, key) != true do
      put_session(conn, key, true)
    else
      conn
    end
  end

  defp session_fetched?(conn), do: conn.private[:plug_session_fetch] == :done

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
    query_params = fetch_campaign_params(conn)

    %{
      event_type: "pageview",
      path: conn.request_path,
      site: conn.host,
      referrer: header(conn, "referer"),
      query_params: query_params,
      ip: Tracking.client_ip(conn),
      user_agent: header(conn, "user-agent"),
      language: header(conn, "accept-language"),
      user_uuid: Tracking.current_user_uuid(conn.assigns),
      roles: Tracking.current_roles(conn.assigns),
      status: conn.status,
      duration_ms: duration_ms,
      location: edge_location(conn),
      metadata: live_metadata(conn)
    }
  end

  # A page whose LiveView runs `PhoenixKitWebAnalytics.LiveHook` will report
  # its live connection; one that never does ran no JavaScript (see
  # `PhoenixKitWebAnalytics.BotSignals`). Read off the route's live_session.
  defp live_metadata(conn) do
    case conn.private[:phoenix_live_view] do
      {_view, _opts, %{extra: %{on_mount: hooks}}} when is_list(hooks) ->
        if Enum.any?(hooks, &match?(%{id: {PhoenixKitWebAnalytics.LiveHook, _}}, &1)),
          do: %{"lv" => true},
          else: %{}

      _ ->
        %{}
    end
  end

  # Only the campaign parameters are read out; the rest of the query string is
  # deliberately never looked at, let alone stored (see `Collector`).
  defp fetch_campaign_params(conn) do
    case conn.query_params do
      %Plug.Conn.Unfetched{} -> Tracking.campaign_params(conn.query_string)
      params when is_map(params) -> Map.take(params, Tracking.campaign_param_names())
    end
  rescue
    _ -> %{}
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
    # A malformed %-escape in the header.
    ArgumentError -> nil
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
