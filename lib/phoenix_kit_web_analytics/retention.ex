defmodule PhoenixKitWebAnalytics.Retention do
  @moduledoc """
  Keeps the events table from growing without bound.

  Analytics is the one table in a PhoenixKit app that grows with *traffic*
  rather than with content, so it needs a story for old data from day one.
  Once an hour this process:

  1. **Rolls up** completed days into `PhoenixKitWebAnalytics.Schemas.DailyStat`
     rows — page views, visitors, sessions, bounces, and total session
     seconds, per site.
  2. **Prunes** raw events older than `web_analytics_retention_days`
     (365 by default; `0` disables pruning), in batches, and only for days that
     were rolled up first.

  So the long-range trend line is permanent while the raw rows behind it are
  not. What is lost at the retention horizon is the ability to break an old day
  down by page or referrer — see `PhoenixKitWebAnalytics.Reports` for how
  reports handle the boundary.

  ## The watermark

  Progress is a single date — "every day up to and including this one is
  rolled up" — kept in the `web_analytics_rolled_through` setting. Each pass
  walks forward from it (at most #{60} days at a time, so a first run against a
  large backlog spreads over several hours), and advances it only past days
  whose rollup committed. Prune never deletes past the watermark, and does
  nothing at all if the watermark can't be read: a database hiccup must cost
  an hour of compaction, never a day of history.

  A day is re-rolled by the passes in the first #{3} hours after it ends. A
  hit that was being written as midnight passed lands in "yesterday" after
  that day's first rollup; a re-roll picks it up, and replacing the day whole
  makes it idempotent. After that the day is final — re-rolling it every hour
  would re-read a whole day of raw events 24 times for nothing.

  Each breakdown keeps at most #{5_000} values per day (the most visited), so a
  site with an id in every URL can't turn one day's rollup into a million
  rows. The long tail below that still counts in the day's totals.

  Sessions from before schema V3 get their first hit marked here too
  (`backfill_session_starts/0`), a batch at a time, so the migration never
  rewrites a large table in one statement.

  Days are UTC days, bounded with `inserted_at` ranges — never with a
  `DATE(...)` cast, which would depend on the database session's time zone.

  ## Scheduling

  The first run is deliberately a couple of minutes after boot: a host restart
  should not spend its first seconds deleting rows while it is also serving the
  post-deploy traffic spike. Runs are skipped entirely while the module is
  disabled.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias PhoenixKit.Settings
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Dimensions
  alias PhoenixKitWebAnalytics.Schemas.DailyDim
  alias PhoenixKitWebAnalytics.Schemas.DailyStat
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.SessionStats
  alias PhoenixKitWebAnalytics.Tracking

  @interval_ms :timer.hours(1)
  @boot_delay_ms :timer.minutes(2)
  @max_days_per_run 60
  @delete_batch 5_000
  @max_delete_batches 200
  @reroll_days 2
  @settle_seconds 3 * 3600
  @max_dim_rows 5_000
  @backfill_batch 5_000
  @max_backfill_batches 100
  @backfill_key "web_analytics_session_starts_backfilled"
  @stat_fields ~w(pageviews visitors events exits engaged_ms_sum engaged_count scroll_sum
                  scroll_count duration_ms_sum duration_count)a
  @watermark_key "web_analytics_rolled_through"

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
    # One pass at a time across every node: "Run now" and each node's hourly
    # timer would otherwise re-aggregate the same days side by side. The lock
    # is session-level, so it's taken and released on one checked-out
    # connection; a pass that finds it held skips rather than queueing.
    repo().checkout(fn ->
      if try_lock() do
        try do
          backfill_session_starts()
          %{rolled_up: rollup_pending_days(), pruned: prune_old_events()}
        after
          unlock()
        end
      else
        Logger.info("[WebAnalytics] retention pass skipped: another pass is running")
        %{rolled_up: 0, pruned: 0}
      end
    end)
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
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:run, state) do
    maybe_run()
    schedule(@interval_ms)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("[WebAnalytics] Retention ignored #{inspect(message)}")
    {:noreply, state}
  end

  # ── rollup ────────────────────────────────────────────────────────────────

  @doc """
  Rolls up the completed days past the watermark, and re-rolls the last
  #{@reroll_days}.

  Returns the number of newly rolled-up days that had traffic. At most
  #{@max_days_per_run} days are handled per pass. Stops at the first day whose
  rollup fails, so the watermark never skips a day.
  """
  @spec rollup_pending_days(DateTime.t()) :: non_neg_integer()
  def rollup_pending_days(now \\ DateTime.utc_now()) do
    yesterday = Date.add(DateTime.to_date(now), -1)

    case first_pending_date(yesterday) do
      {:ok, nil} ->
        reroll_recent(yesterday, nil, now)
        0

      {:ok, first} ->
        last = Enum.min([Date.add(first, @max_days_per_run - 1), yesterday], Date)
        count = roll_forward(Date.range(first, last))
        reroll_recent(yesterday, first, now)
        count

      :error ->
        0
    end
  end

  @doc """
  The last day known to be fully rolled up, or `nil` when nothing has been
  rolled up yet. `:error` when the setting can't be read.
  """
  @spec rolled_through() :: {:ok, Date.t() | nil} | :error
  def rolled_through do
    case Settings.get_setting(@watermark_key, nil) do
      nil -> {:ok, nil}
      value -> {:ok, parse_date(value)}
    end
  rescue
    error ->
      Logger.warning("[WebAnalytics] could not read the rollup watermark: #{inspect(error)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("[WebAnalytics] could not read the rollup watermark: #{inspect(reason)}")
      :error
  end

  @doc "Aggregates one day into `DailyStat` rows, one per site."
  @spec rollup_day(Date.t()) :: :ok | :error
  def rollup_day(%Date{} = date) do
    from = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    to = DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")

    # Bot traffic (stored only with track_bots on) stays out of the rollups,
    # as it stays out of every report unless asked for.
    day = from(e in Event, where: e.inserted_at >= ^from and e.inserted_at < ^to and not e.is_bot)

    totals = day |> Dimensions.totals() |> repo().all() |> Map.new(&{&1.site, &1})
    sessions = day_sessions(day)
    now = DateTime.utc_now()

    stats =
      Enum.map(totals, fn {site, counts} ->
        session_facts = Map.get(sessions, site, %{sessions: 0, bounces: 0, seconds: 0})

        counts
        |> Map.take(@stat_fields)
        |> Map.new(fn {key, value} -> {key, to_integer_if_decimal(value)} end)
        |> Map.merge(%{
          date: date,
          site: site,
          sessions: session_facts.sessions,
          bounces: session_facts.bounces,
          total_session_seconds: round(session_facts.seconds)
        })
      end)

    dims =
      Enum.flat_map(Dimensions.names(), fn dimension ->
        day
        |> Dimensions.aggregate(dimension, limit: @max_dim_rows)
        |> repo().all()
        |> Enum.reject(&(is_nil(&1.value) or (&1.hits == 0 and &1.exits == 0)))
        |> Enum.map(&dim_row(&1, date, dimension, now))
      end)

    # One transaction per day: a day is replaced whole or not at all, so a
    # failure can't leave it looking rolled up while its raw rows become
    # eligible for pruning.
    result =
      repo().transaction(fn ->
        Enum.each(stats, &upsert_or_rollback/1)
        from(d in DailyDim, where: d.date == ^date) |> repo().delete_all()

        dims
        |> Enum.chunk_every(1_000)
        |> Enum.each(&repo().insert_all(DailyDim, &1))
      end)

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[WebAnalytics] rollup failed for #{date}: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.warning("[WebAnalytics] rollup failed for #{date}: #{Exception.message(error)}")
      :error
  end

  defp dim_row(row, date, dimension, now) do
    row
    |> Map.update!(:value, &Tracking.truncate_utf8(to_string(&1), 2048))
    |> Map.update!(:detail, &Tracking.truncate_utf8(to_string(&1), 512))
    |> Map.merge(%{
      uuid: UUIDv7.generate(),
      date: date,
      dimension: dimension,
      inserted_at: now
    })
    |> Map.new(fn {key, value} -> {key, to_integer_if_decimal(value)} end)
  end

  defp to_integer_if_decimal(%Decimal{} = value), do: Decimal.to_integer(Decimal.round(value))
  defp to_integer_if_decimal(value), do: value

  # ── session-start backfill ────────────────────────────────────────────────

  @doc """
  Marks the first hit of every session recorded before schema V3, which
  introduced `session_start` — at most #{@max_backfill_batches} batches of
  #{@backfill_batch} sessions per call, walking `session_id` in order from a
  cursor kept in the `#{@backfill_key}` setting (`"done"` once finished).

  Returns the number of hits it marked. Sessions recorded since V3 are
  already marked; meeting one again is harmless (its first hit is the one
  marked).
  """
  @spec backfill_session_starts() :: non_neg_integer()
  def backfill_session_starts do
    case Settings.get_setting(@backfill_key, nil) do
      "done" ->
        0

      cursor ->
        {marked, reached} = backfill_from(cursor, 0, 0)
        # Saved once per pass, not per batch: every setting write is also an
        # activity-log entry. A pass cut short re-walks its batches, harmlessly.
        if reached != cursor, do: save_backfill_cursor(reached)
        marked
    end
  rescue
    error ->
      Logger.warning("[WebAnalytics] session-start backfill failed: #{Exception.message(error)}")
      0
  end

  defp backfill_from(cursor, marked, @max_backfill_batches), do: {marked, cursor}

  defp backfill_from(cursor, marked, batches) do
    # The first hit of the next sessions after the cursor: DISTINCT ON walks
    # the (session_id, inserted_at) index, so each batch costs its own size.
    firsts =
      from(e in Event,
        distinct: e.session_id,
        order_by: [asc: e.session_id, asc: e.inserted_at, asc: e.uuid],
        limit: @backfill_batch,
        select: {e.session_id, e.uuid}
      )
      |> after_session(cursor)
      |> repo().all()

    case firsts do
      [] ->
        {marked, "done"}

      firsts ->
        uuids = Enum.map(firsts, &elem(&1, 1))

        {count, _} =
          from(e in Event, where: e.uuid in ^uuids and not e.session_start)
          |> repo().update_all(set: [session_start: true])

        {last_session, _} = List.last(firsts)
        backfill_from(last_session, marked + count, batches + 1)
    end
  end

  defp after_session(query, nil), do: query
  defp after_session(query, cursor), do: where(query, [e], e.session_id > ^cursor)

  defp save_backfill_cursor(value) do
    Settings.update_setting_with_module(@backfill_key, value, Config.module_key())
  end

  # ── prune ─────────────────────────────────────────────────────────────────

  @doc """
  Deletes raw events past the retention horizon, in batches.

  Returns the number of rows deleted. Days past the rollup watermark are left
  alone — pruning never runs ahead of the aggregation that preserves the trend
  line — and nothing is deleted when the watermark can't be read.
  """
  @spec prune_old_events() :: non_neg_integer()
  def prune_old_events do
    case Config.retention_days() do
      days when is_integer(days) and days > 0 -> prune_before(cutoff(days))
      _ -> 0
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp maybe_run do
    if Config.enabled?() do
      result = run()

      if result.rolled_up > 0 or result.pruned > 0 do
        Logger.info(
          "[WebAnalytics] retention: rolled up #{result.rolled_up} day(s), " <>
            "pruned #{result.pruned} event(s)"
        )
      end
    end

    :ok
  rescue
    error ->
      Logger.warning("[WebAnalytics] retention pass failed: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[WebAnalytics] retention pass exited: #{inspect(reason)}")
      :ok
  end

  defp schedule(delay), do: Process.send_after(self(), :run, delay)

  @lock_key "phoenix_kit_web_analytics:retention"

  defp try_lock do
    %{rows: [[locked?]]} =
      repo().query!("SELECT pg_try_advisory_lock(hashtext($1))", [@lock_key])

    locked?
  end

  defp unlock do
    repo().query!("SELECT pg_advisory_unlock(hashtext($1))", [@lock_key])
  end

  # The first day after the watermark — or, before anything was rolled up,
  # the day of the oldest event (an indexed MIN). nil when there's nothing to
  # do.
  defp first_pending_date(yesterday) do
    with {:ok, watermark} <- rolled_through() do
      first =
        case watermark do
          nil -> oldest_event_date()
          date -> Date.add(date, 1)
        end

      if first && Date.compare(first, yesterday) != :gt, do: {:ok, first}, else: {:ok, nil}
    end
  end

  defp oldest_event_date do
    case Event |> select([e], min(e.inserted_at)) |> repo().one() do
      nil -> nil
      %DateTime{} = at -> DateTime.to_date(at)
      %NaiveDateTime{} = at -> NaiveDateTime.to_date(at)
    end
  end

  defp roll_forward(dates) do
    Enum.reduce_while(dates, 0, fn date, count ->
      with :ok <- rollup_day(date), :ok <- advance_watermark(date) do
        {:cont, if(day_has_rows?(date), do: count + 1, else: count)}
      else
        _ -> {:halt, count}
      end
    end)
  end

  # Re-roll the recent completed days this pass didn't just roll, while
  # they're still settling.
  defp reroll_recent(yesterday, first_new, now) do
    Date.add(yesterday, 1 - @reroll_days)
    |> Date.range(yesterday)
    |> Enum.reject(&(first_new && Date.compare(&1, first_new) != :lt))
    |> Enum.filter(&settling?(&1, now))
    # Every such day, rows or not: a day that was empty when first rolled up
    # can have received a late hit since.
    |> Enum.each(&rollup_day/1)
  end

  defp settling?(date, now) do
    day_end = DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")
    DateTime.diff(now, day_end) < @settle_seconds
  end

  defp day_has_rows?(date) do
    from(s in DailyStat, where: s.date == ^date, select: 1, limit: 1)
    |> repo().one()
    |> Kernel.==(1)
  end

  defp advance_watermark(date) do
    case Settings.update_setting_with_module(
           @watermark_key,
           Date.to_iso8601(date),
           Config.module_key()
         ) do
      {:ok, _} -> :ok
      error -> {:error, error}
    end
  end

  defp day_sessions(day) do
    per_session = SessionStats.per_session(day, by_site: true)

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

  defp upsert_or_rollback(row) do
    case upsert_daily_stat(row) do
      {:ok, _} -> :ok
      {:error, changeset} -> repo().rollback(changeset)
    end
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
           :exits,
           :engaged_ms_sum,
           :engaged_count,
           :scroll_sum,
           :scroll_count,
           :duration_ms_sum,
           :duration_count,
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
    # retention window silently destroys history instead of compacting it. An
    # unreadable watermark means "don't know", which means "don't delete".
    case rolled_through() do
      {:ok, %Date{} = date} ->
        cutoff
        |> min_datetime(DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC"))
        |> delete_batches(0, 0)

      _ ->
        0
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
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning(
        "[WebAnalytics] prune stopped after #{deleted} row(s): #{Exception.message(error)}"
      )

      deleted
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp to_number(nil), do: 0
  defp to_number(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp to_number(value) when is_number(value), do: value

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
