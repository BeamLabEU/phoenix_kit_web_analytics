defmodule PhoenixKitWebAnalytics.ReportCache do
  @moduledoc """
  A short-lived cache for report results, so a busy site's admin pages don't
  re-run the same aggregates for every viewer and every refresh.

  Finished days come from rollups and are cheap; what costs is the slice of
  raw events not rolled up yet (today). Caching a report for a few seconds
  means that slice is aggregated at most once per interval per filter, however
  many admins have the Overview open.

  One computation per key at a time: when a report expires, the first caller
  recomputes it while everyone else gets the previous result (or, when there
  is none yet, waits for the one being computed) — so a restart or a dozen
  dashboards refreshing together cost one query, not a dozen.

  30 seconds by default (`config :phoenix_kit_web_analytics, report_cache_ms:
  ms`); `0` turns it off (the test suite does). The table belongs to this
  process; without it running, `fetch/3` just computes.
  """

  use GenServer

  require Logger

  @table :phoenix_kit_web_analytics_report_cache
  @sweep_ms 60_000
  # How long an expired result may still be served while it's recomputed.
  @stale_ms 300_000
  @wait_step_ms 20
  @wait_max_ms 30_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The cached value for `key`, or `fun.()` computed and stored for `ttl_ms`
  (the configured interval by default).
  """
  @spec fetch(term(), (-> value), non_neg_integer() | nil) :: value when value: term()
  def fetch(key, fun, ttl_ms \\ nil) do
    case ttl_ms || default_ttl() do
      ttl when ttl > 0 ->
        fetch_cached(key, fun, ttl, System.monotonic_time(:millisecond) + @wait_max_ms)

      _ ->
        fun.()
    end
  end

  @doc "Drops every cached report (after a settings change or a rollup)."
  @spec clear() :: :ok
  def clear do
    :ets.match_delete(@table, {{:value, :_}, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{{:value, :_}, :_, :"$1"}, [{:<, :"$1", now - @stale_ms}], [true]}
    ])

    # Claims left by a process that died mid-computation.
    for [key, pid] <- :ets.match(@table, {{:computing, :"$1"}, :"$2"}), not Process.alive?(pid) do
      :ets.delete_object(@table, {{:computing, key}, pid})
    end

    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("[WebAnalytics] ReportCache ignored #{inspect(message)}")
    {:noreply, state}
  end

  defp fetch_cached(key, fun, ttl, deadline) do
    now = System.monotonic_time(:millisecond)

    case lookup(key, now) do
      {:fresh, value} ->
        value

      {:stale, value} ->
        # Someone else is already recomputing: the previous result will do.
        if claim(key), do: compute(key, fun, ttl), else: value

      :miss ->
        cond do
          claim(key) -> compute(key, fun, ttl)
          # No table, or waited long enough: compute without the cache.
          not table?() or now > deadline -> fun.()
          true -> wait(key, fun, ttl, deadline)
        end
    end
  end

  defp wait(key, fun, ttl, deadline) do
    Process.sleep(@wait_step_ms)
    fetch_cached(key, fun, ttl, deadline)
  end

  defp compute(key, fun, ttl) do
    value = fun.()
    store(key, value, System.monotonic_time(:millisecond) + ttl)
    value
  after
    release(key)
  end

  defp lookup(key, now) do
    case :ets.lookup(@table, {:value, key}) do
      [{_, value, expires}] when expires > now -> {:fresh, value}
      [{_, value, _expires}] -> {:stale, value}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  # The claim to compute `key`. One left by a process that died
  # mid-computation (a closed tab's LiveView) is taken over, so neither the
  # waiters nor the stale-value readers are stuck behind it.
  defp claim(key) do
    :ets.insert_new(@table, {{:computing, key}, self()}) or take_over_dead_claim(key)
  rescue
    ArgumentError -> false
  end

  defp take_over_dead_claim(key) do
    case :ets.lookup(@table, {:computing, key}) do
      [{_, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          false
        else
          :ets.delete_object(@table, {{:computing, key}, pid})
          :ets.insert_new(@table, {{:computing, key}, self()})
        end

      _ ->
        :ets.insert_new(@table, {{:computing, key}, self()})
    end
  end

  defp release(key) do
    :ets.delete_object(@table, {{:computing, key}, self()})
  rescue
    ArgumentError -> :ok
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  defp store(key, value, expires) do
    :ets.insert(@table, {{:value, key}, value, expires})
  rescue
    ArgumentError -> :ok
  end

  defp default_ttl,
    do: Application.get_env(:phoenix_kit_web_analytics, :report_cache_ms, 30_000)
end
