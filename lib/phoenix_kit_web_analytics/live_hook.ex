defmodule PhoenixKitWebAnalytics.LiveHook do
  @moduledoc """
  Counts LiveView navigations as page views.

  `PhoenixKitWebAnalytics.Plug` sees HTTP requests, which covers the first load
  of a LiveView page but not what happens afterwards: `push_patch`,
  `push_navigate`, and `<.link patch={…}>` change the URL over the socket
  without ever touching the router. Without this hook a LiveView-heavy app
  reports one page view per session and nothing else.

  Attach it in the host's `live_session`:

      live_session :public,
        on_mount: [{PhoenixKitWebAnalytics.LiveHook, :track_navigation}] do
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
        websocket: [connect_info: [:peer_data, :user_agent, session: @session_options]]

  Both keys must be listed. If either is missing the hook stays inert and only
  full page loads are counted — check this first if LiveView navigations aren't
  showing up.

  ## Not double-counted

  On a normal page load the dead render already produced a tracked HTTP
  response, so the hook ignores the `handle_params` that follows the connected
  mount. It tells that case apart from a `push_navigate` remount (which has no
  HTTP request behind it, and *is* counted) using LiveView's `_mounts` connect
  parameter.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, get_connect_info: 2, get_connect_params: 1]

  alias PhoenixKitWebAnalytics.Collector

  @hook_name :phoenix_kit_web_analytics
  @client_key :__phoenix_kit_web_analytics_client
  @skip_key :__phoenix_kit_web_analytics_skip_next
  @last_uri_key :__phoenix_kit_web_analytics_last_uri

  @doc """
  `on_mount` callback. Use `:track_navigation`.
  """
  def on_mount(:track_navigation, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket) do
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
          |> assign(@skip_key, first_mount?(socket))
          |> assign(@last_uri_key, nil)
          |> attach_hook(@hook_name, :handle_params, &handle_params/3)

        {:cont, socket}
    end
  end

  defp handle_params(_params, uri, socket) do
    if socket.assigns[@skip_key] do
      # This is the connected mount's own handle_params, for a URL the plug
      # already recorded during the dead render.
      {:cont, socket |> assign(@skip_key, false) |> assign(@last_uri_key, uri)}
    else
      track(socket, uri)
      {:cont, assign(socket, @last_uri_key, uri)}
    end
  end

  defp track(socket, uri) do
    parsed = URI.parse(uri)
    client = socket.assigns[@client_key] || %{}

    Collector.track_async(%{
      event_type: "pageview",
      path: parsed.path || "/",
      site: parsed.host,
      referrer: socket.assigns[@last_uri_key],
      query_params: utm_params(parsed.query),
      ip: client[:ip],
      user_agent: client[:user_agent],
      language: client[:language],
      user_uuid: current_user_uuid(socket),
      status: 200,
      metadata: %{"source" => "live_navigation"}
    })
  end

  # nil (rather than an empty map) signals "can't identify this visitor the same
  # way the plug would" — see the moduledoc.
  defp client_info(socket) do
    user_agent = get_connect_info(socket, :user_agent)
    peer_data = get_connect_info(socket, :peer_data)

    case {user_agent, peer_data} do
      {ua, %{address: address}} when is_binary(ua) ->
        %{ip: address, user_agent: ua, language: accept_language(socket)}

      _ ->
        nil
    end
  end

  defp accept_language(socket) do
    case get_connect_info(socket, :x_headers) do
      headers when is_list(headers) ->
        Enum.find_value(headers, fn
          {"accept-language", value} -> value
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  # LiveView increments `_mounts` for every remount within one page load, so 0
  # means "this socket just connected for a freshly served HTML page".
  defp first_mount?(socket) do
    case get_connect_params(socket) do
      %{"_mounts" => mounts} when is_integer(mounts) -> mounts == 0
      # Unknown: assume a page load, since over-counting is the worse failure.
      _ -> true
    end
  end

  defp utm_params(nil), do: %{}

  defp utm_params(query) do
    query
    |> URI.decode_query()
    |> Map.take(~w(utm_source utm_medium utm_campaign utm_term utm_content))
  rescue
    _ -> %{}
  end

  defp current_user_uuid(socket) do
    case socket.assigns do
      %{phoenix_kit_current_user: %{uuid: uuid}} -> uuid
      %{phoenix_kit_current_scope: %{user: %{uuid: uuid}}} -> uuid
      _ -> nil
    end
  end
end
