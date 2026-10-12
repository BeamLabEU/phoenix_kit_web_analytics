defmodule PhoenixKitWebAnalytics.Bots do
  @moduledoc """
  The read side of the Bots page: the visitors a profile is kept for
  (`PhoenixKitWebAnalytics.Profiles`), ranked by how much they look like a
  bot (`PhoenixKitWebAnalytics.BotScore`), one by one or grouped by what
  several of them share — a network, a subnet, an address, a device, a
  User-Agent.

  Grouping is what makes a decision possible: one visitor with a hosting
  address is a guess, four hundred from the same network with the same
  device hash is a scraper.

  Every query degrades to an empty result and logs, like the reports.

  ## Filter

      %{
        days: 7,              # last seen within; 0 = whenever
        level: :all,          # :all | :suspicious | :likely — the score's floor
        asn: nil,             # narrow to a network number
        subnet: nil,          # … a subnet ("203.0.113.0/24")
        ip: nil,              # … a stored address
        device: nil,          # … a device hash
        agent: nil            # … a User-Agent, by its MD5
      }
  """

  import Ecto.Query

  require Logger

  alias PhoenixKitWebAnalytics.BotScore
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Schemas.VisitorProfile

  @groups [:network, :subnet, :ip, :device, :agent]
  @levels [:all, :suspicious, :likely]
  @default_limit 100

  @type filter :: %{optional(atom()) => term()}

  @doc "What visitors can be grouped by."
  @spec groups() :: [atom()]
  def groups, do: @groups

  @doc "The score floors a list can be narrowed to."
  @spec levels() :: [atom()]
  def levels, do: @levels

  @doc "The filter with nothing narrowed: the last week, every score."
  @spec default_filter() :: filter()
  def default_filter,
    do: %{days: 7, level: :all, asn: nil, subnet: nil, ip: nil, device: nil, agent: nil}

  @doc """
  The profiles matching `filter`, the likeliest bots first, then the latest
  seen. `:limit` (#{@default_limit} by default).
  """
  @spec visitors(filter(), keyword()) :: [VisitorProfile.t()]
  def visitors(filter, opts \\ []) do
    filter
    |> base()
    |> order_by([p], desc: p.bot_score, desc: p.last_seen_at)
    |> limit(^Keyword.get(opts, :limit, @default_limit))
    |> repo().all()
  rescue
    error -> degrade("visitors", error, [])
  end

  @doc """
  The matching profiles grouped by `by`: for each group its `:key`, a
  `:label` (the network's name, the User-Agent; otherwise `nil`), how many
  `:visitors`, how many of them `:likely` bots, the highest score
  (`:top_score`) and when one was last seen. The groups with the most likely
  bots first. Profiles without the grouped value aren't in any group.
  """
  @spec groups(atom(), filter(), keyword()) :: [map()]
  def groups(by, filter, opts \\ []) when by in @groups do
    likely = BotScore.threshold(:likely)

    from(k in subquery(keyed(by, base(filter))),
      where: not is_nil(k.key),
      group_by: k.key,
      order_by: [
        desc: filter(count(), k.score >= ^likely),
        desc: count(),
        asc: k.key
      ],
      limit: ^Keyword.get(opts, :limit, @default_limit),
      select: %{
        key: k.key,
        label: max(k.label),
        visitors: count(),
        likely: filter(count(), k.score >= ^likely),
        top_score: max(k.score),
        last_seen_at: max(k.last_seen_at)
      }
    )
    |> repo().all()
  rescue
    error -> degrade("groups", error, [])
  end

  @doc """
  How many profiles match `filter` whatever their score, how many of those
  are likely bots, how many suspicious, and how many distinct devices.
  """
  @spec summary(filter()) :: %{
          visitors: non_neg_integer(),
          likely: non_neg_integer(),
          suspicious: non_neg_integer(),
          devices: non_neg_integer()
        }
  def summary(filter) do
    likely = BotScore.threshold(:likely)
    suspicious = BotScore.threshold(:suspicious)

    from(p in base(%{filter | level: :all}),
      select: %{
        visitors: count(),
        likely: filter(count(), p.bot_score >= ^likely),
        suspicious: filter(count(), p.bot_score >= ^suspicious and p.bot_score < ^likely),
        devices: count(p.device_hash, :distinct)
      }
    )
    |> repo().one()
  rescue
    error -> degrade("summary", error, %{visitors: 0, likely: 0, suspicious: 0, devices: 0})
  end

  @doc """
  The latest visit of each of `visitor_ids`: `%{visitor_id => session_id}`.
  A visitor whose events are gone isn't in the map.
  """
  @spec latest_sessions([String.t()]) :: %{String.t() => Ecto.UUID.t()}
  def latest_sessions([]), do: %{}

  def latest_sessions(visitor_ids) when is_list(visitor_ids) do
    from(e in Event,
      where: e.visitor_id in ^visitor_ids,
      distinct: e.visitor_id,
      order_by: [asc: e.visitor_id, desc: e.inserted_at],
      select: {e.visitor_id, e.session_id}
    )
    |> repo().all()
    |> Map.new()
  rescue
    error -> degrade("latest_sessions", error, %{})
  end

  @doc "The MD5 a User-Agent is grouped and filtered by."
  @spec agent_key(String.t()) :: String.t()
  def agent_key(user_agent) when is_binary(user_agent),
    do: :crypto.hash(:md5, user_agent) |> Base.encode16(case: :lower)

  # ── internals ─────────────────────────────────────────────────────────────

  # An address's subnet: the /24 of an IPv4 one, the /48 of an IPv6 one. A
  # stored network ("203.0.113.0/24") is its own.
  defmacrop subnet(ip) do
    quote do
      fragment(
        "network(set_masklen(?::inet, CASE WHEN family(?::inet) = 4 THEN 24 ELSE 48 END))::text",
        unquote(ip),
        unquote(ip)
      )
    end
  end

  defp base(filter) do
    VisitorProfile
    |> since(filter[:days])
    |> floor(filter[:level])
    |> narrow(:asn, filter[:asn])
    |> narrow(:subnet, filter[:subnet])
    |> narrow(:ip, filter[:ip])
    |> narrow(:device, filter[:device])
    |> narrow(:agent, filter[:agent])
  end

  defp since(query, days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    where(query, [p], p.last_seen_at >= ^cutoff)
  end

  defp since(query, _days), do: query

  defp floor(query, level) when level in [:suspicious, :likely] do
    threshold = BotScore.threshold(level)
    where(query, [p], p.bot_score >= ^threshold)
  end

  defp floor(query, _level), do: query

  defp narrow(query, _field, nil), do: query
  defp narrow(query, :asn, asn) when is_integer(asn), do: where(query, [p], p.asn == ^asn)

  defp narrow(query, :subnet, subnet) when is_binary(subnet),
    do: where(query, [p], not is_nil(p.ip) and subnet(p.ip) == ^subnet)

  defp narrow(query, :ip, ip) when is_binary(ip), do: where(query, [p], p.ip == ^ip)

  defp narrow(query, :device, hash) when is_binary(hash),
    do: where(query, [p], p.device_hash == ^hash)

  defp narrow(query, :agent, md5) when is_binary(md5),
    do: where(query, [p], fragment("md5(?)", p.user_agent) == ^md5)

  defp narrow(query, _field, _value), do: query

  defp keyed(:network, query) do
    from(p in query,
      select: %{
        key: type(p.asn, :string),
        label: p.network,
        score: p.bot_score,
        last_seen_at: p.last_seen_at
      }
    )
  end

  defp keyed(:subnet, query) do
    from(p in query,
      where: not is_nil(p.ip),
      select: %{
        key: subnet(p.ip),
        label: type(^nil, :string),
        score: p.bot_score,
        last_seen_at: p.last_seen_at
      }
    )
  end

  defp keyed(:ip, query) do
    from(p in query,
      select: %{
        key: p.ip,
        label: type(^nil, :string),
        score: p.bot_score,
        last_seen_at: p.last_seen_at
      }
    )
  end

  defp keyed(:device, query) do
    from(p in query,
      select: %{
        key: p.device_hash,
        label: type(^nil, :string),
        score: p.bot_score,
        last_seen_at: p.last_seen_at
      }
    )
  end

  defp keyed(:agent, query) do
    from(p in query,
      select: %{
        key: fragment("md5(?)", p.user_agent),
        label: p.user_agent,
        score: p.bot_score,
        last_seen_at: p.last_seen_at
      }
    )
  end

  defp degrade(what, error, fallback) do
    Logger.warning("[WebAnalytics] bots #{what} failed: #{Exception.message(error)}")
    fallback
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
