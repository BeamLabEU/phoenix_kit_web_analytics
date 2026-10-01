defmodule PhoenixKitWebAnalytics.Tracking do
  @moduledoc false
  # Small pieces the plug and the LiveView hook both need, kept in one place so
  # an HTTP page view and a live navigation can never disagree about who the
  # user is or which campaign parameters count.

  @utm_params ~w(utm_source utm_medium utm_campaign utm_term utm_content)
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

  @doc "Campaign parameters from a raw query string; everything else is dropped."
  @spec utm_params(String.t() | nil) :: %{String.t() => String.t()}
  def utm_params(nil), do: %{}
  def utm_params(""), do: %{}

  def utm_params(query) when is_binary(query) do
    query |> URI.decode_query() |> Map.take(@utm_params)
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
