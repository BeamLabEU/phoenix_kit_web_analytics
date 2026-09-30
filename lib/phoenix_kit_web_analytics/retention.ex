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

  The two most recent completed days are re-rolled on every pass. A hit that
  was being written as midnight passed lands in "yesterday" after that day's
  first rollup; re-rolling picks it up, and the upsert makes it idempotent.

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
  alias PhoenixKitWebAnalytics.Schemas.DailyStat
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.SessionStats

  @interval_ms :timer.hours(1)
  @boot_delay_ms :timer.minutes(2)
  @max_days_per_run 60
  @delete_batch 5_000
  @max_delete_batches 200
  @reroll_days 2
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
  @spec rollup_pending_days() :: non_neg_integer()
  def rollup_pending_days do
    yesterday = Date.add(Date.utc_today(), -1)

    case first_pending_date(yesterday) do
      {:ok, nil} ->
        reroll_recent(yesterday, nil)
        0

      {:ok, first} ->
        last = Enum.min([Date.add(first, @max_days_per_run - 1), yesterday], Date)
        count = roll_forward(Date.range(first, last))
        reroll_recent(yesterday, first)
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

    totals = day_totals(from, to)
    sessions = day_sessions(from, to)

    rows =
      Enum.map(totals, fn {site, counts} ->
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

    # One transaction per day: a site whose row fails must not leave the day
    # looking rolled up while its raw rows become eligible for pruning.
    result =
      repo().transaction(fn ->
        Enum.each(rows, fn row ->
          case upsert_daily_stat(row) do
            {:ok, _} -> :ok
            {:error, changeset} -> repo().rollback(changeset)
          end
        end)
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

  # Re-roll the most recent completed days that this pass didn't just roll.
  defp reroll_recent(yesterday, first_new) do
    Date.add(yesterday, 1 - @reroll_days)
    |> Date.range(yesterday)
    |> Enum.reject(&(first_new && Date.compare(&1, first_new) != :lt))
    |> Enum.each(fn date -> if day_has_rows?(date), do: rollup_day(date) end)
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

  defp day_totals(from, to) do
    from(e in Event,
      where: e.inserted_at >= ^from and e.inserted_at < ^to,
      group_by: fragment("COALESCE(?, '')", e.site),
      select: %{
        site: fragment("COALESCE(?, '')", e.site),
        pageviews: fragment("COUNT(*) FILTER (WHERE ? = 'pageview')", e.event_type),
        events: fragment("COUNT(*) FILTER (WHERE ? = 'event')", e.event_type),
        visitors:
          fragment("COUNT(DISTINCT ?) FILTER (WHERE ? = 'pageview')", e.visitor_id, e.event_type)
      }
    )
    |> repo().all()
    |> Map.new(fn row -> {row.site, row} end)
  end

  defp day_sessions(from, to) do
    per_session =
      from(e in Event, where: e.inserted_at >= ^from and e.inserted_at < ^to)
      |> SessionStats.per_session(by_site: true)

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
