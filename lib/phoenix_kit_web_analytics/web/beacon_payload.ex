defmodule PhoenixKitWebAnalytics.Web.BeaconPayload do
  @moduledoc """
  Turns an untrusted beacon payload into a hit map for
  `PhoenixKitWebAnalytics.Collector`.

  This is the trust boundary for the two public collection endpoints, kept out
  of the controller so it can be tested directly for exactly the things that
  matter: what a client can and cannot influence.

  A client controls only the **content** of a hit — which path, which event
  name, which properties. It cannot influence **identity or origin**:

    * `site` is `conn.host`, so a payload can't attribute hits to another site
    * only the path is read from the client's URL; scheme and host are dropped
    * `user_uuid` comes from the session, never from the body
    * `visitor_id` is derived server-side downstream and isn't representable
      here at all

  Free-form content is capped so an unbounded jsonb blob per event can't turn
  the analytics table into the largest one in the database: 20 properties,
  200 bytes per value, 120 bytes of event name.
  """

  @max_props 20
  @max_prop_bytes 200
  @utm_params ~w(utm_source utm_medium utm_campaign utm_term utm_content)

  @doc """
  Builds the hit map for `params` received on `conn`.

  Never raises: every field degrades to `nil` or a default, because the caller
  is a public endpoint that must answer 204 no matter what it was sent.
  """
  @spec to_hit(Plug.Conn.t(), map()) :: map()
  def to_hit(conn, params) when is_map(params) do
    event_type = event_type(params)

    %{
      event_type: event_type,
      event_name: if(event_type == "event", do: truncate(params["n"], 120)),
      path: path(params["p"]),
      page_title: truncate(params["t"], 512),
      site: conn.host,
      referrer: truncate(params["r"], 2048),
      query_params: utm_params(params["p"]),
      ip: conn.remote_ip,
      user_agent: header(conn, "user-agent"),
      language: header(conn, "accept-language"),
      user_uuid: current_user_uuid(conn),
      status: 200,
      metadata: props(params["props"])
    }
  end

  def to_hit(conn, _params), do: to_hit(conn, %{})

  @doc """
  Whether the payload describes a custom event or a page view.

  A payload with a non-empty `n` is an event; everything else — including an
  explicit `"e" => "pageview"` — is a page view.
  """
  @spec event_type(map()) :: String.t()
  def event_type(%{"e" => "pageview"}), do: "pageview"
  def event_type(%{"n" => name}) when is_binary(name) and name != "", do: "event"
  def event_type(_params), do: "pageview"

  @doc """
  Extracts just the path from a client-sent URL.

  Anything that isn't an absolute path becomes `"/"` — `URI.parse/1` happily
  reports a bare word as a relative path, and a "path" that doesn't start with
  a slash would corrupt every pages report it appeared in.

      iex> PhoenixKitWebAnalytics.Web.BeaconPayload.path("https://evil.example/steal?x=1")
      "/steal"

      iex> PhoenixKitWebAnalytics.Web.BeaconPayload.path("garbage")
      "/"
  """
  @spec path(term()) :: String.t()
  def path(url) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{path: "/" <> _ = path} -> path
      _ -> "/"
    end
  rescue
    _ -> "/"
  end

  def path(_url), do: "/"

  @doc "Extracts campaign parameters from a client-sent URL's query string."
  @spec utm_params(term()) :: map()
  def utm_params(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{query: query} when is_binary(query) ->
        query |> URI.decode_query() |> Map.take(@utm_params)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  def utm_params(_url), do: %{}

  @doc "Caps custom event properties by count, key length, and value size."
  @spec props(term()) :: map()
  def props(props) when is_map(props) do
    props
    |> Enum.filter(fn {key, _value} -> is_binary(key) end)
    |> Enum.take(@max_props)
    |> Map.new(fn {key, value} -> {truncate(key, 60), cap_value(value)} end)
  end

  def props(_props), do: %{}

  # ── internals ─────────────────────────────────────────────────────────────

  defp cap_value(value) when is_binary(value), do: truncate(value, @max_prop_bytes)
  defp cap_value(value) when is_number(value) or is_boolean(value), do: value
  defp cap_value(nil), do: nil
  defp cap_value(value), do: value |> inspect() |> truncate(@max_prop_bytes)

  defp truncate(value, max) when is_binary(value) do
    if byte_size(value) > max, do: binary_part(value, 0, max), else: value
  end

  defp truncate(_value, _max), do: nil

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp current_user_uuid(conn) do
    case conn.assigns do
      %{phoenix_kit_current_user: %{uuid: uuid}} -> uuid
      %{phoenix_kit_current_scope: %{user: %{uuid: uuid}}} -> uuid
      _ -> nil
    end
  end
end
