defmodule PhoenixKitWebAnalytics.InternalTraffic do
  @moduledoc """
  Works out a hit's `PhoenixKitWebAnalytics.TrafficFlags` — whether it is
  the site's own people or their networks — without a query on the way.

    * **`internal_network`** — the client address falls in one of the
      networks in `config :phoenix_kit_web_analytics, internal_networks:
      [...]` (CIDR, IPv4 or IPv6; a bare address is one host). Parsed once
      and kept until the config changes.
    * **`admin`** — the signed-in user holds a role listed in
      `web_analytics_internal_roles` (Owner and Admin by default), by
      `PhoenixKit.Users.Auth.Scope.held_roles/1`: the roles they really
      hold, whichever one they are acting as. A hit that names only a user
      (no scope) is judged by a five-minute cache of that user's roles; on a
      miss the roles are looked up off the hit's path, so that hit goes
      unflagged and the next one — with the whole visit — gets the bit.
    * **`admin_network`** — the client's network (an IPv4 address, an IPv6
      /64, as `PhoenixKit.Utils.IpAddress.network/1` keys it) had a staff
      member signed in within the last `web_analytics_admin_network_hours`
      (24 by default; `0` turns it off). Learnt from two places: a staff
      sign-in (core's `{:session_created, …}`, which every node hears — the
      address is the session token's, so an admin who only ever works in
      the admin panel, which is never tracked, still counts) and a staff
      member's own request through `PhoenixKitWebAnalytics.Plug`, shared
      with the other nodes. Private, loopback and unparseable addresses are
      never taken.

  A network learnt this way is held in memory only, under its plain key
  (hashing it would not protect anything: the key would sit on the same
  node), and forgotten when its time is up. Nothing about it is written to
  the database or the settings.

  Behind carrier-grade NAT, a mobile network or an office gateway, one
  address is many people: a staff sign-in from a phone flags everyone
  behind the same public address for those hours. That's the trade-off of
  the `admin_network` flag, and why it can be counted back in from
  Settings or its hours set to `0`.
  """

  use GenServer

  import Bitwise
  import Ecto.Query

  require Logger

  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.TrafficFlags

  @table :phoenix_kit_web_analytics_internal_traffic
  @topic "phoenix_kit_web_analytics:admin_networks"
  @networks_key {__MODULE__, :internal_networks}
  @roles_ttl_ms :timer.minutes(5)
  # A lookup in flight blocks another for the same user this long.
  @pending_ttl_ms :timer.seconds(30)
  @token_retry_ms 2_000
  @sweep_ms :timer.minutes(10)

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # ── a hit's flags ─────────────────────────────────────────────────────────

  @doc """
  The flags of a hit: `:ip` (a tuple), `:roles` (the signed-in user's held
  roles, when the hit came with a scope) and `:user_uuid`. Never raises;
  `0` when nothing can be told.
  """
  @spec flags(map(), Config.collection_config()) :: non_neg_integer()
  def flags(hit, config) when is_map(hit) do
    network_flags(hit[:ip], config) ||| admin_flag(hit, config)
  rescue
    error ->
      Logger.debug("[WebAnalytics] traffic flags failed: #{Exception.message(error)}")
      0
  end

  @doc """
  The flags an address alone gives — `internal_network` and
  `admin_network`. What the recording endpoint can tell before it knows the
  visit.
  """
  @spec network_flags(:inet.ip_address() | nil, Config.collection_config()) :: non_neg_integer()
  def network_flags(ip, config) when is_tuple(ip) do
    internal = if internal_network?(ip), do: TrafficFlags.bit(:internal_network), else: 0
    admin_net = if admin_network?(ip, config), do: TrafficFlags.bit(:admin_network), else: 0
    internal ||| admin_net
  rescue
    _ -> 0
  end

  def network_flags(_ip, _config), do: 0

  @doc "Whether any of `roles` is a staff role under `config`."
  @spec staff?([String.t()] | nil, Config.collection_config()) :: boolean()
  def staff?(roles, config) when is_list(roles),
    do: Enum.any?(roles, &(&1 in config.internal_roles))

  def staff?(_roles, _config), do: false

  defp admin_flag(hit, config) do
    if staff?(roles_of(hit), config), do: TrafficFlags.bit(:admin), else: 0
  end

  # The hit's own roles (remembered for its user), else the cached ones;
  # a miss starts a lookup and answers nil.
  defp roles_of(%{roles: roles} = hit) when is_list(roles) do
    remember_roles(hit[:user_uuid], roles)
    roles
  end

  defp roles_of(%{user_uuid: uuid}) when is_binary(uuid) do
    case cached_roles(uuid) do
      {:ok, roles} -> roles
      :pending -> nil
      :miss -> lookup_roles(uuid)
    end
  end

  defp roles_of(_hit), do: nil

  # ── internal networks ─────────────────────────────────────────────────────

  @doc """
  Whether `ip` is in one of the configured `internal_networks`. An invalid
  entry is skipped, with one warning.
  """
  @spec internal_network?(:inet.ip_address() | nil) :: boolean()
  def internal_network?(ip) when is_tuple(ip) do
    case parsed_networks() do
      [] -> false
      networks -> with {bits, value} <- to_integer(unmap(ip)), do: in_any?(networks, bits, value)
    end
  end

  def internal_network?(_ip), do: false

  defp in_any?(networks, bits, value) do
    Enum.any?(networks, fn {net_bits, base, prefix} ->
      net_bits == bits and value >>> (bits - prefix) == base >>> (bits - prefix)
    end)
  end

  # Parsed once per configured list: the hot path reads one persistent term.
  defp parsed_networks do
    raw = Config.internal_networks()

    case :persistent_term.get(@networks_key, nil) do
      {^raw, parsed} ->
        parsed

      _ ->
        parsed = Enum.flat_map(raw, &parse_cidr/1)
        :persistent_term.put(@networks_key, {raw, parsed})
        parsed
    end
  end

  @doc """
  `"203.0.113.0/24"` → `[{32, base, 24}]`; `[]` (with a warning) for
  anything that isn't a network.
  """
  @spec parse_cidr(String.t()) :: [{32 | 128, non_neg_integer(), non_neg_integer()}]
  def parse_cidr(cidr) when is_binary(cidr) do
    {address, prefix} =
      case String.split(String.trim(cidr), "/", parts: 2) do
        [address, prefix] -> {address, Integer.parse(prefix)}
        [address] -> {address, :host}
      end

    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(address)),
         {bits, value} <- to_integer(unmap(ip)),
         len when is_integer(len) and len >= 0 and len <= bits <- prefix_length(prefix, bits) do
      [{bits, value, len}]
    else
      _ ->
        Logger.warning("[WebAnalytics] internal_networks: #{inspect(cidr)} is not a network")
        []
    end
  end

  defp prefix_length(:host, bits), do: bits
  defp prefix_length({len, ""}, _bits), do: len
  defp prefix_length(_prefix, _bits), do: nil

  defp to_integer({a, b, c, d}) do
    <<value::32>> = <<a::8, b::8, c::8, d::8>>
    {32, value}
  end

  defp to_integer({_, _, _, _, _, _, _, _} = ip) do
    <<value::128>> = for part <- Tuple.to_list(ip), into: <<>>, do: <<part::16>>
    {128, value}
  end

  defp to_integer(_ip), do: nil

  defp unmap({0, 0, 0, 0, 0, 65_535, ab, cd}),
    do: {div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)}

  defp unmap(ip), do: ip

  # ── staff networks ────────────────────────────────────────────────────────

  @doc """
  Whether `ip`'s network had a staff sign-in within the configured hours.
  """
  @spec admin_network?(:inet.ip_address() | nil, Config.collection_config()) :: boolean()
  def admin_network?(ip, %{admin_network_hours: hours}) when is_tuple(ip) and hours > 0 do
    case network(ip) do
      nil -> false
      network -> expires_at(network) > now_ms()
    end
  end

  def admin_network?(_ip, _config), do: false

  @doc """
  Notes that a staff member was seen at `ip` (a tuple or a string): its
  network counts as a staff network for the configured hours. Told to the
  other nodes only when the network is new here or past half its time, so a
  staff member browsing doesn't cost a broadcast per request. Private,
  loopback and unparseable addresses are ignored. Never raises.
  """
  @spec note_admin_network(:inet.ip_address() | String.t() | nil, Config.collection_config()) ::
          :ok
  def note_admin_network(ip, %{admin_network_hours: hours}) when hours > 0 do
    with network when is_binary(network) <- network(ip) do
      ttl = hours * 3_600_000
      now = now_ms()

      if expires_at(network) - now <= div(ttl, 2) do
        expires = now + ttl
        put_network(network, expires)
        Manager.broadcast(@topic, {:admin_network, network, expires})
      end
    end

    :ok
  rescue
    error ->
      Logger.debug("[WebAnalytics] could not note a staff network: #{Exception.message(error)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  def note_admin_network(_ip, _config), do: :ok

  @doc false
  # The network key of a public address, nil for anything else.
  @spec network(:inet.ip_address() | String.t() | nil) :: String.t() | nil
  def network(ip) when is_tuple(ip) do
    ip = unmap(ip)

    if public?(ip),
      do: ip |> :inet.ntoa() |> to_string() |> IpAddress.network(),
      else: nil
  end

  def network(ip) when is_binary(ip) do
    case :inet.parse_strict_address(String.to_charlist(String.trim(ip))) do
      {:ok, tuple} -> network(tuple)
      _ -> nil
    end
  end

  def network(_ip), do: nil

  defp public?({0, _, _, _}), do: false
  defp public?({10, _, _, _}), do: false
  defp public?({127, _, _, _}), do: false
  defp public?({169, 254, _, _}), do: false
  defp public?({172, b, _, _}) when b in 16..31, do: false
  defp public?({192, 168, _, _}), do: false
  defp public?({0, 0, 0, 0, 0, 0, 0, _}), do: false
  defp public?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: false
  defp public?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: false
  defp public?(_ip), do: true

  defp expires_at(network) do
    case :ets.lookup(@table, {:net, network}) do
      [{_, at}] -> at
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  # The later of two expiries wins: a node that heard an older note keeps
  # the newer one.
  defp put_network(network, expires) do
    if expires > expires_at(network), do: :ets.insert(@table, {{:net, network}, expires})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ── staff users ───────────────────────────────────────────────────────────

  defp cached_roles(uuid) do
    now = now_ms()

    case :ets.lookup(@table, {:roles, uuid}) do
      [{_, :pending, at}] when at > now -> :pending
      [{_, roles, at}] when at > now and is_list(roles) -> {:ok, roles}
      _ -> :miss
    end
  rescue
    ArgumentError -> :pending
  end

  defp remember_roles(uuid, roles) when is_binary(uuid) do
    if cached_roles(uuid) != {:ok, roles},
      do: :ets.insert(@table, {{:roles, uuid}, roles, now_ms() + @roles_ttl_ms})

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp remember_roles(_uuid, _roles), do: :ok

  # Off the hit's path; the pending mark keeps the hits that follow from
  # starting lookups of their own.
  defp lookup_roles(uuid) do
    :ets.insert(@table, {{:roles, uuid}, :pending, now_ms() + @pending_ttl_ms})
    Collector.run_async(fn -> remember_roles(uuid, load_roles(uuid)) end)
    nil
  rescue
    ArgumentError -> nil
  end

  defp load_roles(uuid) do
    Roles.get_user_roles(struct(User, uuid: uuid))
  end

  # A staff sign-in: the user's roles are remembered, and the network the
  # session's token was issued to is a staff network. Core broadcasts right
  # after inserting the token; if it isn't readable yet (a transaction still
  # open around the sign-in) it is read once more a moment later.
  defp session_created(user_uuid, token_uuid, attempt) do
    roles = load_roles(user_uuid)
    remember_roles(user_uuid, roles)
    config = Config.collection_config()

    if config.enabled? and config.admin_network_hours > 0 and staff?(roles, config) do
      case token_address(token_uuid) do
        {:ok, address} -> note_admin_network(address, config)
        :missing when attempt == :first -> retry_later(user_uuid, token_uuid)
        _ -> :ok
      end
    end

    :ok
  end

  defp retry_later(user_uuid, token_uuid) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      server ->
        Process.send_after(server, {:retry_token, user_uuid, token_uuid}, token_retry_ms())
    end
  end

  defp token_address(token_uuid) do
    from(t in UserToken,
      where: t.uuid == ^token_uuid,
      select: t.ip_address
    )
    |> PhoenixKit.RepoHelper.repo().one()
    |> case do
      nil -> :missing
      address -> {:ok, address}
    end
  rescue
    error ->
      Logger.debug("[WebAnalytics] could not read a session token: #{Exception.message(error)}")
      :error
  end

  defp token_retry_ms,
    do: Application.get_env(:phoenix_kit_web_analytics, :admin_token_retry_ms, @token_retry_ms)

  defp now_ms, do: System.system_time(:millisecond)

  # ── server ────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}, {:continue, :subscribe}}
  end

  @impl GenServer
  def handle_continue(:subscribe, state) do
    subscribe()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:session_created, %{uuid: user_uuid}, %{token_uuid: token_uuid}}, state)
      when is_binary(user_uuid) do
    Collector.run_async(fn -> session_created(user_uuid, to_string(token_uuid), :first) end)
    {:noreply, state}
  end

  def handle_info({:retry_token, user_uuid, token_uuid}, state) do
    Collector.run_async(fn -> session_created(user_uuid, token_uuid, :retry) end)
    {:noreply, state}
  end

  def handle_info({:admin_network, network, expires}, state)
      when is_binary(network) and is_integer(expires) do
    put_network(network, expires)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    now = now_ms()

    :ets.select_delete(@table, [
      {{{:net, :_}, :"$1"}, [{:"=<", :"$1", now}], [true]},
      {{{:roles, :_}, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}
    ])

    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  # Core's session broadcasts carry the whole user struct — only the
  # message's name is logged.
  def handle_info(message, state) do
    name = if is_tuple(message), do: inspect(elem(message, 0)), else: "a message"
    Logger.debug("[WebAnalytics] InternalTraffic ignored #{name}")
    {:noreply, state}
  end

  defp subscribe do
    Manager.subscribe(@topic)

    events = PhoenixKit.Admin.Events

    if Code.ensure_loaded?(events) and function_exported?(events, :subscribe_to_sessions, 0),
      do: events.subscribe_to_sessions()
  rescue
    error ->
      Logger.warning("[WebAnalytics] could not subscribe to staff sign-ins: #{inspect(error)}")
  end
end
