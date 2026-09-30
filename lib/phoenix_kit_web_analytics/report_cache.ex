defmodule PhoenixKitWebAnalytics.ReportCache do
  @moduledoc """
  A short-lived cache for report results, so a busy site's admin pages don't
  re-run the same aggregates for every viewer and every refresh.

  Finished days come from rollups and are cheap; what costs is the slice of
  raw events not rolled up yet (today). Caching a report for a few seconds
  means that slice is aggregated at most once per interval per filter, however
  many admins have the Overview open.

  30 seconds by default (`config :phoenix_kit_web_analytics, report_cache_ms:
  ms`); `0` turns it off (the test suite does). The table belongs to this
  process; without it running, `fetch/3` just computes.
  """

  use GenServer

  require Logger

  @table :phoenix_kit_web_analytics_report_cache
  @sweep_ms 60_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The cached value for `key`, or `fun.()` computed and stored for `ttl_ms`
  (the configured interval by default).
  """
  @spec fetch(term(), (-> value), non_neg_integer() | nil) :: value when value: term()
  def fetch(key, fun, ttl_ms \\ nil) do
    ttl = ttl_ms || default_ttl()
    now = System.monotonic_time(:millisecond)

    case ttl > 0 && lookup(key, now) do
      {:ok, value} ->
        value

      _ ->
        value = fun.()
        if ttl > 0, do: store(key, value, now + ttl)
        value
    end
  end

  @doc "Drops every cached report (after a settings change or a rollup)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
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
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("[WebAnalytics] ReportCache ignored #{inspect(message)}")
    {:noreply, state}
  end

  defp lookup(key, now) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires}] when expires > now -> {:ok, value}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp store(key, value, expires) do
    :ets.insert(@table, {key, value, expires})
  rescue
    ArgumentError -> :ok
  end

  defp default_ttl,
    do: Application.get_env(:phoenix_kit_web_analytics, :report_cache_ms, 30_000)
end
