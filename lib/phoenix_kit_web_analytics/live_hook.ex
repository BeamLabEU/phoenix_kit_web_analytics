defmodule PhoenixKitWebAnalytics.LiveHook do
  @moduledoc """
  Everything a visitor does on a LiveView page, recorded server-side from the
  socket — no client-side script.

  `PhoenixKitWebAnalytics.Plug` sees HTTP requests, which covers the first load
  of a page. Once a LiveView is connected, the visitor's clicks, form submits
  and navigations travel over the websocket instead, and that's where this hook
  sits. It records:

    * **Page views for live navigation** — `push_navigate`, `push_patch`,
      `<.link navigate>` / `<.link patch>` change the URL without an HTTP
      request, so the plug never sees them.
    * **Interactions** — every `phx-click`, `phx-submit`, `phx-keydown` … event
      the LiveView handles, by event name (`"add_to_cart"`, `"save"`). Form
      contents are never recorded; see "What an interaction stores" below.
    * **Leaving** — the page is registered with
      `PhoenixKitWebAnalytics.LivePresence`, which records a `"leave"` event
      with the time spent on the page when the LiveView process ends, and
      powers the "on the site right now" view.

  Attach it in the host's `live_session`, after whatever mounts the current
  user, so logged-in visitors are attributed:

      live_session :public,
        on_mount: [
          {PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope},
          {PhoenixKitWebAnalytics.LiveHook, :track_navigation}
        ] do
        live "/", HomeLive
        live "/pricing", PricingLive
      end

  ## Requires connect_info on the socket

  The hook needs the same two inputs the plug has — client IP and User-Agent —
  because they feed the daily visitor hash. Without them a LiveView navigation
  would hash to a *different* visitor than the page load that preceded it,
  inflating the visitor count. Rather than record data it knows to be wrong, the
  hook does nothing unless the endpoint provides them:

      socket "/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [:peer_data, :x_headers, :user_agent, session: @session_options]],
        longpoll: [connect_info: [:peer_data, :x_headers, :user_agent, session: @session_options]]

  The keys must be listed **on both transports**: LiveView falls back to long
  polling when a websocket can't be opened (a corporate proxy, a flaky
  network), and a visitor on the fallback transport is invisible to this hook
  if only `websocket:` carries them. If `:peer_data` or `:user_agent` is
  missing the hook stays inert and only full page loads are counted — check
  this first if LiveView activity isn't showing up.

  `:x_headers` is what lets the hook see the visitor behind a reverse proxy:
  when the socket's peer is a private or loopback address (the proxy), the
  visitor's address is the forwarded one, read by the same rule as the plug
  (see "Client IP" in `PhoenixKitWebAnalytics.Plug`). Without `:x_headers`
  such a socket can't name its visitor — a proxy, a container network and
  `localhost` in development look the same — so the hook stays inert for it —
  no page view, no interaction, no "Right now" entry — and counts the skip;
  Settings then shows a warning. With `:x_headers` listed and no proxy in
  front (development, a LAN), the peer is the visitor. The same headers
  carry an `x-accept-language`, when a proxy sets one, for the visitor's
  language.

  ## Not double-counted

  A page load is an ordinary HTTP response the plug already recorded, so the
  `handle_params` that follows the connected mount is not counted again. A live
  navigation is told apart by LiveView's `_live_referer` connect parameter,
  which the client sends only when it arrived by `push_navigate` / `<.link
  navigate>`. A **reconnect** (a deploy, a dropped network) remounts with
  `_mounts > 0` and is never counted — the visitor didn't go anywhere.

  ## What an interaction stores

  The event name, the page it happened on, and — only for parameter names
  listed in the `web_analytics_event_params` setting (`tab`, `view`, `step` …
  by default) — short scalar values, so "switched to the *pricing* tab" is
  visible. Everything else in the params is discarded before it leaves the
  LiveView process: form fields, free text, uploads.

  Form *typing* (`phx-change`, recognisable by its `"_target"` parameter) is
  not recorded at all, and neither are event names listed in the
  `web_analytics_ignore_events` setting. The same event repeated within a
  second on one page counts once, so a double-click or a key held down is one
  interaction.

  Events handled by a LiveComponent (`phx-target={@myself}`) run in the
  component, not the LiveView, and are not seen by this hook.

  ## Do Not Track

  The socket can't see request headers, so the plug notes a `DNT: 1` /
  `Sec-GPC: 1` visitor in the session and this hook reads it from there; such
  a visitor's LiveView activity is not recorded either. That needs the plug to
  run after `:fetch_session`, as it does in a standard `:browser` pipeline.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, get_connect_info: 2, get_connect_params: 1]

  alias PhoenixKitWebAnalytics.BotSignals
  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.LivePresence
  alias PhoenixKitWebAnalytics.Referrer
  alias PhoenixKitWebAnalytics.Tracking
  alias PhoenixKitWebAnalytics.UserAgent

  @hook_name :phoenix_kit_web_analytics
  @client_key :__phoenix_kit_web_analytics_client
  @state_key :__phoenix_kit_web_analytics_state

  # The same event within this window on one page counts once.
  @repeat_window_ms 1_000
  @max_param_value 60

  @doc """
  `on_mount` callback. Use `:track_navigation`.
  """
  @spec on_mount(
          :track_navigation,
          map() | :not_mounted_at_router,
          map(),
          Phoenix.LiveView.Socket.t()
        ) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:track_navigation, _params, session, socket) do
    if Phoenix.LiveView.connected?(socket) and not opted_out?(session) do
      mount_connected(socket)
    else
      # The dead render is an ordinary HTTP response — the plug has it.
      {:cont, socket}
    end
  end

  defp mount_connected(socket) do
    case client_info(socket) do
      nil ->
        {:cont, socket}

      client ->
        socket =
          socket
          |> assign(@client_key, client)
          |> assign(@state_key, %{
            first?: true,
            live_navigation?: live_navigation?(socket),
            live_referer: live_referer(socket),
            uri: nil,
            last_event: nil
          })
          |> attach_hook(@hook_name, :handle_params, &handle_params/3)
          |> attach_hook(@hook_name, :handle_event, &handle_event/3)

        {:cont, socket}
    end
  end

  defp handle_params(_params, uri, socket) do
    state = socket.assigns[@state_key]
    parsed = URI.parse(uri)
    path = parsed.path || "/"

    cond do
      state.first? ->
        # The connected mount's own handle_params. Counted only when the
        # visitor got here by live navigation; a page load was already
        # recorded by the plug during the dead render.
        if state.live_navigation?, do: track_pageview(socket, parsed, state.live_referer)

        if watchable?(path, socket.assigns[@client_key]) do
          LivePresence.watch(self(), socket.assigns[@client_key], %{
            path: path,
            site: Referrer.normalize_host(parsed.host),
            user_uuid: Tracking.current_user_uuid(socket.assigns),
            referrer: state.live_referer
          })
        end

      same_path?(state.uri, parsed) ->
        # A patch that only changed the query string (a filter, a page of
        # results) is the same page.
        :ok

      true ->
        track_pageview(socket, parsed, state.uri)

        if watchable?(path, socket.assigns[@client_key]) do
          LivePresence.navigate(self(), path, socket.assigns[@client_key], %{
            site: Referrer.normalize_host(parsed.host),
            user_uuid: Tracking.current_user_uuid(socket.assigns)
          })
        else
          LivePresence.unwatch(self())
        end
    end

    {:cont, assign(socket, @state_key, %{state | first?: false, uri: uri, last_event: nil})}
  end

  defp handle_event(event, params, socket) do
    state = socket.assigns[@state_key]
    now = System.monotonic_time(:millisecond)

    if record_event?(event, params, state, now) do
      track_interaction(socket, event, params, state.uri)
      {:cont, assign(socket, @state_key, %{state | last_event: {event, now}})}
    else
      {:cont, socket}
    end
  end

  # ── what gets recorded ────────────────────────────────────────────────────

  defp record_event?(event, params, state, now) do
    is_binary(event) and is_binary(state.uri) and not form_change?(params) and
      not repeated?(state.last_event, event, now) and
      not Config.ignored_event?(event)
  end

  # LiveView adds `_target` to the params of every phx-change event.
  defp form_change?(%{"_target" => _}), do: true
  defp form_change?(_params), do: false

  defp repeated?({event, at}, event, now), do: now - at < @repeat_window_ms
  defp repeated?(_last, _event, _now), do: false

  defp track_pageview(socket, parsed, referrer) do
    path = parsed.path || "/"

    if trackable_path?(path) do
      client = socket.assigns[@client_key] || %{}

      Collector.track_async(%{
        event_type: "pageview",
        path: path,
        site: parsed.host,
        referrer: referrer,
        query_params: Tracking.campaign_params(parsed.query),
        ip: client[:ip],
        user_agent: client[:user_agent],
        language: client[:language],
        user_uuid: Tracking.current_user_uuid(socket.assigns),
        status: 200,
        metadata: %{"source" => "live_navigation"}
      })
    end
  end

  defp track_interaction(socket, event, params, uri) do
    parsed = URI.parse(uri)
    path = parsed.path || "/"

    if trackable_path?(path) do
      client = socket.assigns[@client_key] || %{}

      Collector.track_async(%{
        event_type: "interaction",
        event_name: event,
        path: path,
        site: parsed.host,
        ip: client[:ip],
        user_agent: client[:user_agent],
        language: client[:language],
        user_uuid: Tracking.current_user_uuid(socket.assigns),
        metadata: interaction_metadata(params)
      })
    end
  end

  defp interaction_metadata(params) do
    base = %{"source" => "live_event"}

    case recorded_params(params) do
      empty when map_size(empty) == 0 -> base
      values -> Map.put(base, "params", values)
    end
  end

  # Only allow-listed names, only short scalar values. Nothing else in the
  # params is ever copied out of the LiveView process.
  defp recorded_params(params) when is_map(params) do
    allowed = Config.event_params()

    params
    |> Map.take(allowed)
    |> Enum.flat_map(fn
      {key, value} when is_binary(value) and value != "" ->
        [{key, String.slice(value, 0, @max_param_value)}]

      {key, value} when is_integer(value) or is_boolean(value) ->
        [{key, to_string(value)}]

      _ ->
        []
    end)
    |> Map.new()
  end

  defp recorded_params(_params), do: %{}

  defp trackable_path?(path) do
    config = Config.collection_config()
    config.enabled? and not Config.excluded?(path, config.exclusions)
  end

  # What "Right now" lists, and so what a leave is recorded for, follows the
  # same rules as a page view: tracking on, the path not excluded, and no
  # automated visitor unless bots are being recorded.
  defp watchable?(path, client) do
    config = Config.collection_config()

    config.enabled? and not Config.excluded?(path, config.exclusions) and
      (config.track_bots? or not UserAgent.bot?(client && client[:user_agent]))
  end

  defp same_path?(nil, _parsed), do: false
  defp same_path?(previous, parsed), do: URI.parse(previous).path == parsed.path

  # ── connection facts ──────────────────────────────────────────────────────

  defp opted_out?(session) when is_map(session), do: session[Tracking.dnt_session_key()] == true
  defp opted_out?(_session), do: false

  # nil (rather than an empty map) signals "can't identify this visitor the same
  # way the plug would" — see the moduledoc. A socket that has both inputs but
  # sits behind a proxy without `:x_headers` is counted as skipped, which
  # pauses the no-JavaScript bot judgement while visits are being missed.
  defp client_info(socket) do
    user_agent = get_connect_info(socket, :user_agent)
    peer_data = get_connect_info(socket, :peer_data)

    with {ua, %{address: _}} when is_binary(ua) <- {user_agent, peer_data},
         ip when not is_nil(ip) <- counted(Tracking.socket_ip(socket)) do
      %{
        ip: ip,
        user_agent: ua,
        language: accept_language(get_connect_info(socket, :x_headers))
      }
    else
      _ -> nil
    end
  end

  defp counted(nil) do
    BotSignals.count_live_visit(:skipped)
    nil
  end

  defp counted(ip) do
    BotSignals.count_live_visit(:tracked)
    ip
  end

  # Only `x-`-prefixed headers reach `:x_headers`, so this finds a language
  # only when a proxy forwards one that way; otherwise the collector carries
  # the session's language over from its page view.
  defp accept_language(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {"x-accept-language", value} -> value
      _ -> nil
    end)
  end

  defp accept_language(_headers), do: nil

  # `_live_referer` is sent only by a live navigation; `_mounts` is 0 on the
  # first join of a view and goes up on every reconnect, so requiring both
  # keeps a reconnect of a live-navigated page from counting twice.
  defp live_navigation?(socket) do
    case get_connect_params(socket) do
      %{"_live_referer" => referer, "_mounts" => 0} when is_binary(referer) -> true
      _ -> false
    end
  end

  defp live_referer(socket) do
    case get_connect_params(socket) do
      %{"_live_referer" => referer} when is_binary(referer) and referer != "" -> referer
      _ -> nil
    end
  end
end
