defmodule PhoenixKitWebAnalytics.Retention do
  @moduledoc """
  Keeps the events table from growing without bound.

  Analytics is the one table in a PhoenixKit app that grows with *traffic*
  rather than with content, so it needs a story for old data from day one.
  Once an hour this process:

  1. **Rolls up** every completed day that doesn't have a
     `PhoenixKitWebAnalytics.Schemas.DailyStat` row yet — page views, visitors,
     sessions, bounces, and total session seconds, per site.
  2. **Prunes** raw events older than `web_analytics_retention_days`
     (365 by default; `0` disables pruning), in batches, and only for days that
     were rolled up first.

  So the long-range trend line is permanent while the raw rows behind it are
  not. What is lost at the retention horizon is the ability to break an old day
  down by page or referrer — see `PhoenixKitWebAnalytics.Reports` for how
  reports handle the boundary.

  ## Scheduling

  The first run is deliberately a couple of minutes after boot: a host restart
  should not spend its first seconds deleting rows while it is also serving the
  post-deploy traffic spike. Runs are skipped entirely while the module is
  disabled.

  Rollup is idempotent — a day is aggregated once, and the upsert makes a
  repeat run a no-op — so a crash or a restart mid-pass costs nothing.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Schemas.DailyStat
  alias PhoenixKitWebAnalytics.Schemas.Event

  @interval_ms :timer.hours(1)
  @boot_delay_ms :timer.minutes(2)
  @max_days_per_run 60
  @delete_batch 5_000
  @max_delete_batches 200

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs a rollup + prune pass immediately, in the caller's process.

  Returns `%{rolled_up: days, pruned: rows}`. Used by the admin settings page's
  "Run now" action and by tests, which need the work to happen on the sandbox
  connection.
  """
  @spec run() :: %{rolled_up: non_neg_integer(), pruned: non_neg_integer()}
  def run do
    rolled_up = rollup_pending_days()
    pruned = prune_old_events()

    %{rolled_up: rolled_up, pruned: pruned}
  end

  @doc "Asks the running process to do a pass. Returns immediately."
  @spec run_async() :: :ok
  def run_async do
    if pid = Process.whereis(__MODULE__), do: send(pid, :run)
    :ok
  end

  @impl GenServer
  def init(_opts) do
    schedule(@boot_delay_ms)
    {:ok, %{last_run: nil}}
  end

  @impl GenServer
  def handle_info(:run, state) do
    state = maybe_run(state)
    schedule(@interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── rollup ────────────────────────────────────────────────────────────────

  @doc """
  Writes `DailyStat` rows for completed days that don't have one yet.

  Returns the number of days rolled up. At most #{@max_days_per_run} days are
  handled per pass, so a first run against a large backlog spreads its work
  over several hours instead of locking up the database in one go.
  """
  @spec rollup_pending_days() :: non_neg_integer()
  def rollup_pending_days do
    dates = pending_dates()

    Enum.reduce(dates, 0, fn date, count ->
      case rollup_day(date) do
        :ok -> count + 1
        _ -> count
      end
    end)
  end

  @doc "Aggregates one day into `DailyStat` rows, one per site."
  @spec rollup_day(Date.t()) :: :ok | :error
  def rollup_day(%Date{} = date) do
    from = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    to = DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")

    totals = day_totals(from, to)
    sessions = day_sessions(from, to)

    totals
    |> Enum.map(fn {site, counts} ->
      session_facts = Map.get(sessions, site, %{sessions: 0, bounces: 0, seconds: 0})

      %{
        date: date,
        site: site,
        pageviews: counts.pageviews,
        visitors: counts.visitors,
        events: counts.events,
        sessions: session_facts.sessions,
        bounces: session_facts.bounces,
        total_session_seconds: round(session_facts.seconds)
      }
    end)
    |> Enum.each(&upsert_daily_stat/1)

    :ok
  rescue
    error ->
      Logger.warning("[WebAnalytics] rollup failed for #{date}: #{Exception.message(error)}")
      :error
  end

  # ── prune ─────────────────────────────────────────────────────────────────

  @doc """
  Deletes raw events past the retention horizon, in batches.

  Returns the number of rows deleted. Days that have not been rolled up yet are
  left alone — pruning never runs ahead of the aggregation that preserves the
  trend line.
  """
  @spec prune_old_events() :: non_neg_integer()
  def prune_old_events do
    case Config.retention_days() do
      days when is_integer(days) and days > 0 -> prune_before(cutoff(days))
      _ -> 0
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp maybe_run(state) do
    if Config.enabled?() do
      result = run()

      if result.rolled_up > 0 or result.pruned > 0 do
        Logger.info(
          "[WebAnalytics] retention: rolled up #{result.rolled_up} day(s), " <>
            "pruned #{result.pruned} event(s)"
        )
      end

      %{state | last_run: DateTime.utc_now()}
    else
      state
    end
  rescue
    error ->
      Logger.warning("[WebAnalytics] retention pass failed: #{Exception.message(error)}")
      state
  catch
    :exit, reason ->
      Logger.debug("[WebAnalytics] retention pass exited: #{inspect(reason)}")
      state
  end

  defp schedule(delay), do: Process.send_after(self(), :run, delay)

  defp pending_dates do
    today = Date.utc_today()
    horizon = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    event_dates =
      from(e in Event,
        where: e.inserted_at < ^horizon,
        select: fragment("DISTINCT DATE(? AT TIME ZONE 'UTC')", e.inserted_at),
        order_by: fragment("1"),
        limit: ^(@max_days_per_run * 2)
      )
      |> repo().all()
      |> Enum.map(&to_date/1)
      |> Enum.reject(&is_nil/1)

    rolled_up =
      from(s in DailyStat, where: s.date in ^event_dates, select: s.date)
      |> repo().all()
      |> MapSet.new()

    event_dates
    |> Enum.reject(&MapSet.member?(rolled_up, &1))
    |> Enum.take(@max_days_per_run)
  rescue
    _ -> []
  end

  defp day_totals(from, to) do
    from(e in Event,
      where: e.inserted_at >= ^from and e.inserted_at < ^to,
      group_by: fragment("COALESCE(?, '')", e.site),
      select: %{
        site: fragment("COALESCE(?, '')", e.site),
        pageviews: fragment("COUNT(*) FILTER (WHERE ? = 'pageview')", e.event_type),
        events: fragment("COUNT(*) FILTER (WHERE ? = 'event')", e.event_type),
        visitors: count(e.visitor_id, :distinct)
      }
    )
    |> repo().all()
    |> Map.new(fn row -> {row.site, row} end)
  end

  defp day_sessions(from, to) do
    per_session =
      from(e in Event,
        where: e.inserted_at >= ^from and e.inserted_at < ^to,
        where: e.event_type == "pageview",
        group_by: [fragment("COALESCE(?, '')", e.site), e.session_id],
        select: %{
          site: fragment("COALESCE(?, '')", e.site),
          session_id: e.session_id,
          hits: count(e.uuid),
          seconds: fragment("EXTRACT(EPOCH FROM (MAX(?) - MIN(?)))", e.inserted_at, e.inserted_at)
        }
      )

    from(s in subquery(per_session),
      group_by: s.site,
      select: %{
        site: s.site,
        sessions: count(s.session_id),
        bounces: fragment("COUNT(*) FILTER (WHERE ? = 1)", s.hits),
        seconds: sum(s.seconds)
      }
    )
    |> repo().all()
    |> Map.new(fn row ->
      {row.site, %{sessions: row.sessions, bounces: row.bounces, seconds: to_number(row.seconds)}}
    end)
  end

  # Upsert rather than insert: a day may be re-rolled after a crash, and two
  # nodes running the retention process must not fight over the unique index.
  defp upsert_daily_stat(attrs) do
    %DailyStat{}
    |> DailyStat.changeset(attrs)
    |> repo().insert(
      on_conflict:
        {:replace,
         [
           :pageviews,
           :visitors,
           :sessions,
           :bounces,
           :events,
           :total_session_seconds,
           :updated_at
         ]},
      conflict_target: [:date, :site]
    )
  end

  defp cutoff(days) do
    Date.utc_today()
    |> Date.add(-days)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp prune_before(cutoff) do
    # Never delete a day that hasn't been aggregated — otherwise a misconfigured
    # retention window silently destroys history instead of compacting it.
    case oldest_unrolled_date() do
      nil ->
        delete_batches(cutoff, 0, 0)

      date ->
        cutoff
        |> min_datetime(DateTime.new!(date, ~T[00:00:00], "Etc/UTC"))
        |> delete_batches(0, 0)
    end
  end

  defp oldest_unrolled_date do
    case pending_dates() do
      [] -> nil
      dates -> Enum.min(dates, Date)
    end
  end

  defp min_datetime(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp delete_batches(_cutoff, deleted, batches) when batches >= @max_delete_batches, do: deleted

  defp delete_batches(cutoff, deleted, batches) do
    ids =
      from(e in Event,
        where: e.inserted_at < ^cutoff,
        select: e.uuid,
        limit: @delete_batch
      )

    {count, _} =
      from(e in Event, where: e.uuid in subquery(ids))
      |> repo().delete_all()

    if count < @delete_batch do
      deleted + count
    else
      delete_batches(cutoff, deleted + count, batches + 1)
    end
  rescue
    _ -> deleted
  end

  defp to_date(%Date{} = date), do: date

  defp to_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp to_date(_value), do: nil

  defp to_number(nil), do: 0
  defp to_number(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp to_number(value) when is_number(value), do: value

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
