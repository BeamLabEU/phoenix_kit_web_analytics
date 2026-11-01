defmodule PhoenixKitWebAnalytics.RequestVisitor do
  @moduledoc """
  Who is behind a request, the way this module counts visitors — for code in
  the host that needs the same identity the reports use (a rate limit, an
  abuse check, a "too many searches" guard) without re-implementing it.

      %{visitor_id: id, ip: ip, network: network} = PhoenixKitWebAnalytics.visitor(conn)

  ## What it returns

    * `:visitor_id` — the 32-hex-character ID the collector stores for this
      request's page view: the salt, the client address read by the module's
      rule (see "Client IP" in `PhoenixKitWebAnalytics.Plug`), the
      User-Agent, the configured `web_analytics_visitor_rotation` and today's
      UTC date (`PhoenixKitWebAnalytics.Visitor.visitor_id/5`). A Chrome
      Speculation-Rules prefetch gets the prefetch's own ID, as its stored
      hit does. Two hits are stored under another ID: a page view counted
      without consent (`anon:` + a fresh UUID, by design), and one whose
      write runs after midnight UTC for a request made before it. **`nil`
      when the salt can't be read** — settings unreachable,
      or the module never switched on, so no salt exists yet. This never
      creates one: nothing on a request's path writes a setting.
    * `:ip` — the client address, an `:inet` tuple.
    * `:network` — what to count an address by:
      `PhoenixKit.Utils.IpAddress.network/1`, an IPv4 address as it is and
      an IPv6 address as its `/64` (one household or phone holds the whole
      block). `"unknown"` when the address can't be read.
    * `:prefetch?` — whether the request is a speculative prefetch.

  Never raises. When something fails the result still has the peer address
  and a `nil` visitor ID.

  ## Once per request

  `put/1` computes it and keeps it in `conn.private`; `get/1` (and
  `PhoenixKitWebAnalytics.visitor/1`) return the kept one when there is one
  and compute it otherwise; `fetch/1` returns only a kept one. So a plug
  early in the pipeline (`PhoenixKitWebAnalytics.RateLimit.Plug` does) can
  compute it, and a controller later in the same request reuses it.

  ## Privacy

  Working the ID out in memory, for security, stores nothing: no row, no
  log line, no cookie. It is the same one-way hash the reports count by,
  and it changes with the rotation. **Storing it is the host's
  responsibility** — once it is kept beside other data, it is identifying
  data under that data's rules, and with `web_analytics_visitor_rotation`
  longer than a day it recognises a returning visitor across days.
  """

  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Tracking
  alias PhoenixKitWebAnalytics.Visitor

  @private_key :phoenix_kit_web_analytics_visitor

  @type t :: %{
          visitor_id: String.t() | nil,
          ip: :inet.ip_address() | nil,
          network: String.t() | nil,
          prefetch?: boolean()
        }

  @doc """
  The request's visitor — the kept one (`put/1`), or worked out now. `config`
  is a `PhoenixKitWebAnalytics.Config.collection_config/0` the caller already
  read, to save the read.
  """
  @spec get(Plug.Conn.t(), map() | nil) :: t()
  def get(%Plug.Conn{} = conn, config \\ nil) do
    case fetch(conn) do
      {:ok, visitor} -> visitor
      :error -> compute(conn, config)
    end
  end

  @doc "Works out the request's visitor and keeps it in `conn.private` (once)."
  @spec put(Plug.Conn.t(), map() | nil) :: Plug.Conn.t()
  def put(%Plug.Conn{} = conn, config \\ nil) do
    case fetch(conn) do
      {:ok, _visitor} -> conn
      :error -> Plug.Conn.put_private(conn, @private_key, compute(conn, config))
    end
  end

  @doc "The visitor `put/1` kept for this request, or `:error`."
  @spec fetch(Plug.Conn.t()) :: {:ok, t()} | :error
  def fetch(%Plug.Conn{private: private}) do
    case private do
      %{@private_key => %{} = visitor} -> {:ok, visitor}
      _ -> :error
    end
  end

  defp compute(conn, config) do
    ip = Tracking.client_ip(conn)
    bot = Tracking.prefetch_reason(conn)

    %{
      visitor_id: visitor_id(conn, ip, bot, config),
      ip: ip,
      network: network(ip),
      prefetch?: bot != nil
    }
  rescue
    _ ->
      %{visitor_id: nil, ip: conn.remote_ip, network: network(conn.remote_ip), prefetch?: false}
  end

  # The collector's recipe for a hit with an address (a request always has
  # one): the same salt, rotation and day, and the same hash input for the
  # User-Agent, prefetch included.
  defp visitor_id(conn, ip, bot, config) do
    case Config.cached_hash_salt() do
      nil ->
        nil

      salt ->
        rotation = (config || Config.collection_config()).visitor_rotation
        agent = Visitor.agent_input(Tracking.first_header(conn, "user-agent"), bot)
        Visitor.visitor_id(ip, agent, salt, Date.utc_today(), rotation)
    end
  end

  # `format_ip/1` answers "unknown" for anything that isn't an address.
  defp network(ip), do: ip |> Visitor.format_ip() |> IpAddress.network()
end
