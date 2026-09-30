defmodule PhoenixKitWebAnalytics.Reports do
  @moduledoc """
  Read-side aggregation — every number the admin pages show.

  All functions take a **filter map** and answer one question about it. Build
  the filter with `filter/1`:

      filter = PhoenixKitWebAnalytics.Reports.filter(period: "7d")

      PhoenixKitWebAnalytics.Reports.overview(filter)
      PhoenixKitWebAnalytics.Reports.top_paths(filter, limit: 10)

  ## Filter keys

    * `:from` / `:to` — the time window, `from` inclusive, `to` exclusive
    * `:site` — restrict to one host (nil = all)
    * `:path` — restrict to one path (nil = all)
    * `:period` — the label the window came from, carried for the UI

  ## Counting rules

  These are the same rules a hosted analytics product applies, stated
  explicitly because they're what makes two tools disagree:

    * **Page views** count rows with `event_type = "pageview"`. Custom events
      are never page views.
    * **Visitors** is `COUNT(DISTINCT visitor_id)`. Since `visitor_id` is a
      daily hash (see `PhoenixKitWebAnalytics.Visitor`), one person browsing on
      three days counts as three visitors over a week-long window. That is the
      honest consequence of not tracking people across days.
    * **Sessions** is `COUNT(DISTINCT session_id)`, where a session ends after
      the configured inactivity gap (30 minutes by default).
    * **Bounce rate** is sessions with exactly one page view, over all sessions.
    * **Average session length** measures last hit minus first hit in a
      session, so single-page sessions contribute zero — the standard
      definition, and the reason it reads low on content sites.

  ## Long windows and pruned data

  `daily_timeseries/1` transparently falls back to
  `PhoenixKitWebAnalytics.Schemas.DailyStat` rows for days whose raw events have
  been pruned, so trend lines survive retention. Breakdowns (pages, referrers,
  …) are raw-only: once a day is pruned its breakdowns are gone by design, and
  this module will not show a partial ranking as if it were complete.

  ## Engagement

  `"leave"` events — recorded when a visitor leaves a page, with the time it
  was open — answer "how long do people stay" and "where do they leave"
  (`engagement/1`, `exit_pages/2`, `page_engagement/2`). `"interaction"` events
  are what they did there (`top_interactions/2`). `sessions/2` lists visits and
  `session_timeline/1` replays one.

  Bot traffic (stored only when `web_analytics_track_bots` is on) is left out
  of every report unless the filter asks for it with `bots: true`.

  ## Failure behaviour

  Every query degrades to an empty result rather than raising — a module that
  is installed but whose migrations haven't run yet, or a momentarily
  unreachable database, renders as "no data yet" instead of a 500 on the admin
  page. The failure is logged.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKitWebAnalytics.Schemas.DailyStat
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.SessionStats

  @type filter :: %{
          from: DateTime.t(),
          to: DateTime.t(),
          site: String.t() | nil,
          path: String.t() | nil,
          period: String.t(),
          bots: boolean()
        }

  @default_limit 10
  @slow_min_views 3
  @default_period "7d"
  @empty_totals %{pageviews: 0, visitors: 0, avg_response_ms: nil}
  @empty_sessions %{sessions: 0, bounces: 0, total_seconds: 0}

  @periods [
    {"today", "Today"},
    {"yesterday", "Yesterday"},
    {"7d", "Last 7 days"},
    {"30d", "Last 30 days"},
    {"90d", "Last 90 days"},
    {"12m", "Last 12 months"},
    {"all", "All time"}
  ]

  @doc "The selectable periods as `{value, label}` pairs, for the UI."
  @spec periods() :: [{String.t(), String.t()}]
  def periods, do: @periods

  @doc "The default period when none was requested."
  @spec default_period() :: String.t()
  def default_period, do: @default_period

  @doc "The human label for a period value."
  @spec period_label(String.t()) :: String.t()
  def period_label(period) do
    Enum.find_value(@periods, period, fn {value, label} -> if value == period, do: label end)
  end

  @doc """
  Builds a filter.

  ## Options

    * `:period` — one of `periods/0`'s values; an unknown value falls back to
      the default rather than raising, since it arrives from a query parameter
    * `:site`, `:path` — optional restrictions
    * `:bots` — include automated traffic (default `false`)
    * `:now` — reference time (tests)
  """
  @spec filter(keyword()) :: filter()
  def filter(opts \\ []) do
    period = normalize_period(Keyword.get(opts, :period))
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    {from, to} = period_range(period, now)

    %{
      from: from,
      to: to,
      site: presence(Keyword.get(opts, :site)),
      path: presence(Keyword.get(opts, :path)),
      period: period,
      bots: Keyword.get(opts, :bots, false) == true
    }
  end

  @doc """
  The `{from, to}` window for a period label, `to` exclusive.

      iex> {from, to} = PhoenixKitWebAnalytics.Reports.period_range("today", ~U[2026-03-04 10:00:00Z])
      iex> {DateTime.to_date(from), DateTime.to_date(to)}
      {~D[2026-03-04], ~D[2026-03-05]}
  """
  @spec period_range(String.t(), DateTime.t() | nil) :: {DateTime.t(), DateTime.t()}
  def period_range(period, now \\ nil) do
    now = now || DateTime.utc_now()

    window(period, DateTime.to_date(now))
  end

  # Every window except "yesterday" ends at tomorrow's start, so a report always
  # includes what happened today.
  defp window("today", today), do: {start_of_day(today), end_of_today(today)}
  defp window("yesterday", today), do: {start_of_day(Date.add(today, -1)), start_of_day(today)}
  defp window("7d", today), do: trailing_days(today, 6)
  defp window("30d", today), do: trailing_days(today, 29)
  defp window("90d", today), do: trailing_days(today, 89)
  defp window("12m", today), do: trailing_days(today, 364)
  defp window("all", today), do: {~U[1970-01-01 00:00:00Z], end_of_today(today)}
  defp window(_period, today), do: window(@default_period, today)

  defp trailing_days(today, days_back),
    do: {start_of_day(Date.add(today, -days_back)), end_of_today(today)}

  defp end_of_today(today), do: start_of_day(Date.add(today, 1))

  @doc """
  The bucket size a period should be charted at.

  Short windows get hourly points; a year gets monthly ones, so the chart never
  tries to draw 365 bars.
  """
  @spec bucket_for(String.t()) :: :hour | :day | :month
  def bucket_for(period) when period in ["today", "yesterday"], do: :hour
  def bucket_for(period) when period in ["12m", "all"], do: :month
  def bucket_for(_period), do: :day

  # ── headline numbers ──────────────────────────────────────────────────────

  @doc """
  Headline totals for the window.

  Returns `pageviews`, `visitors`, `sessions`, `events`, `bounce_rate` (percent,
  `nil` with no sessions), `avg_session_seconds` (`nil` with no sessions), and
  `avg_response_ms` (`nil` when nothing recorded a duration).
  """
  @spec overview(filter()) :: map()
  def overview(filter) do
    totals = pageview_totals(filter)
    sessions = session_totals(filter)

    %{
      pageviews: totals.pageviews,
      visitors: totals.visitors,
      events: event_count(filter),
      avg_response_ms: to_float(totals.avg_response_ms),
      sessions: sessions.sessions,
      bounce_rate: percentage(sessions.bounces, sessions.sessions),
      avg_session_seconds: average(sessions.total_seconds, sessions.sessions)
    }
  end

  @doc """
  Totals for the window immediately before this one, for period-over-period
  comparison. `nil` for the `"all"` period, which has no "before".
  """
  @spec previous_overview(filter()) :: map() | nil
  def previous_overview(%{period: "all"}), do: nil

  def previous_overview(%{from: from, to: to} = filter) do
    span = DateTime.diff(to, from, :second)

    overview(%{filter | from: DateTime.add(from, -span, :second), to: from})
  end

  @doc "Distinct visitors seen in the last `minutes` — the \"right now\" number."
  @spec active_visitors(pos_integer(), String.t() | nil) :: non_neg_integer()
  def active_visitors(minutes \\ 5, site \\ nil) do
    now = DateTime.utc_now()

    %{
      from: DateTime.add(now, -minutes * 60, :second),
      to: DateTime.add(now, 60, :second),
      site: site,
      path: nil,
      period: "custom",
      bots: false
    }
    |> base_query()
    |> where([e], e.event_type != "leave")
    |> select([e], count(e.visitor_id, :distinct))
    |> one(0)
  end

  # ── trend ─────────────────────────────────────────────────────────────────

  @doc """
  Page views and visitors per time bucket, oldest first.

  Empty buckets are filled in with zeros, so a chart doesn't have to reason
  about gaps. Each entry is `%{bucket: DateTime.t(), pageviews: n, visitors: n}`.
  """
  @spec timeseries(filter(), :hour | :day | :month) :: [map()]
  def timeseries(filter, bucket \\ :day) do
    rows =
      filter
      |> pageview_query()
      |> bucketed(bucket)
      |> all([])
      |> Map.new(fn row -> {normalize_bucket(row.bucket), row} end)

    filter
    |> bucket_starts(bucket)
    |> Enum.map(fn start ->
      case Map.get(rows, start) do
        nil -> %{bucket: start, pageviews: 0, visitors: 0}
        row -> %{bucket: start, pageviews: row.pageviews, visitors: row.visitors}
      end
    end)
  end

  @doc """
  Daily page views and visitors, backfilled from rollups where raw events are
  gone.

  Raw events win wherever they exist — a day still present in the events table
  is always computed from it, and only fully pruned days come from
  `PhoenixKitWebAnalytics.Schemas.DailyStat`. Each entry is
  `%{date: Date.t(), pageviews: n, visitors: n, source: :events | :rollup}`.
  """
  @spec daily_timeseries(filter()) :: [map()]
  def daily_timeseries(filter) do
    rollups = rollup_days(filter)

    filter
    |> timeseries(:day)
    |> Enum.map(fn row ->
      date = DateTime.to_date(row.bucket)
      day = %{date: date, pageviews: row.pageviews, visitors: row.visitors, source: :events}

      if row.pageviews == 0, do: Map.get(rollups, date, day), else: day
    end)
  end

  # ── breakdowns ────────────────────────────────────────────────────────────

  @doc "Most viewed paths."
  @spec top_paths(filter(), keyword()) :: [map()]
  def top_paths(filter, opts \\ []),
    do: filter |> pageview_query() |> breakdown(:path, opts)

  @doc """
  Slowest paths by average server response time.

  This comes free with page-view tracking — the plug already measured the
  response — and is often the most actionable table here: a page that is both
  popular and slow shows up in one query. Paths with fewer than three views are
  excluded, since one cold request would otherwise top the list.
  """
  @spec slow_min_views() :: pos_integer()
  def slow_min_views, do: @slow_min_views

  @spec slowest_paths(filter(), keyword()) :: [map()]
  def slowest_paths(filter, opts \\ []) do
    filter
    |> pageview_query()
    |> where([e], not is_nil(e.duration_ms))
    |> group_by([e], e.path)
    |> having([e], count(e.uuid) >= ^@slow_min_views)
    |> select([e], %{
      label: e.path,
      pageviews: count(e.uuid),
      avg_ms: avg(e.duration_ms),
      max_ms: max(e.duration_ms)
    })
    |> order_by([e], desc: avg(e.duration_ms))
    |> limit(^row_limit(opts))
    |> all([])
    |> Enum.map(&%{&1 | avg_ms: to_float(&1.avg_ms)})
  end

  @doc "Top referring sources, excluding internal navigation and direct traffic."
  @spec top_referrers(filter(), keyword()) :: [map()]
  def top_referrers(filter, opts \\ []) do
    filter
    |> pageview_query()
    |> where([e], not is_nil(e.referrer_source))
    |> where([e], e.referrer_medium not in ["internal", "none"])
    |> breakdown(:referrer_source, opts)
  end

  @doc "Traffic grouped by channel — direct, organic, social, referral, email, paid."
  @spec channels(filter(), keyword()) :: [map()]
  def channels(filter, opts \\ []) do
    filter
    |> pageview_query()
    |> where([e], is_nil(e.referrer_medium) or e.referrer_medium != "internal")
    |> breakdown(:referrer_medium, Keyword.put_new(opts, :default_label, "none"))
  end

  @doc "Top UTM campaigns."
  @spec top_campaigns(filter(), keyword()) :: [map()]
  def top_campaigns(filter, opts \\ []) do
    filter
    |> pageview_query()
    |> where([e], not is_nil(e.utm_campaign))
    |> breakdown(:utm_campaign, opts)
  end

  @doc "Top UTM sources."
  @spec top_utm_sources(filter(), keyword()) :: [map()]
  def top_utm_sources(filter, opts \\ []) do
    filter
    |> pageview_query()
    |> where([e], not is_nil(e.utm_source))
    |> breakdown(:utm_source, opts)
  end

  @doc "Browser breakdown."
  @spec browsers(filter(), keyword()) :: [map()]
  def browsers(filter, opts \\ []) do
    filter
    |> pageview_query()
    |> breakdown(:browser, Keyword.put_new(opts, :default_label, "Unknown"))
  end

  @doc "Operating system breakdown."
  @spec operating_systems(filter(), keyword()) :: [map()]
  def operating_systems(filter, opts \\ []) do
    filter
    |> pageview_query()
    |> breakdown(:os, Keyword.put_new(opts, :default_label, "Unknown"))
  end

  @doc "Device class breakdown (desktop / mobile / tablet)."
  @spec devices(filter(), keyword()) :: [map()]
  def devices(filter, opts \\ []) do
    filter
    |> pageview_query()
    |> breakdown(:device_type, Keyword.put_new(opts, :default_label, "unknown"))
  end

  @doc """
  Country breakdown.

  Empty unless a geo resolver is configured or the host sits behind a CDN that
  sets a country header — see `PhoenixKitWebAnalytics.Geo`.
  """
  @spec countries(filter(), keyword()) :: [map()]
  def countries(filter, opts \\ []) do
    filter
    |> pageview_query()
    |> where([e], not is_nil(e.country_code))
    |> breakdown(:country_code, opts)
  end

  @doc "Browser language breakdown."
  @spec languages(filter(), keyword()) :: [map()]
  def languages(filter, opts \\ []) do
    filter
    |> pageview_query()
    |> where([e], not is_nil(e.language))
    |> breakdown(:language, opts)
  end

  @doc "Hosts that received traffic, for the site selector."
  @spec sites(filter()) :: [String.t()]
  def sites(filter) do
    filter
    |> base_query()
    |> where([e], not is_nil(e.site))
    |> group_by([e], e.site)
    |> order_by([e], desc: count(e.uuid))
    |> select([e], e.site)
    |> limit(50)
    |> all([])
  end

  # ── engagement ────────────────────────────────────────────────────────────

  @doc """
  How long visitors stay: `exits` (pages left), `avg_time_ms` (average time
  on a page, from leave events), and `avg_scroll` (average scroll depth, 0–100,
  `nil` without the client script).
  """
  @spec engagement(filter()) :: %{
          exits: non_neg_integer(),
          avg_time_ms: float() | nil,
          avg_scroll: float() | nil
        }
  def engagement(filter) do
    filter
    |> base_query()
    |> select([e], %{
      exits: fragment("COUNT(*) FILTER (WHERE ? = 'leave')", e.event_type),
      avg_time_ms:
        fragment("AVG(?) FILTER (WHERE ? = 'leave')", e.engaged_ms, e.event_type),
      avg_scroll: avg(e.scroll_depth)
    })
    |> one(%{exits: 0, avg_time_ms: nil, avg_scroll: nil})
    |> Map.update!(:avg_time_ms, &to_float/1)
    |> Map.update!(:avg_scroll, &to_float/1)
  end

  @doc "The pages visitors left the site from, ranked (`pageviews` holds the exit count)."
  @spec exit_pages(filter(), keyword()) :: [map()]
  def exit_pages(filter, opts \\ []) do
    filter
    |> base_query()
    |> where([e], e.event_type == "leave")
    |> breakdown(:path, opts)
  end

  @doc """
  Per-path engagement for the given paths: `%{path => %{exits, avg_time_ms,
  avg_scroll}}`. Paths with no leave recorded are absent.
  """
  @spec page_engagement(filter(), [String.t()]) :: %{String.t() => map()}
  def page_engagement(_filter, []), do: %{}

  def page_engagement(filter, paths) when is_list(paths) do
    filter
    |> base_query()
    |> where([e], e.path in ^paths and e.event_type in ["leave", "interaction"])
    |> group_by([e], e.path)
    |> select([e], %{
      path: e.path,
      exits: fragment("COUNT(*) FILTER (WHERE ? = 'leave')", e.event_type),
      avg_time_ms:
        fragment("AVG(?) FILTER (WHERE ? = 'leave')", e.engaged_ms, e.event_type),
      avg_scroll: avg(e.scroll_depth)
    })
    |> all([])
    |> Map.new(fn row ->
      {row.path,
       %{exits: row.exits, avg_time_ms: to_float(row.avg_time_ms), avg_scroll: to_float(row.avg_scroll)}}
    end)
  end

  @doc """
  What visitors did, ranked: LiveView events by name, and the client script's
  clicks by kind and target (`"outbound · github.com/acme"`). Each row is
  `%{label, name, target, pageviews: count, visitors}`.
  """
  @spec top_interactions(filter(), keyword()) :: [map()]
  def top_interactions(filter, opts \\ []) do
    filter
    |> base_query()
    |> where([e], e.event_type == "interaction" and e.event_name != "scroll")
    |> group_by([e], [e.event_name, e.target])
    |> select([e], %{
      name: e.event_name,
      target: e.target,
      pageviews: count(e.uuid),
      visitors: count(e.visitor_id, :distinct)
    })
    |> order_by([e], desc: count(e.uuid))
    |> limit(^row_limit(opts))
    |> all([])
    |> Enum.map(fn row ->
      Map.put(row, :label, Enum.join(Enum.reject([row.name, row.target], &is_nil/1), " · "))
    end)
  end

  # ── sessions ──────────────────────────────────────────────────────────────

  @doc """
  Visits in the window, newest first — one row per session that has at least
  one page view:

      %{session_id, started_at, ended_at, seconds, pageviews, interactions,
        entry_path, exit_path, source, medium, browser, os, device_type,
        country_code, user_uuid}

  `source`/`medium` are the first page view's. `seconds` spans every event
  type, so a session that ended with a leave counts the time on its last
  page.

  ## Options

    * `:limit` — default 50
    * `:before` — a `DateTime`; only sessions that started before it (paging)
    * `:user_uuid` — only sessions in which that signed-in user was active
  """
  @spec sessions(filter(), keyword()) :: [map()]
  def sessions(filter, opts \\ []) do
    filter
    |> base_query()
    |> sessions_for_user(Keyword.get(opts, :user_uuid))
    |> group_by([e], e.session_id)
    |> having([e], fragment("COUNT(*) FILTER (WHERE ? = 'pageview')", e.event_type) > 0)
    |> sessions_before(Keyword.get(opts, :before))
    |> select([e], %{
      session_id: e.session_id,
      started_at: min(e.inserted_at),
      ended_at: max(e.inserted_at),
      pageviews: fragment("COUNT(*) FILTER (WHERE ? = 'pageview')", e.event_type),
      interactions:
        fragment("COUNT(*) FILTER (WHERE ? IN ('interaction', 'event'))", e.event_type),
      entry_path:
        fragment(
          "(ARRAY_AGG(? ORDER BY ?) FILTER (WHERE ? = 'pageview'))[1]",
          e.path,
          e.inserted_at,
          e.event_type
        ),
      exit_path:
        fragment(
          "(ARRAY_AGG(? ORDER BY ? DESC) FILTER (WHERE ? = 'pageview'))[1]",
          e.path,
          e.inserted_at,
          e.event_type
        ),
      source:
        fragment(
          "(ARRAY_AGG(? ORDER BY ?) FILTER (WHERE ? = 'pageview'))[1]",
          e.referrer_source,
          e.inserted_at,
          e.event_type
        ),
      medium:
        fragment(
          "(ARRAY_AGG(? ORDER BY ?) FILTER (WHERE ? = 'pageview'))[1]",
          e.referrer_medium,
          e.inserted_at,
          e.event_type
        ),
      browser: max(e.browser),
      os: max(e.os),
      device_type: max(e.device_type),
      country_code: max(e.country_code),
      user_uuid:
        type(
          fragment("(ARRAY_AGG(?) FILTER (WHERE ? IS NOT NULL))[1]", e.user_uuid, e.user_uuid),
          Ecto.UUID
        )
    })
    |> order_by([e], desc: min(e.inserted_at))
    |> limit(^row_limit(opts, 50))
    |> all([])
    |> Enum.map(fn row ->
      Map.put(row, :seconds, max(DateTime.diff(to_utc(row.ended_at), to_utc(row.started_at)), 0))
    end)
  end

  @doc """
  Every event of one session, oldest first — the visit replayed. At most 1000
  events; `[]` for an id that isn't a UUID.
  """
  @spec session_timeline(String.t()) :: [Event.t()]
  def session_timeline(session_id) do
    case Ecto.UUID.cast(session_id) do
      {:ok, uuid} ->
        from(e in Event, where: e.session_id == ^uuid, order_by: [asc: e.inserted_at], limit: 1000)
        |> all([])

      :error ->
        []
    end
  end

  # ── custom events ─────────────────────────────────────────────────────────

  @doc "Custom events, ranked by occurrence."
  @spec top_events(filter(), keyword()) :: [map()]
  def top_events(filter, opts \\ []) do
    filter
    |> base_query()
    |> where([e], e.event_type == "event" and not is_nil(e.event_name))
    |> breakdown(:event_name, opts)
  end

  @doc """
  The most recent hits, newest first — the live feed.

  Returns whole `PhoenixKitWebAnalytics.Schemas.Event` structs. Every column is
  already non-identifying, so there is nothing to redact for display.

  ## Options

    * `:limit` — default 50
    * `:event_type` — `"pageview"`, `"event"`, `"interaction"` or `"leave"`
      to show one kind only
  """
  @spec recent_hits(filter(), keyword()) :: [Event.t()]
  def recent_hits(filter, opts \\ []) do
    query =
      filter
      |> base_query()
      |> order_by([e], desc: e.inserted_at)
      |> limit(^row_limit(opts, 50))

    case Keyword.get(opts, :event_type) do
      type when type in ["pageview", "event", "interaction", "leave"] ->
        where(query, [e], e.event_type == ^type)

      _ ->
        query
    end
    |> all([])
  end

  @doc """
  Stored rows and the oldest retained timestamp — shown on the settings page
  so an operator can see what retention is actually doing.

  The event count is exact below 100,000 rows and Postgres's planner estimate
  above that (`events_estimated?: true`): an exact `count(*)` over a large
  append-only table is a full scan, and this runs on every settings and
  Modules page load.
  """
  @spec storage_stats() :: %{
          events: non_neg_integer(),
          events_estimated?: boolean(),
          rollup_days: non_neg_integer(),
          oldest: DateTime.t() | nil
        }
  def storage_stats do
    {events, estimated?} = event_count_estimate()

    %{
      events: events,
      events_estimated?: estimated?,
      rollup_days: DailyStat |> select([s], count(s.uuid)) |> one(0),
      oldest: Event |> select([e], min(e.inserted_at)) |> one(nil)
    }
  end

  @exact_count_limit 100_000

  defp event_count_estimate do
    capped =
      from(e in subquery(from(e in Event, select: e.uuid, limit: @exact_count_limit + 1)),
        select: count()
      )
      |> one(0)

    if capped <= @exact_count_limit do
      {capped, false}
    else
      {planner_estimate() || capped, true}
    end
  end

  defp planner_estimate do
    table =
      case Event.__schema__(:prefix) do
        nil -> "phoenix_kit_web_analytics_events"
        prefix -> "#{prefix}.phoenix_kit_web_analytics_events"
      end

    case repo().query("SELECT reltuples::bigint FROM pg_class WHERE oid = to_regclass($1)", [table],
           log: false
         ) do
      {:ok, %{rows: [[count]]}} when is_integer(count) and count > 0 -> count
      _ -> nil
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.debug("[WebAnalytics] row estimate failed: #{Exception.message(error)}")
      nil
  end

  # ── query building ────────────────────────────────────────────────────────

  defp base_query(filter) do
    Event
    |> where([e], e.inserted_at >= ^filter.from and e.inserted_at < ^filter.to)
    |> filter_site(filter.site)
    |> filter_path(filter[:path])
    |> filter_bots(Map.get(filter, :bots, false))
  end

  defp filter_bots(query, true), do: query
  defp filter_bots(query, _bots), do: where(query, [e], e.is_bot == false)

  defp sessions_for_user(query, nil), do: query

  defp sessions_for_user(query, user_uuid) do
    case Ecto.UUID.cast(user_uuid) do
      {:ok, uuid} ->
        user_sessions = from(u in Event, where: u.user_uuid == ^uuid, select: u.session_id)
        where(query, [e], e.session_id in subquery(user_sessions))

      :error ->
        where(query, [e], false)
    end
  end

  defp sessions_before(query, %DateTime{} = before),
    do: having(query, [e], min(e.inserted_at) < ^before)

  defp sessions_before(query, _before), do: query

  defp to_utc(%DateTime{} = at), do: at
  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp pageview_query(filter) do
    filter |> base_query() |> where([e], e.event_type == "pageview")
  end

  defp filter_site(query, nil), do: query
  defp filter_site(query, site), do: where(query, [e], e.site == ^site)

  defp filter_path(query, nil), do: query
  defp filter_path(query, path), do: where(query, [e], e.path == ^path)

  # One shape for every "label + counts, ranked" table. The grouped column is
  # passed as a field atom (never interpolated SQL), and NULL labels are
  # replaced in Elixir rather than with a coalesce, which keeps the query
  # identical for every dimension.
  defp breakdown(query, field, opts) do
    default_label = Keyword.get(opts, :default_label)

    query
    |> group_by([e], field(e, ^field))
    |> select([e], %{
      label: field(e, ^field),
      pageviews: count(e.uuid),
      visitors: count(e.visitor_id, :distinct)
    })
    |> order_by([e], desc: count(e.uuid))
    |> limit(^row_limit(opts))
    |> all([])
    |> Enum.map(fn row -> %{row | label: row.label || default_label} end)
    |> Enum.reject(&is_nil(&1.label))
  end

  # `date_trunc`'s unit must be a literal — never interpolate one — so each
  # supported bucket gets its own clause.
  defp bucketed(query, :hour) do
    query
    |> group_by([e], fragment("date_trunc('hour', ?)", e.inserted_at))
    |> select([e], %{
      bucket: fragment("date_trunc('hour', ?)", e.inserted_at),
      pageviews: count(e.uuid),
      visitors: count(e.visitor_id, :distinct)
    })
  end

  defp bucketed(query, :day) do
    query
    |> group_by([e], fragment("date_trunc('day', ?)", e.inserted_at))
    |> select([e], %{
      bucket: fragment("date_trunc('day', ?)", e.inserted_at),
      pageviews: count(e.uuid),
      visitors: count(e.visitor_id, :distinct)
    })
  end

  defp bucketed(query, :month) do
    query
    |> group_by([e], fragment("date_trunc('month', ?)", e.inserted_at))
    |> select([e], %{
      bucket: fragment("date_trunc('month', ?)", e.inserted_at),
      pageviews: count(e.uuid),
      visitors: count(e.visitor_id, :distinct)
    })
  end

  defp pageview_totals(filter) do
    filter
    |> pageview_query()
    |> select([e], %{
      pageviews: count(e.uuid),
      visitors: count(e.visitor_id, :distinct),
      avg_response_ms: avg(e.duration_ms)
    })
    |> one(@empty_totals)
  end

  defp event_count(filter) do
    filter
    |> base_query()
    |> where([e], e.event_type == "event")
    |> select([e], count(e.uuid))
    |> one(0)
  end

  # Bounce rate and session length both need per-session facts first, so they
  # share one grouped subquery rather than scanning the window twice.
  defp session_totals(filter) do
    per_session = filter |> base_query() |> SessionStats.per_session()

    from(s in subquery(per_session),
      select: %{
        sessions: count(s.session_id),
        bounces: fragment("COUNT(*) FILTER (WHERE ? = 1)", s.hits),
        total_seconds: sum(s.seconds)
      }
    )
    |> one(@empty_sessions)
  end

  defp rollup_days(filter) do
    from_date = DateTime.to_date(filter.from)
    to_date = DateTime.to_date(filter.to)

    query =
      from(s in DailyStat,
        where: s.date >= ^from_date and s.date <= ^to_date,
        group_by: s.date,
        select: %{date: s.date, pageviews: sum(s.pageviews), visitors: sum(s.visitors)}
      )

    query
    |> filter_rollup_site(filter.site)
    |> all([])
    |> Map.new(fn row ->
      {row.date,
       %{
         date: row.date,
         pageviews: row.pageviews || 0,
         visitors: row.visitors || 0,
         source: :rollup
       }}
    end)
  end

  defp filter_rollup_site(query, nil), do: query
  defp filter_rollup_site(query, site), do: where(query, [s], s.site == ^site)

  # The bucket starts a chart should show, whether or not they hold data.
  # Future buckets inside today are dropped — an empty bar for 11pm reads as
  # "no traffic" rather than "hasn't happened yet".
  defp bucket_starts(filter, :hour) do
    now = DateTime.utc_now()

    filter.from
    |> Stream.iterate(&DateTime.add(&1, 3600, :second))
    |> Enum.take_while(&(DateTime.compare(&1, filter.to) == :lt))
    |> Enum.map(&(&1 |> Map.merge(%{minute: 0, second: 0}) |> DateTime.truncate(:second)))
    |> Enum.take_while(&(DateTime.compare(&1, now) != :gt))
  end

  defp bucket_starts(filter, :day) do
    from_date = DateTime.to_date(filter.from)
    to_date = filter.to |> DateTime.add(-1, :second) |> DateTime.to_date()

    if Date.compare(from_date, to_date) == :gt do
      []
    else
      from_date |> Date.range(to_date) |> Enum.map(&start_of_day/1)
    end
  end

  defp bucket_starts(filter, :month) do
    from_month = filter |> first_month() |> Date.beginning_of_month()
    to_month = filter.to |> DateTime.add(-1, :second) |> DateTime.to_date()

    from_month
    |> Stream.iterate(&(&1 |> Date.add(32) |> Date.beginning_of_month()))
    |> Enum.take_while(&(Date.compare(&1, to_month) != :gt))
    |> Enum.map(&start_of_day/1)
  end

  # "All time" starts at the oldest data, not at the 1970 lower bound of its
  # window — otherwise the chart is 680 empty months and one sliver.
  defp first_month(%{period: "all"} = filter) do
    oldest_event = Event |> select([e], min(e.inserted_at)) |> one(nil)
    oldest_rollup = DailyStat |> select([s], min(s.date)) |> one(nil)

    [oldest_event && to_utc(oldest_event) |> DateTime.to_date(), oldest_rollup]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(Date, fn -> DateTime.to_date(filter.to) end)
  end

  defp first_month(filter), do: DateTime.to_date(filter.from)

  # `date_trunc` returns a timestamptz, which Postgrex decodes to a DateTime
  # (microsecond precision); bucket keys are compared at second precision.
  defp normalize_bucket(%DateTime{} = bucket), do: DateTime.truncate(bucket, :second)

  defp normalize_bucket(%NaiveDateTime{} = bucket) do
    bucket |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)
  end

  # ── plumbing ──────────────────────────────────────────────────────────────

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

  defp row_limit(opts, default \\ @default_limit) do
    case Keyword.get(opts, :limit, default) do
      value when is_integer(value) and value > 0 and value <= 1_000 -> value
      _ -> default
    end
  end

  defp normalize_period(period) when is_binary(period) do
    if Enum.any?(@periods, fn {value, _label} -> value == period end),
      do: period,
      else: @default_period
  end

  defp normalize_period(_period), do: @default_period

  defp start_of_day(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp percentage(_part, total) when total in [0, nil], do: nil
  defp percentage(nil, _total), do: nil
  defp percentage(part, total), do: part * 100 / total

  defp average(_total, count) when count in [0, nil], do: nil
  defp average(nil, _count), do: nil
  defp average(total, count), do: to_float(total) / count

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp to_float(value) when is_number(value), do: value / 1

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
