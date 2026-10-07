defmodule PhoenixKitWebAnalytics.Tracking do
  @moduledoc false
  # Small pieces the plug and the LiveView hook both need, kept in one place so
  # an HTTP page view and a live navigation can never disagree about who the
  # user is or which campaign parameters count.

  import Phoenix.LiveView, only: [get_connect_info: 2]

  require Logger

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.IpAddress

  @utm_params ~w(utm_source utm_medium utm_campaign utm_term utm_content)

  # Ad-click identifiers. An ad platform appends one of these itself when
  # auto-tagging is on, and it is the only mark a paid click leaves on the
  # URL — there is no `utm_medium=cpc` unless someone adds it by hand. Keeping
  # it is what lets a paid visit be recognised at all, and later lets a form
  # submission be reported back to the ad platform as a conversion.
  @click_params ~w(gclid gbraid wbraid msclkid fbclid ttclid li_fat_id)

  # Which platform a click identifier belongs to, named as
  # `PhoenixKitWebAnalytics.Referrer` names it, so a paid and an organic visit
  # from the same platform share one source.
  @click_sources %{
    "gclid" => "Google",
    "gbraid" => "Google",
    "wbraid" => "Google",
    "msclkid" => "Bing",
    "fbclid" => "Facebook",
    "ttclid" => "TikTok",
    "li_fat_id" => "LinkedIn"
  }

  # Identifiers a platform adds to ad clicks only. `fbclid` is not one: Meta
  # appends it to organic link clicks as well, so it says "came from
  # Facebook", not "clicked an ad".
  @paid_click_params ~w(gclid gbraid wbraid msclkid ttclid li_fat_id)
  @dnt_session_key "phoenix_kit_web_analytics_dnt"

  @doc "The five `utm_*` names. Everything read off a URL is `campaign_param_names/0`."
  @spec utm_param_names() :: [String.t()]
  def utm_param_names, do: @utm_params

  @doc """
  The session key the plug sets for a `DNT` / `Sec-GPC` visitor, so the
  LiveView hook — which can't see request headers — honours it too.
  """
  @spec dnt_session_key() :: String.t()
  def dnt_session_key, do: @dnt_session_key

  @doc "The ad-click identifier names read out of a query string."
  @spec click_param_names() :: [String.t()]
  def click_param_names, do: @click_params

  @doc "Every parameter name worth keeping off a URL: campaign plus ad click."
  @spec campaign_param_names() :: [String.t()]
  def campaign_param_names, do: @utm_params ++ @click_params

  @doc """
  The ad platform an identifier belongs to, or `nil` for an unknown name.

      iex> PhoenixKitWebAnalytics.Tracking.click_source("gclid")
      "Google"
  """
  @spec click_source(String.t()) :: String.t() | nil
  def click_source(name) when is_binary(name), do: Map.get(@click_sources, name)

  @doc """
  Whether an identifier marks an ad click on its own. `fbclid` doesn't: Meta
  adds it to organic link clicks too.
  """
  @spec paid_click?(String.t()) :: boolean()
  def paid_click?(name) when is_binary(name), do: name in @paid_click_params

  @doc "Campaign parameters from a raw query string; everything else is dropped."
  @spec utm_params(String.t() | nil) :: %{String.t() => String.t()}
  def utm_params(query), do: take_params(query, @utm_params)

  @doc """
  Campaign and ad-click parameters from a raw query string.

  Same contract as `utm_params/1` — a malformed query yields an empty map
  rather than raising, because losing the whole hit over a stray `%ZZ` in
  someone else's link is never the right trade.
  """
  @spec campaign_params(String.t() | nil) :: %{String.t() => String.t()}
  def campaign_params(query), do: take_params(query, campaign_param_names())

  defp take_params(nil, _keep), do: %{}
  defp take_params("", _keep), do: %{}

  defp take_params(query, keep) when is_binary(query) do
    query |> URI.decode_query() |> Map.take(keep)
  rescue
    ArgumentError -> %{}
  end

  @doc """
  The client address used for the visitor hash, by the rule core's
  `PhoenixKit.Utils.IpAddress.client_address/1` follows for a login: a
  public `conn.remote_ip` is the visitor (core's answer; a `RemoteIp` plug
  may already have rewritten it), and behind a private or loopback peer — a
  reverse proxy on the same box or network — the **last** `X-Forwarded-For`
  entry (the one that proxy appended), then `X-Real-IP` when there is no
  readable `X-Forwarded-For`.

  A proxy that appends the port (`203.0.113.7:51234`, `[2001:db8::7]:443`)
  is read too. An IPv4-mapped address (`::ffff:a.b.c.d`) comes back as IPv4.
  One implementation for the plug and the beacon, so a page load and its
  beacon hits hash to the same visitor.
  """
  @spec client_ip(Plug.Conn.t()) :: :inet.ip_address()
  def client_ip(%Plug.Conn{remote_ip: peer} = conn) do
    ip =
      if local?(peer),
        do: forwarded_ip(conn.req_headers),
        else: conn |> IpAddress.client_address() |> parse_ip()

    unmap(ip || peer)
  rescue
    _ -> unmap(conn.remote_ip)
  end

  @doc """
  The same rule for a LiveView socket, read from its connect info during
  mount; a public peer is core's
  `PhoenixKit.Utils.IpAddress.client_address_from_socket/1` answer.

  `nil` when the socket can't name the visitor: no `:peer_data`, or a
  private or loopback peer on an endpoint whose `connect_info` doesn't list
  `:x_headers` — a proxy, a container network or localhost, which can't be
  told apart without the headers. The caller records nothing rather than a
  wrong address. With `:x_headers` listed and no forwarded header in them
  (development, a LAN without a proxy), the peer is the visitor, as it is
  for the plug.
  """
  @spec socket_ip(Phoenix.LiveView.Socket.t()) :: :inet.ip_address() | nil
  def socket_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: peer} when is_tuple(peer) -> socket_peer_ip(socket, peer)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp socket_peer_ip(socket, peer) do
    headers = get_connect_info(socket, :x_headers)

    cond do
      not local?(peer) ->
        unmap(parse_ip(IpAddress.client_address_from_socket(socket)) || peer)

      is_nil(headers) ->
        nil

      true ->
        unmap(forwarded_ip(headers) || peer)
    end
  end

  # Behind a private peer the headers are read here, not taken from core: a
  # core that can't parse a port (2.55 and earlier) passes over such an
  # `X-Forwarded-For` and answers with `X-Real-IP` — a header the visitor may
  # have sent themselves. The rule is core's own, so on a core that parses
  # ports the two agree.
  #
  # A copy of core's ranges for a proxy — `local?/1` is private there.
  defp local?({127, _, _, _}), do: true
  defp local?({10, _, _, _}), do: true
  defp local?({192, 168, _, _}), do: true
  defp local?({172, b, _, _}) when b in 16..31, do: true
  defp local?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp local?({0, 0, 0, 0, 0, 65_535, _, _} = mapped), do: local?(unmap(mapped))
  defp local?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp local?(_ip), do: false

  # Every `X-Forwarded-For` line, in order, as one list: the last entry is the
  # one the nearest proxy appended. `X-Real-IP` after that.
  defp forwarded_ip(headers) do
    forwarded_for =
      for {"x-forwarded-for", value} <- headers, is_binary(value), do: value

    real_ip = for {"x-real-ip", value} <- headers, is_binary(value), do: value

    last_forwarded(forwarded_for) || real_ip |> List.first() |> header_ip()
  end

  defp last_forwarded([]), do: nil

  defp last_forwarded(values),
    do: values |> Enum.join(",") |> String.split(",") |> List.last() |> header_ip()

  defp header_ip(nil), do: nil
  defp header_ip(value), do: value |> String.trim() |> strip_port() |> parse_ip()

  # Only the two unambiguous forms lose a port: `a.b.c.d:port` and
  # `[v6]:port`. A bare IPv6 address is left alone — `2001:db8::1:443` is a
  # valid address, not one with a port.
  defp strip_port(value) do
    cond do
      Regex.match?(~r/^\d{1,3}(\.\d{1,3}){3}:\d+$/, value) ->
        value |> String.split(":") |> hd()

      match = Regex.run(~r/^\[(.+)\](:\d+)?$/, value, capture: :all_but_first) ->
        hd(match)

      true ->
        value
    end
  end

  defp parse_ip(value) when is_binary(value) and value != "" do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> ip
      {:error, _} -> nil
    end
  end

  defp parse_ip(_value), do: nil

  defp unmap({0, 0, 0, 0, 0, 65_535, ab, cd}),
    do: {div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)}

  defp unmap(ip), do: ip

  @doc """
  Warns, once at start, about `trust_x_forwarded_for: true`: it no longer
  does anything. A forwarded header from a private peer is always read, and
  one from a public peer (a CDN in front of the site) never is — that needs
  a `RemoteIp` plug. An explicit `false` asks for nothing that changed.
  """
  @spec warn_deprecated_config() :: :ok
  def warn_deprecated_config do
    if Application.get_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for) == true do
      Logger.warning(
        "[WebAnalytics] config :phoenix_kit_web_analytics, trust_x_forwarded_for: true is " <>
          "deprecated and has no effect. X-Forwarded-For from a private or loopback peer is " <>
          "always read (its last entry); behind a CDN or a proxy with a public address, add " <>
          "a RemoteIp plug before PhoenixKitWebAnalytics.Plug. Remove the setting."
      )
    end

    :ok
  end

  @doc """
  Truncates to at most `max` bytes without splitting a UTF-8 character — a
  cut mid-character is invalid UTF-8, which Postgres rejects, losing the hit.
  """
  @spec truncate_utf8(String.t(), non_neg_integer()) :: String.t()
  def truncate_utf8(value, max) when byte_size(value) <= max, do: value

  def truncate_utf8(value, max) do
    value |> binary_part(0, max) |> drop_partial_codepoint()
  end

  # Walks back over at most three continuation bytes until the prefix is valid.
  defp drop_partial_codepoint(binary) do
    if String.valid?(binary) or binary == "" do
      binary
    else
      binary |> binary_part(0, byte_size(binary) - 1) |> drop_partial_codepoint()
    end
  end

  @doc "The logged-in user's UUID from conn or socket assigns, or nil."
  @spec current_user_uuid(map()) :: String.t() | nil
  def current_user_uuid(%{phoenix_kit_current_user: %{uuid: uuid}}), do: uuid
  def current_user_uuid(%{phoenix_kit_current_scope: %{user: %{uuid: uuid}}}), do: uuid
  def current_user_uuid(_assigns), do: nil

  @doc """
  The roles the signed-in user really holds, from the scope in conn or
  socket assigns — `PhoenixKit.Users.Auth.Scope.held_roles/1`, so a user
  acting as one of their roles still counts as all of them. `nil` without a
  signed-in scope (the collector then goes by the user's UUID alone).
  """
  @spec current_roles(map()) :: [String.t()] | nil
  def current_roles(%{phoenix_kit_current_scope: %Scope{user: %{uuid: uuid}} = scope})
      when is_binary(uuid) do
    if Code.ensure_loaded?(Scope) and function_exported?(Scope, :held_roles, 1),
      do: Scope.held_roles(scope),
      else: Scope.user_roles(scope)
  rescue
    _ -> nil
  end

  def current_roles(_assigns), do: nil
end
