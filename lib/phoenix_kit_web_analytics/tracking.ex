defmodule PhoenixKitWebAnalytics.Tracking do
  @moduledoc false
  # Small pieces the plug and the LiveView hook both need, kept in one place so
  # an HTTP page view and a live navigation can never disagree about who the
  # user is or which campaign parameters count.

  @utm_params ~w(utm_source utm_medium utm_campaign utm_term utm_content)

  # Ad-click identifiers. An ad platform appends one of these itself when
  # auto-tagging is on, and it is the only mark a paid click leaves on the
  # URL — there is no `utm_medium=cpc` unless someone adds it by hand. Keeping
  # it is what lets a paid visit be recognised at all, and later lets a form
  # submission be reported back to the ad platform as a conversion.
  @click_params ~w(gclid gbraid wbraid msclkid fbclid ttclid li_fat_id)

  # Which platform a click identifier belongs to.
  @click_sources %{
    "gclid" => "google",
    "gbraid" => "google",
    "wbraid" => "google",
    "msclkid" => "bing",
    "fbclid" => "facebook",
    "ttclid" => "tiktok",
    "li_fat_id" => "linkedin"
  }

  # Identifiers a platform adds to ad clicks only. `fbclid` is not one: Meta
  # appends it to organic link clicks as well, so it says "came from
  # Facebook", not "clicked an ad".
  @paid_click_params ~w(gclid gbraid wbraid msclkid ttclid li_fat_id)
  @dnt_session_key "phoenix_kit_web_analytics_dnt"

  @doc "The campaign parameter names read out of a query string."
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
      "google"
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
  The client address used for the visitor hash — `conn.remote_ip`, or the
  first `X-Forwarded-For` entry when `trust_x_forwarded_for` is configured.
  One implementation for the plug and the beacon, so a page load and its
  beacon hits hash to the same visitor behind a proxy.
  """
  @spec client_ip(Plug.Conn.t()) :: :inet.ip_address()
  def client_ip(%Plug.Conn{} = conn) do
    if trust_forwarded?() do
      conn |> Plug.Conn.get_req_header("x-forwarded-for") |> List.first() |> forwarded_ip() ||
        conn.remote_ip
    else
      conn.remote_ip
    end
  end

  @doc """
  The same rule for a LiveView socket: the peer address, or the first
  `X-Forwarded-For` entry from `connect_info`'s `:x_headers` when configured
  (list `:x_headers` in the endpoint's `connect_info` for that).
  """
  @spec socket_ip(:inet.ip_address(), list() | nil) :: :inet.ip_address()
  def socket_ip(peer_address, x_headers) do
    with true <- trust_forwarded?(),
         headers when is_list(headers) <- x_headers,
         {_, value} <- List.keyfind(headers, "x-forwarded-for", 0),
         ip when not is_nil(ip) <- forwarded_ip(value) do
      ip
    else
      _ -> peer_address
    end
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

  defp trust_forwarded?,
    do: Application.get_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for, false)

  defp forwarded_ip(value) when is_binary(value) do
    with [first | _] <- String.split(value, ","),
         {:ok, ip} <- first |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      ip
    else
      _ -> nil
    end
  end

  defp forwarded_ip(_value), do: nil

  @doc "The logged-in user's UUID from conn or socket assigns, or nil."
  @spec current_user_uuid(map()) :: String.t() | nil
  def current_user_uuid(%{phoenix_kit_current_user: %{uuid: uuid}}), do: uuid
  def current_user_uuid(%{phoenix_kit_current_scope: %{user: %{uuid: uuid}}}), do: uuid
  def current_user_uuid(_assigns), do: nil
end
