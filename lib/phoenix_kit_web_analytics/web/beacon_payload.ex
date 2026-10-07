defmodule PhoenixKitWebAnalytics.Web.BeaconPayload do
  @moduledoc """
  Turns an untrusted beacon payload into a hit map for
  `PhoenixKitWebAnalytics.Collector`.

  This is the trust boundary for the two public collection endpoints, kept out
  of the controller so it can be tested directly for exactly the things that
  matter: what a client can and cannot influence.

  A client controls only the **content** of a hit — which path, which event
  name, which properties. It cannot influence **identity**:

    * only the path is read from the client's URL; scheme and host are dropped
      (campaign parameters and an ad-click identifier are read from its query
      string — so a beacon-recorded `click_id` is client-supplied, like any
      landing URL)
    * `user_uuid` is never read from the body (the collection endpoints run
      without a session, so beacon hits are never attributed to a user)
    * `visitor_id` is derived server-side downstream and isn't representable
      here at all
    * the event type is one of a fixed set, and a click's kind one of a fixed
      set; anything else is dropped

  `site` is the request's `Host` header — the same thing the plug records.
  Like every client-side analytics endpoint, a caller can send any `Host`; a
  host that serves many domains should put a canonical-host redirect in front.

  ## Payload

  Compact keys, as sent by `<.beacon />` and the optional client script:

    * `e` — `"pageview"`, `"event"`, `"click"`, `"scroll"` or `"leave"`
    * `n` — custom event name (`"event"`)
    * `p` — the page URL; `t` its title; `r` the referrer
    * `props` — custom event properties
    * `k` — a click's kind: `"click"`, `"outbound"`, `"download"`, `"contact"`;
      `x` — what was clicked (a host + path, a file name, a label)
    * `ms` — visible time on the page (`"leave"`); `sd` — scroll depth 0–100

  Free-form content is capped so an unbounded jsonb blob per event can't turn
  the analytics table into the largest one in the database: 20 properties,
  200 bytes per value, 120 bytes of event name.
  """

  alias PhoenixKitWebAnalytics.Tracking

  @max_props 20
  @max_prop_bytes 200
  @click_kinds ~w(click outbound download contact)
  # A leave reported longer than this after the page opened is clamped; the
  # client measures visible time, so larger values are a broken or hostile
  # client.
  @max_engaged_ms 4 * 60 * 60 * 1000

  @doc """
  Builds the hit map for `params` received on `conn`.

  Never raises: every field degrades to `nil` or a default, because the caller
  is a public endpoint that must answer 204 no matter what it was sent.
  """
  @spec to_hit(Plug.Conn.t(), map()) :: map()
  def to_hit(conn, params) when is_map(params) do
    # Every hit carries the same keys, so a caller never has to ask which
    # kind it got before reading one. `user_uuid` is always nil here.
    base = %{
      event_name: nil,
      user_uuid: nil,
      path: path(params["p"]),
      site: conn.host,
      ip: Tracking.client_ip(conn),
      user_agent: header(conn, "user-agent"),
      language: header(conn, "accept-language")
    }

    Map.merge(base, kind_attrs(kind(params), params))
  end

  def to_hit(conn, _params), do: to_hit(conn, %{})

  @doc """
  What the payload reports: `:pageview`, `:event`, `:click`, `:scroll` or
  `:leave` — or `:unknown` for anything else, which is not stored. An
  `"event"` needs a non-empty name `n`; a payload with only a name is an
  event too (the 0.2 snippet's shape).
  """
  @spec kind(map()) :: :pageview | :event | :click | :scroll | :leave | :automation | :unknown
  def kind(%{"e" => "pageview"}), do: :pageview
  def kind(%{"e" => "click"}), do: :click
  def kind(%{"e" => "scroll"}), do: :scroll
  def kind(%{"e" => "leave"}), do: :leave
  # The client script's report that the browser is under automation.
  def kind(%{"e" => "automation"}), do: :automation

  def kind(%{"e" => e, "n" => name}) when e in ["event", nil] and is_binary(name) and name != "",
    do: :event

  def kind(%{"n" => name} = params)
      when is_binary(name) and name != "" and not is_map_key(params, "e"),
      do: :event

  def kind(_params), do: :unknown

  @doc """
  Whether the payload is one of the client script's hits (clicks, scroll,
  leave), which are accepted only with the client script switched on — as
  opposed to the beacon's page views and custom events.
  """
  @spec client_script_hit?(map()) :: boolean()
  def client_script_hit?(params), do: kind(params) in [:click, :scroll, :leave]

  @doc """
  The event type a payload is stored as — `"pageview"` or `"event"`, kept for
  callers of the 0.2 API.
  """
  @spec event_type(map()) :: String.t()
  def event_type(params) do
    case kind(params) do
      :event -> "event"
      _ -> "pageview"
    end
  end

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
  end

  def path(_url), do: "/"

  @doc """
  Extracts campaign parameters and ad-click identifiers from a client-sent
  URL's query string (`Tracking.campaign_params/1`; the name predates the
  identifiers).
  """
  @spec utm_params(term()) :: map()
  def utm_params(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{query: query} when is_binary(query) -> Tracking.campaign_params(query)
      _ -> %{}
    end
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

  defp kind_attrs(:pageview, params) do
    %{
      event_type: "pageview",
      page_title: truncate(params["t"], 512),
      referrer: truncate(params["r"], 2048),
      query_params: utm_params(params["p"]),
      status: 200,
      metadata: %{"source" => "beacon"}
    }
  end

  # `to_hit/2` called directly with a shapeless payload (the controller drops
  # those before this point) describes it as a page view, as 0.2 did.
  defp kind_attrs(:unknown, params), do: kind_attrs(:pageview, params)

  defp kind_attrs(:event, params) do
    %{
      event_type: "event",
      event_name: truncate(params["n"], 120),
      page_title: truncate(params["t"], 512),
      metadata: props(params["props"])
    }
  end

  defp kind_attrs(:click, params) do
    kind = if params["k"] in @click_kinds, do: params["k"], else: "click"

    %{
      event_type: "interaction",
      event_name: kind,
      target: truncate(params["x"], 512),
      metadata: %{"source" => "client_script"}
    }
  end

  defp kind_attrs(:scroll, params) do
    %{
      event_type: "interaction",
      event_name: "scroll",
      scroll_depth: percent(params["sd"]),
      metadata: %{"source" => "client_script"}
    }
  end

  defp kind_attrs(:leave, params) do
    engaged_ms = milliseconds(params["ms"])
    now = DateTime.utc_now()

    %{
      event_type: "leave",
      engaged_ms: engaged_ms,
      scroll_depth: percent(params["sd"]),
      # The leave belongs to the session its page view opened.
      session_anchor: DateTime.add(now, -(engaged_ms || 0), :millisecond),
      inserted_at: now,
      metadata: %{"source" => "client_script"}
    }
  end

  defp percent(value) when is_integer(value), do: value |> max(0) |> min(100)
  defp percent(value) when is_float(value), do: value |> round() |> percent()
  defp percent(_value), do: nil

  defp milliseconds(value) when is_integer(value), do: value |> max(0) |> min(@max_engaged_ms)
  defp milliseconds(value) when is_float(value), do: value |> round() |> milliseconds()
  defp milliseconds(_value), do: nil

  defp cap_value(value) when is_binary(value), do: truncate(value, @max_prop_bytes)
  defp cap_value(value) when is_number(value) or is_boolean(value), do: value
  defp cap_value(nil), do: nil
  defp cap_value(value), do: value |> inspect() |> truncate(@max_prop_bytes)

  defp truncate(value, max) when is_binary(value), do: Tracking.truncate_utf8(value, max)
  defp truncate(_value, _max), do: nil

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
