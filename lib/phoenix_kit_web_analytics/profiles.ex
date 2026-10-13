defmodule PhoenixKitWebAnalytics.Profiles do
  @moduledoc """
  What is kept about who a visitor is, and the settings that decide it.

  An event row says what happened: a page, a click, a browser family, a
  country. It never says *who* — no address, no raw User-Agent. That is the
  default and it stays the default. A site that wants more — to see which
  network a crawler comes from, to tell two scrapers apart, to have something
  to block by — switches it on here, one kind of data at a time:

  | Setting | Keeps |
  |---------|-------|
  | `web_analytics_store_ip` | the visitor's address: `off`, `truncated` (its `/24` or `/48` network) or `full` |
  | `web_analytics_store_user_agent` | the raw User-Agent string |
  | `web_analytics_store_headers` | the request headers of the visit's first page view |
  | `web_analytics_store_network` | the network's number, owner and whether it is a hosting provider |
  | `web_analytics_store_signals` | what the client script measures about the device, and a hash of it (`PhoenixKitWebAnalytics.Signals`) |

  What is on is the operator's decision and the operator's responsibility:
  an address is personal data nearly everywhere, and which of these may be
  kept without asking the visitor differs from one law to the next. The
  module takes no position — it stores exactly what the settings say, and
  nothing when they say nothing.

  ## One row per visitor ID

  A visitor ID is a hash of the address and the User-Agent, so every hit of
  one ID has the same of both. They are written once, to
  `PhoenixKitWebAnalytics.Schemas.VisitorProfile`, when a visit starts —
  after the hit's own transaction, so a profile that can't be written never
  costs the event. A later visit of the same ID refreshes `last_seen_at` and
  fills in what was missing; it never blanks what is there.

  Rows go when the visitor hasn't been seen for `web_analytics_retention_days`
  (the raw events' own horizon), in the retention pass. Switching a setting
  off stops new values being written; `forget/1` removes the ones already
  stored.

  ## Request headers

  `request_headers/2` is what the plug hands over when headers are kept: the
  protocol, the header names in the order they arrived, and their values.
  Which headers a client sends, and in what order, is one of the few things a
  script posing as a browser rarely gets right.

  Never kept, whatever the settings: the value of any header that carries a
  credential (`Cookie`, `Authorization`, anything named like a token, key or
  secret) — the name stays in the list, so its presence still shows. The
  query string of `Referer` is dropped, as it is on events. Headers that
  carry the visitor's address are kept only when the address itself is kept
  whole.

  ## Network

  A resolver (`PhoenixKitWebAnalytics.Geo`) may return `:asn`, `:network` and
  `:hosting` beside the location. Nothing ships with the module that knows
  them; without a resolver that does, the setting keeps nothing.

  ## Bot score

  Every row carries `bot_reasons` and their sum, `bot_score`
  (`PhoenixKitWebAnalytics.BotScore`). The request's reasons are worked out
  when a visit starts, the device's when its measurements arrive, and
  `PhoenixKitWebAnalytics.BotSignals`' verdicts are added as they are
  reached. The User-Agent is read for this whether or not it is kept — as it
  already is for the browser and system on every event — but headers and
  network count only when they are.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKitWebAnalytics.BotScore
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Geo
  alias PhoenixKitWebAnalytics.Schemas.VisitorProfile
  alias PhoenixKitWebAnalytics.Signals
  alias PhoenixKitWebAnalytics.Tracking

  @fields [:ip, :user_agent, :headers, :asn, :network, :hosting]

  @max_user_agent 1_000
  @max_headers 64
  @max_header_name 64
  @max_header_value 512
  @max_network 255

  # Headers whose value is a credential, by name or by what the name contains.
  @secret_headers ~w(cookie authorization proxy-authorization)
  @secret_words ~w(auth token secret session csrf password passwd key signature)
  # `Sec-WebSocket-Key` and friends are handshake nonces, not credentials.
  @not_secret ~w(sec-websocket-key sec-websocket-accept)

  # Headers a proxy or CDN puts the visitor's address in.
  @address_headers ~w(x-forwarded-for x-real-ip forwarded x-client-ip true-client-ip
    cf-connecting-ip cf-connecting-ipv6 fly-client-ip fastly-client-ip x-cluster-client-ip
    x-original-forwarded-for x-envoy-external-address)

  @delete_batch 5_000
  @max_delete_batches 200

  @doc "Whether any setting asks for something to be kept."
  @spec wanted?(Config.collection_config()) :: boolean()
  def wanted?(config) do
    config.store_ip != :off or config.store_user_agent? or config.store_headers? or
      config.store_network? or config.store_signals?
  end

  @doc """
  What the settings keep of a hit: a map of the profile's optional columns,
  holding only the ones with a value. Empty when nothing is to be kept — every
  setting off, or a hit that names no client (a server-side event).
  """
  @spec capture(map(), Config.collection_config()) :: map()
  def capture(hit, config) do
    %{
      ip: stored_ip(hit[:ip], config.store_ip),
      user_agent: if(config.store_user_agent?, do: text(hit[:user_agent], @max_user_agent)),
      headers: if(config.store_headers?, do: headers(hit[:headers]))
    }
    |> Map.merge(network(hit, config))
    |> Map.reject(fn {_field, value} -> is_nil(value) end)
  end

  @doc """
  Records a visit's start for `visitor_id`: writes what `capture/2` keeps of
  the hit, or refreshes the row that is there. Does nothing when there is
  nothing to keep. Always returns `:ok` — a profile is never worth an error
  to the caller.
  """
  @spec record(String.t(), map(), Config.collection_config(), DateTime.t()) :: :ok
  def record(visitor_id, hit, config, now \\ DateTime.utc_now()) when is_binary(visitor_id) do
    with true <- wanted?(config),
         attrs when attrs != %{} <- capture(hit, config) do
      upsert(visitor_id, attrs, now)

      # From what the row holds now, not from this hit alone: a visit that
      # starts on a live navigation or a beacon hit carries no headers, and
      # scoring that as "nothing found" would take back what an earlier
      # visit's headers — still stored — showed.
      rescore(visitor_id, :request, fn stored ->
        BotScore.request_reasons(%{
          user_agent: hit[:user_agent],
          headers: stored.headers,
          hosting: stored.hosting
        })
      end)
    end

    :ok
  rescue
    error ->
      Logger.debug("[WebAnalytics] visitor profile not stored: #{Exception.message(error)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Stores what the client script measured for `visitor_id` — the cleaned
  measurements (`Signals.clean/1`), the device hash, and the reasons they
  give — creating the row when nothing else is kept. Does nothing unless
  `web_analytics_store_signals` is on. Always returns `:ok`.
  """
  @spec record_signals(String.t(), map(), String.t() | nil, Config.collection_config(), keyword()) ::
          :ok
  def record_signals(visitor_id, raw, user_agent, config, opts \\ [])
      when is_binary(visitor_id) do
    with true <- config.store_signals?,
         %{} = signals <- Signals.clean(raw),
         salt when is_binary(salt) <- Keyword.get_lazy(opts, :salt, &Config.hash_salt/0) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      upsert_signals(visitor_id, signals, Signals.device_hash(signals, salt), now)

      rescore(visitor_id, :signals, fn _stored ->
        BotScore.signal_reasons(signals, user_agent)
      end)

      if signals["wd"] == true, do: add_reason([visitor_id], "webdriver")

      # With nothing else kept the visit's start wrote no row, so what the
      # User-Agent alone says is added here.
      Enum.each(
        BotScore.request_reasons(%{user_agent: user_agent}),
        &add_reason([visitor_id], &1)
      )
    end

    :ok
  rescue
    error ->
      Logger.debug("[WebAnalytics] device signals not stored: #{Exception.message(error)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Adds a reason to the profiles of `visitor_ids` (a list, or a query
  selecting visitor IDs) that don't have it yet — a
  `PhoenixKitWebAnalytics.BotSignals` verdict. Profiles that don't exist
  aren't created. Returns the number changed.
  """
  @spec add_reason([String.t()] | Ecto.Query.t(), BotScore.reason()) :: non_neg_integer()
  def add_reason(visitor_ids, reason) when is_binary(reason) do
    weight = BotScore.weight(reason)

    {count, _} =
      VisitorProfile
      |> for_visitors(visitor_ids)
      |> where([p], fragment("NOT (? = ANY(?))", ^reason, p.bot_reasons))
      |> update([p],
        set: [
          bot_reasons: fragment("array_append(?, ?)", p.bot_reasons, ^reason),
          bot_score: p.bot_score + ^weight
        ]
      )
      |> repo().update_all([])

    count
  rescue
    error ->
      Logger.debug("[WebAnalytics] bot reason not stored: #{Exception.message(error)}")
      0
  catch
    :exit, _ -> 0
  end

  @doc "Takes a reason back from the profiles of `visitor_ids`. Returns the number changed."
  @spec remove_reason([String.t()] | Ecto.Query.t(), BotScore.reason()) :: non_neg_integer()
  def remove_reason(visitor_ids, reason) when is_binary(reason) do
    weight = BotScore.weight(reason)

    {count, _} =
      VisitorProfile
      |> for_visitors(visitor_ids)
      |> where([p], fragment("? = ANY(?)", ^reason, p.bot_reasons))
      |> update([p],
        set: [
          bot_reasons: fragment("array_remove(?, ?)", p.bot_reasons, ^reason),
          bot_score: fragment("GREATEST(? - ?, 0)", p.bot_score, ^weight)
        ]
      )
      |> repo().update_all([])

    count
  rescue
    error ->
      Logger.debug("[WebAnalytics] bot reason not removed: #{Exception.message(error)}")
      0
  catch
    :exit, _ -> 0
  end

  @doc "The profile kept for a visitor ID, or `nil`."
  @spec get(String.t() | nil) :: VisitorProfile.t() | nil
  def get(visitor_id) when is_binary(visitor_id) do
    repo().get_by(VisitorProfile, visitor_id: visitor_id)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.debug("[WebAnalytics] visitor profile not read: #{Exception.message(error)}")
      nil
  end

  def get(_visitor_id), do: nil

  @doc "How many profiles are stored."
  @spec count() :: non_neg_integer()
  def count do
    repo().aggregate(VisitorProfile, :count)
  rescue
    _ -> 0
  end

  @doc """
  Blanks one kind of stored data on every profile — what switching its
  setting off doesn't do by itself — takes back the bot reasons that were
  read from it (`BotScore.derived_from/1`), and drops the rows left with
  nothing.
  `:all` deletes every profile. Returns the number of rows changed or
  deleted.
  """
  @spec forget(:ip | :user_agent | :headers | :network | :signals | :all) :: non_neg_integer()
  def forget(:all) do
    {count, _} = repo().delete_all(VisitorProfile)
    count
  end

  def forget(kind) when kind in [:ip, :user_agent, :headers, :network, :signals] do
    columns = forget_columns(kind)

    {count, _} =
      VisitorProfile
      |> where(^not_null_any(columns))
      |> repo().update_all(set: Enum.map(columns, &{&1, nil}))

    # What was worked out from the forgotten data goes with it: a reason
    # left behind would still say what the data said.
    Enum.each(BotScore.derived_from(kind), &strip_reason/1)

    drop_empty()
    count
  end

  @doc """
  Deletes the profiles of visitors not seen for the raw events' retention
  period, in batches. Returns the number deleted; nothing when retention is
  off (`0` days keeps everything).
  """
  @spec prune() :: non_neg_integer()
  def prune do
    case Config.retention_days() do
      days when is_integer(days) and days > 0 ->
        Date.utc_today()
        |> Date.add(-days)
        |> DateTime.new!(~T[00:00:00.000000], "Etc/UTC")
        |> delete_batches(0, 0)

      _ ->
        0
    end
  end

  @doc """
  The header profile of a request: protocol, header names in arrival order,
  and their values — less the ones never kept (see the module doc).
  `address?` says whether address-carrying headers keep their value.
  """
  @spec request_headers(Plug.Conn.t(), boolean()) :: map()
  def request_headers(%Plug.Conn{} = conn, address?) do
    headers = Enum.take(conn.req_headers, @max_headers)

    %{
      "http" => conn |> Plug.Conn.get_http_protocol() |> to_string(),
      "scheme" => scheme(conn),
      "names" => Enum.map(headers, fn {name, _value} -> clip(name, @max_header_name) end),
      "values" => header_values(headers, address?)
    }
  rescue
    _ -> nil
  end

  @doc """
  A visitor's address as stored under `mode`: whole, its network
  (`/24` for IPv4, `/48` for IPv6), or not at all.

      iex> PhoenixKitWebAnalytics.Profiles.stored_ip({203, 0, 113, 7}, :full)
      "203.0.113.7"

      iex> PhoenixKitWebAnalytics.Profiles.stored_ip({203, 0, 113, 7}, :truncated)
      "203.0.113.0/24"

      iex> PhoenixKitWebAnalytics.Profiles.stored_ip({0x2001, 0xDB8, 0xABCD, 1, 2, 3, 4, 5}, :truncated)
      "2001:db8:abcd::/48"

      iex> PhoenixKitWebAnalytics.Profiles.stored_ip({203, 0, 113, 7}, :off)
      nil
  """
  @spec stored_ip(tuple() | String.t() | nil, :off | :truncated | :full) :: String.t() | nil
  def stored_ip(ip, mode) when is_binary(ip) and mode != :off do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> stored_ip(tuple, mode)
      {:error, _} -> nil
    end
  end

  def stored_ip({_, _, _, _} = ip, :full), do: ntoa(ip)
  def stored_ip({_, _, _, _, _, _, _, _} = ip, :full), do: ntoa(ip)
  def stored_ip({a, b, c, _}, :truncated), do: ntoa({a, b, c, 0}) <> "/24"

  def stored_ip({a, b, c, _, _, _, _, _}, :truncated),
    do: ntoa({a, b, c, 0, 0, 0, 0, 0}) <> "/48"

  def stored_ip(_ip, _mode), do: nil

  # ── internals ─────────────────────────────────────────────────────────────

  defp ntoa(ip), do: ip |> :inet.ntoa() |> to_string()

  # Fill what's missing, keep what's there: the newest value wins, an absent
  # one never blanks a stored one.
  defp upsert(visitor_id, attrs, now) do
    row =
      attrs
      |> Map.take(@fields)
      |> Map.merge(%{
        uuid: UUIDv7.generate(),
        visitor_id: visitor_id,
        inserted_at: now,
        last_seen_at: now
      })

    update =
      from(p in VisitorProfile,
        update: [
          set: [
            last_seen_at: fragment("GREATEST(EXCLUDED.last_seen_at, ?)", p.last_seen_at),
            ip: fragment("COALESCE(EXCLUDED.ip, ?)", p.ip),
            user_agent: fragment("COALESCE(EXCLUDED.user_agent, ?)", p.user_agent),
            headers: fragment("COALESCE(EXCLUDED.headers, ?)", p.headers),
            asn: fragment("COALESCE(EXCLUDED.asn, ?)", p.asn),
            network: fragment("COALESCE(EXCLUDED.network, ?)", p.network),
            hosting: fragment("COALESCE(EXCLUDED.hosting, ?)", p.hosting)
          ]
        ]
      )

    repo().insert_all(VisitorProfile, [row],
      on_conflict: update,
      conflict_target: [:visitor_id]
    )
  end

  # A device reporting in is the visitor being seen: without the time moving
  # forward, a profile that only ever receives measurements would drop off
  # the Bots page and be pruned as if it had gone away.
  defp upsert_signals(visitor_id, signals, device_hash, now) do
    row = %{
      uuid: UUIDv7.generate(),
      visitor_id: visitor_id,
      signals: signals,
      device_hash: device_hash,
      inserted_at: now,
      last_seen_at: now
    }

    update =
      from(p in VisitorProfile,
        update: [
          set: [
            signals: fragment("EXCLUDED.signals"),
            device_hash: fragment("EXCLUDED.device_hash"),
            last_seen_at: fragment("GREATEST(EXCLUDED.last_seen_at, ?)", p.last_seen_at)
          ]
        ]
      )

    repo().insert_all(VisitorProfile, [row],
      on_conflict: update,
      conflict_target: [:visitor_id]
    )
  end

  # Replaces one source's reasons on a profile, leaving the others'; writes
  # only when that changes something. `found` is given what the row holds.
  #
  # The row is locked from the read to the write. The request's and the
  # device's reasons arrive within the same second on a page load, and
  # without the lock the later write would put back the list it read before
  # the other one landed, losing that source's reasons.
  defp rescore(visitor_id, source, found) do
    repo().transaction(fn ->
      stored =
        repo().one(
          from(p in VisitorProfile,
            where: p.visitor_id == ^visitor_id,
            lock: "FOR UPDATE",
            select: map(p, [:bot_reasons, :headers, :hosting])
          )
        )

      if stored, do: write_reasons(visitor_id, stored.bot_reasons, source, found.(stored))
    end)

    :ok
  end

  defp write_reasons(visitor_id, current, source, found) do
    reasons = BotScore.merge(current, source, found)

    if reasons != current do
      from(p in VisitorProfile, where: p.visitor_id == ^visitor_id)
      |> repo().update_all(set: [bot_reasons: reasons, bot_score: BotScore.score(reasons)])
    end
  end

  # One statement per reason, on every profile that has it.
  defp strip_reason(reason) do
    weight = BotScore.weight(reason)

    from(p in VisitorProfile,
      where: fragment("? = ANY(?)", ^reason, p.bot_reasons),
      update: [
        set: [
          bot_reasons: fragment("array_remove(?, ?)", p.bot_reasons, ^reason),
          bot_score: fragment("GREATEST(? - ?, 0)", p.bot_score, ^weight)
        ]
      ]
    )
    |> repo().update_all([])
  end

  defp for_visitors(query, visitor_ids) when is_list(visitor_ids),
    do: where(query, [p], p.visitor_id in ^visitor_ids)

  defp for_visitors(query, %Ecto.Query{} = visitor_ids),
    do: where(query, [p], p.visitor_id in subquery(visitor_ids))

  # A hit that already carries the network (an edge header, a test) is taken
  # at its word; otherwise the resolver is asked — once per visit, off the
  # request.
  defp network(_hit, %{store_network?: false}), do: %{}

  defp network(hit, _config) do
    source = if is_map(hit[:network]), do: hit[:network], else: Geo.resolve(hit[:ip])

    %{
      asn: asn(source[:asn]),
      network: text(source[:network], @max_network),
      hosting: if(is_boolean(source[:hosting]), do: source[:hosting])
    }
  end

  defp asn(value) when is_integer(value) and value > 0, do: value

  # "AS13335", as some databases write it.
  defp asn(value) when is_binary(value) do
    case value
         |> String.trim()
         |> String.upcase()
         |> String.trim_leading("AS")
         |> Integer.parse() do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp asn(_value), do: nil

  # Already shaped by `request_headers/2`; anything else isn't headers.
  defp headers(%{"names" => names, "values" => values} = headers)
       when is_list(names) and is_map(values),
       do: Map.take(headers, ["http", "scheme", "names", "values"])

  defp headers(_headers), do: nil

  # As the browser saw it: a proxy that ends TLS says so in a header.
  defp scheme(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-proto") do
      [proto | _] when proto in ["http", "https"] -> proto
      _ -> to_string(conn.scheme)
    end
  end

  defp header_values(headers, address?) do
    for {name, value} <- headers,
        kept = header_value(name, value, address?),
        into: %{},
        do: {clip(name, @max_header_name), kept}
  end

  defp header_value(name, value, address?) do
    cond do
      not is_binary(value) -> nil
      secret_header?(name) -> nil
      name in @address_headers and not address? -> nil
      name == "referer" -> value |> strip_query() |> text(@max_header_value)
      true -> text(value, @max_header_value)
    end
  end

  defp secret_header?(name) do
    name in @secret_headers or
      (name not in @not_secret and String.contains?(name, @secret_words))
  end

  defp strip_query(url), do: url |> String.split(["?", "#"], parts: 2) |> hd()

  defp clip(value, max) when is_binary(value), do: text(value, max) || ""
  defp clip(_value, _max), do: ""

  # Text a column can hold: valid UTF-8, no NUL, bounded, never blank.
  defp text(value, max) when is_binary(value) do
    if String.valid?(value) do
      case value |> String.replace(<<0>>, "") |> String.trim() do
        "" -> nil
        trimmed -> Tracking.truncate_utf8(trimmed, max)
      end
    end
  end

  defp text(_value, _max), do: nil

  defp forget_columns(:network), do: [:asn, :network, :hosting]
  defp forget_columns(:signals), do: [:signals, :device_hash]
  defp forget_columns(kind), do: [kind]

  defp not_null_any(columns) do
    Enum.reduce(columns, dynamic(false), fn column, acc ->
      dynamic([p], ^acc or not is_nil(field(p, ^column)))
    end)
  end

  # A row with nothing kept is only a visitor ID and two times.
  defp drop_empty do
    from(p in VisitorProfile,
      where:
        is_nil(p.ip) and is_nil(p.user_agent) and is_nil(p.headers) and is_nil(p.asn) and
          is_nil(p.network) and is_nil(p.hosting) and is_nil(p.signals) and
          is_nil(p.device_hash)
    )
    |> repo().delete_all()
  end

  defp delete_batches(_cutoff, deleted, batches) when batches >= @max_delete_batches, do: deleted

  defp delete_batches(cutoff, deleted, batches) do
    ids =
      from(p in VisitorProfile,
        where: p.last_seen_at < ^cutoff,
        select: p.uuid,
        limit: @delete_batch
      )

    {count, _} = from(p in VisitorProfile, where: p.uuid in subquery(ids)) |> repo().delete_all()

    if count < @delete_batch,
      do: deleted + count,
      else: delete_batches(cutoff, deleted + count, batches + 1)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning(
        "[WebAnalytics] profile prune stopped after #{deleted} row(s): #{Exception.message(error)}"
      )

      deleted
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
