defmodule PhoenixKitWebAnalytics.RollupReader do
  @moduledoc false
  # The engine behind every report that adds things up over a period.
  #
  # A period is split at the rollup watermark: finished days that are rolled
  # up come from `DailyStat` / `DailyDim` (a few rows per day), and only the
  # rest — today, and yesterday until its rollup has run — is aggregated from
  # raw events. The two halves are added in one SQL statement (`UNION ALL`,
  # then grouped), so ranking, `LIMIT` and `OFFSET` happen in the database on
  # the combined numbers.
  #
  # Distinct visitors add up across days exactly, because the visitor ID
  # itself changes every day; that is what makes the split lossless.
  #
  # Rollups don't apply — and the whole window is read raw — for hourly
  # periods (today / yesterday, which need hours), a single-page filter, and
  # bot traffic, none of which the rollups break down by.

  import Ecto.Query

  require Logger

  alias PhoenixKitWebAnalytics.Dimensions
  alias PhoenixKitWebAnalytics.ReportCache
  alias PhoenixKitWebAnalytics.Retention
  alias PhoenixKitWebAnalytics.Schemas.DailyDim
  alias PhoenixKitWebAnalytics.Schemas.DailyStat
  alias PhoenixKitWebAnalytics.Schemas.Event

  @doc """
  How a filter's window is read: `%{dates: {first, last} | nil, raw: filter
  | nil}` — the rolled-up days and the raw remainder.
  """
  @spec plan(map()) :: %{dates: {Date.t(), Date.t()} | nil, raw: map() | nil}
  def plan(filter) do
    with true <- rollups_apply?(filter),
         %Date{} = watermark <- watermark(),
         first = DateTime.to_date(filter.from),
         last = filter.to |> DateTime.add(-1, :second) |> DateTime.to_date(),
         roll_last = Enum.min([watermark, last], Date),
         true <- Date.compare(first, roll_last) != :gt do
      raw_from = DateTime.new!(Date.add(roll_last, 1), ~T[00:00:00], "Etc/UTC")
      raw = if DateTime.compare(raw_from, filter.to) == :lt, do: %{filter | from: raw_from}
      %{dates: {first, roll_last}, raw: raw}
    else
      _ -> %{dates: nil, raw: filter}
    end
  end

  @doc "The last rolled-up day, cached for a minute."
  @spec watermark() :: Date.t() | nil
  def watermark do
    ReportCache.fetch(
      {__MODULE__, :watermark},
      fn ->
        case Retention.rolled_through() do
          {:ok, %Date{} = date} -> date
          _ -> nil
        end
      end,
      60_000
    )
  end

  # ── breakdowns ────────────────────────────────────────────────────────────

  @doc """
  One dimension over the filter's window, combined: a query yielding
  `%{value, detail, hits, visitors, exits, …}` per value, for the caller to
  order, cut and page. `values:` restricts to a list of values.
  """
  @spec dimension(map(), String.t(), keyword()) :: Ecto.Query.t()
  def dimension(filter, dimension, opts \\ []) do
    plan = plan(filter)
    values = Keyword.get(opts, :values)

    parts =
      Enum.reject(
        [
          plan.dates && rollup_part(plan.dates, filter.site, dimension, values),
          plan.raw && raw_part(plan.raw, dimension, values)
        ],
        &is_nil/1
      )

    source =
      case parts do
        [only] -> only
        [first, second] -> union_all(first, ^second)
      end

    from(r in subquery(source),
      group_by: [r.value, r.detail],
      select: %{
        value: r.value,
        detail: r.detail,
        hits: sum(r.hits),
        visitors: sum(r.visitors),
        exits: sum(r.exits),
        exit_visitors: sum(r.exit_visitors),
        engaged_ms_sum: sum(r.engaged_ms_sum),
        engaged_count: sum(r.engaged_count),
        scroll_sum: sum(r.scroll_sum),
        scroll_count: sum(r.scroll_count),
        duration_ms_sum: sum(r.duration_ms_sum),
        duration_count: sum(r.duration_count),
        duration_max: max(r.duration_max)
      }
    )
  end

  defp rollup_part({first, last}, site, dimension, values) do
    from(d in DailyDim,
      where: d.dimension == ^dimension and d.date >= ^first and d.date <= ^last,
      select: %{
        value: d.value,
        detail: d.detail,
        hits: d.hits,
        visitors: d.visitors,
        exits: d.exits,
        exit_visitors: d.exit_visitors,
        engaged_ms_sum: d.engaged_ms_sum,
        engaged_count: d.engaged_count,
        scroll_sum: d.scroll_sum,
        scroll_count: d.scroll_count,
        duration_ms_sum: d.duration_ms_sum,
        duration_count: d.duration_count,
        duration_max: d.duration_max
      }
    )
    |> where_rollup_site(site)
    |> where_values(values)
  end

  defp raw_part(filter, dimension, values) do
    aggregated = filter |> events() |> Dimensions.aggregate(dimension)

    # The rollup drops a row with neither a hit nor an exit (a path that only
    # saw interactions); the raw side must too, or the same day would list a
    # zero-view page while it is today and not once it is rolled up.
    from(r in subquery(aggregated),
      where: not is_nil(r.value) and (r.hits > 0 or r.exits > 0),
      select: %{
        value: r.value,
        detail: r.detail,
        hits: r.hits,
        visitors: r.visitors,
        exits: r.exits,
        exit_visitors: r.exit_visitors,
        engaged_ms_sum: r.engaged_ms_sum,
        engaged_count: r.engaged_count,
        scroll_sum: r.scroll_sum,
        scroll_count: r.scroll_count,
        duration_ms_sum: r.duration_ms_sum,
        duration_count: r.duration_count,
        duration_max: r.duration_max
      }
    )
    |> where_values(values)
  end

  # ── totals ────────────────────────────────────────────────────────────────

  @doc """
  The window's headline sums: page views, visitors, events, sessions,
  bounces, session seconds, exits and the engagement / response sums.
  """
  @spec totals(map(), (Ecto.Query.t() -> map())) :: map()
  def totals(filter, session_totals_fun) do
    plan = plan(filter)

    [
      plan.dates && rollup_totals(plan.dates, filter.site),
      plan.raw && raw_totals(plan.raw, session_totals_fun)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(empty_totals(), &add_totals/2)
  end

  defp rollup_totals({first, last}, site) do
    from(s in DailyStat,
      where: s.date >= ^first and s.date <= ^last,
      select: %{
        pageviews: coalesce(sum(s.pageviews), 0),
        visitors: coalesce(sum(s.visitors), 0),
        events: coalesce(sum(s.events), 0),
        sessions: coalesce(sum(s.sessions), 0),
        bounces: coalesce(sum(s.bounces), 0),
        session_seconds: coalesce(sum(s.total_session_seconds), 0),
        exits: coalesce(sum(s.exits), 0),
        engaged_ms_sum: coalesce(sum(s.engaged_ms_sum), 0),
        engaged_count: coalesce(sum(s.engaged_count), 0),
        scroll_sum: coalesce(sum(s.scroll_sum), 0),
        scroll_count: coalesce(sum(s.scroll_count), 0),
        duration_ms_sum: coalesce(sum(s.duration_ms_sum), 0),
        duration_count: coalesce(sum(s.duration_count), 0)
      }
    )
    |> where_rollup_site(site)
    |> one(empty_totals())
    |> numbers()
  end

  defp raw_totals(filter, session_totals_fun) do
    per_site = filter |> events() |> Dimensions.totals() |> all([])

    sums =
      Enum.reduce(per_site, empty_totals(), fn row, acc ->
        add_totals(numbers(Map.delete(row, :site)), acc)
      end)

    sessions = filter |> events() |> session_totals_fun.()

    add_totals(
      %{
        sessions: sessions.sessions,
        bounces: sessions.bounces,
        session_seconds: sessions.total_seconds
      },
      sums
    )
  end

  defp empty_totals do
    Map.new(
      ~w(pageviews visitors events sessions bounces session_seconds exits engaged_ms_sum
         engaged_count scroll_sum scroll_count duration_ms_sum duration_count)a,
      &{&1, 0}
    )
  end

  defp add_totals(part, acc) do
    Map.merge(acc, numbers(part), fn _key, a, b -> (a || 0) + (b || 0) end)
  end

  # ── trend ─────────────────────────────────────────────────────────────────

  @doc """
  Page views and visitors per day (or month) from the rolled-up days —
  `%{Date => %{pageviews, visitors}}`, keyed by the bucket's first day — and
  the raw remainder's filter (or nil).
  """
  @spec rolled_buckets(map(), :day | :month) :: {map(), map() | nil}
  def rolled_buckets(filter, bucket) do
    plan = plan(filter)

    rows =
      case plan.dates do
        nil ->
          %{}

        {first, last} ->
          from(s in DailyStat, where: s.date >= ^first and s.date <= ^last)
          |> where_rollup_site(filter.site)
          |> group_rollup(bucket)
          |> all([])
          |> Map.new(fn row ->
            {to_date(row.bucket),
             %{pageviews: to_int(row.pageviews), visitors: to_int(row.visitors)}}
          end)
      end

    {rows, plan.raw}
  end

  defp group_rollup(query, :day) do
    from(s in query,
      group_by: s.date,
      select: %{bucket: s.date, pageviews: sum(s.pageviews), visitors: sum(s.visitors)}
    )
  end

  # `date_trunc` on a `date` answers a `timestamptz` — midnight in the
  # *session's* time zone — which reads back as the previous day's evening
  # wherever that zone is east of UTC, and the month then matches no bucket.
  # Casting to `timestamp` first keeps it a plain calendar value.
  defp group_rollup(query, :month) do
    from(s in query,
      group_by: fragment("date_trunc('month', ?::timestamp)", s.date),
      select: %{
        bucket: fragment("date_trunc('month', ?::timestamp)", s.date),
        pageviews: sum(s.pageviews),
        visitors: sum(s.visitors)
      }
    )
  end

  @doc """
  Hosts seen in the window — rolled-up days and the raw remainder. Ignores the
  filter's own site: this is the list to pick a site from.
  """
  @spec sites(map()) :: [String.t()]
  def sites(filter) do
    filter = %{filter | site: nil}
    plan = plan(filter)

    rolled =
      case plan.dates do
        nil ->
          []

        {first, last} ->
          from(s in DailyStat,
            where: s.date >= ^first and s.date <= ^last and s.site != "",
            distinct: true,
            select: s.site
          )
          |> all([])
      end

    raw =
      case plan.raw do
        nil ->
          []

        raw_filter ->
          from(e in events(raw_filter),
            where: not is_nil(e.site),
            distinct: true,
            select: e.site,
            limit: 50
          )
          |> all([])
      end

    (rolled ++ raw) |> Enum.uniq() |> Enum.take(50)
  end

  # ── plumbing ──────────────────────────────────────────────────────────────

  @doc "Raw events in the filter's window, restricted like every report."
  @spec events(map()) :: Ecto.Query.t()
  def events(filter) do
    Event
    |> where([e], e.inserted_at >= ^filter.from and e.inserted_at < ^filter.to)
    |> then(fn q -> if filter.site, do: where(q, [e], e.site == ^filter.site), else: q end)
    |> then(fn q -> if filter[:path], do: where(q, [e], e.path == ^filter.path), else: q end)
    |> then(fn q ->
      if Map.get(filter, :bots, false), do: q, else: where(q, [e], not e.is_bot)
    end)
  end

  @doc "A combined row's sums as plain integers."
  @spec numbers(map()) :: map()
  def numbers(row), do: Map.new(row, fn {key, value} -> {key, to_int(value)} end)

  defp rollups_apply?(filter) do
    is_nil(filter[:path]) and not Map.get(filter, :bots, false) and
      filter[:period] not in ["today", "yesterday"] and
      match?(%DateTime{hour: 0, minute: 0, second: 0}, filter.from)
  end

  defp where_rollup_site(query, nil), do: query
  defp where_rollup_site(query, site), do: where(query, [s], s.site == ^site)

  defp where_values(query, nil), do: query
  defp where_values(query, values), do: where(query, [r], r.value in ^values)

  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = value), do: value |> Decimal.round() |> Decimal.to_integer()
  defp to_int(value) when is_float(value), do: round(value)
  defp to_int(value), do: value

  defp to_date(%Date{} = date), do: date
  defp to_date(%NaiveDateTime{} = at), do: NaiveDateTime.to_date(at)
  defp to_date(%DateTime{} = at), do: DateTime.to_date(at)

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # A broken read costs an empty result, never a failed page — the same rule
  # `Reports` keeps for its own queries.
  defp all(query, fallback) do
    repo().all(query)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("[WebAnalytics] report query failed: #{Exception.message(error)}")
      fallback
  catch
    :exit, reason ->
      Logger.warning("[WebAnalytics] report query exited: #{inspect(reason)}")
      fallback
  end

  defp one(query, fallback) do
    case repo().one(query) do
      nil -> fallback
      result -> result
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("[WebAnalytics] report query failed: #{Exception.message(error)}")
      fallback
  catch
    :exit, reason ->
      Logger.warning("[WebAnalytics] report query exited: #{inspect(reason)}")
      fallback
  end
end
