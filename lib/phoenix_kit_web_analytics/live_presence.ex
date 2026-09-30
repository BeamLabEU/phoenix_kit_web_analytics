defmodule PhoenixKitWebAnalytics.LivePresence do
  @moduledoc """
  Who is on the site right now, and when they leave — from the LiveView
  processes themselves, with no client-side script.

  A connected LiveView is a server process that lives exactly as long as the
  visitor has the page open. `PhoenixKitWebAnalytics.LiveHook` registers each
  one here; this server monitors it and keeps one row per open page in an ETS
  table:

    * **Right now** — `list/1` and `count/1` read the table directly, so the
      "on the site now" view is precise to the second rather than the usual
      "anyone with a hit in the last five minutes" approximation.
    * **Leaving** — when the process goes down (tab closed, navigated to
      another LiveView or a non-LiveView page, network dropped) the monitor
      fires and a `"leave"` event is recorded with the time spent on the page.
      A `push_patch` inside the same LiveView records a leave for the old URL
      too, via `navigate/2`.

  ## What "time on page" means here

  Wall-clock time from the page being shown to the process ending. A page left
  open in a background tab counts until the tab is closed or the socket is
  dropped — browsers throttle and eventually disconnect idle background tabs,
  which bounds it. `max_engaged_ms/0` caps a single reading so one tab
  forgotten over a weekend can't skew an average.

  ## Scope

  The table is per node. On a multi-node deployment each node reports the
  pages open on it; `list/1` does not gather across the cluster.
  """

  use GenServer

  require Logger

  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.UserAgent

  @table :phoenix_kit_web_analytics_live_presence
  # Four hours: longer than any real reading session, short enough that a tab
  # abandoned overnight doesn't turn "average time on page" into nonsense.
  @max_engaged_ms 4 * 60 * 60 * 1000

  @typedoc "One open page."
  @type visit :: %{
          pid: pid(),
          path: String.t(),
          site: String.t() | nil,
          since: DateTime.t(),
          user_uuid: String.t() | nil,
          browser: String.t() | nil,
          os: String.t() | nil,
          device_type: String.t() | nil,
          referrer: String.t() | nil
        }

  # ── client API ────────────────────────────────────────────────────────────

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Starts watching a LiveView process that is showing `path`.

  `client` carries the visitor's IP / User-Agent / language (used only to hash
  the visitor for the leave event, exactly as for the page view — never
  stored), and `attrs` the display fields for the live list. A no-op when the
  server isn't running.
  """
  @spec watch(pid(), map(), map()) :: :ok
  def watch(pid, client, attrs) when is_pid(pid) and is_map(client) and is_map(attrs) do
    cast({:watch, pid, client, attrs, DateTime.utc_now()})
  end

  @doc """
  Records that a watched LiveView moved to a new URL without a remount
  (`push_patch` / `<.link patch>`): a leave for the old path, and the clock
  restarts for the new one.
  """
  @spec navigate(pid(), String.t()) :: :ok
  def navigate(pid, path) when is_pid(pid) and is_binary(path) do
    cast({:navigate, pid, path, DateTime.utc_now()})
  end

  @doc """
  Pages open right now, newest first. `site` restricts to one host.
  """
  @spec list(String.t() | nil) :: [visit()]
  def list(site \\ nil) do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_pid, visit} -> visit end)
    |> filter_site(site)
    |> Enum.sort_by(& &1.since, {:desc, DateTime})
  rescue
    ArgumentError -> []
  end

  @doc "How many pages are open right now."
  @spec count(String.t() | nil) :: non_neg_integer()
  def count(nil) do
    # `:ets.info/2` answers :undefined (it doesn't raise) when the table is
    # gone — the server not running on this node.
    case :ets.info(@table, :size) do
      size when is_integer(size) -> size
      _ -> 0
    end
  end

  def count(site), do: site |> list() |> length()

  @doc "Whether the presence server is running on this node."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @doc "The cap applied to one time-on-page reading, in milliseconds."
  @spec max_engaged_ms() :: pos_integer()
  def max_engaged_ms, do: @max_engaged_ms

  # ── server ────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{table: table, clients: %{}}}
  end

  @impl GenServer
  def handle_cast({:watch, pid, client, attrs, now}, state) do
    if :ets.member(@table, pid) do
      {:noreply, state}
    else
      Process.monitor(pid)
      :ets.insert(@table, {pid, build_visit(pid, client, attrs, now)})
      {:noreply, put_in(state.clients[pid], client)}
    end
  end

  def handle_cast({:navigate, pid, path, now}, state) do
    case :ets.lookup(@table, pid) do
      [{^pid, %{path: ^path}}] ->
        {:noreply, state}

      [{^pid, visit}] ->
        record_leave(visit, state.clients[pid], now)
        :ets.insert(@table, {pid, %{visit | path: path, since: now}})
        {:noreply, state}

      [] ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case :ets.lookup(@table, pid) do
      [{^pid, visit}] ->
        record_leave(visit, state.clients[pid], DateTime.utc_now())
        :ets.delete(@table, pid)

      [] ->
        :ok
    end

    {:noreply, %{state | clients: Map.delete(state.clients, pid)}}
  end

  def handle_info(message, state) do
    Logger.debug("[WebAnalytics] LivePresence ignored #{inspect(message)}")
    {:noreply, state}
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp cast(message) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      server -> GenServer.cast(server, message)
    end
  end

  defp build_visit(pid, client, attrs, now) do
    ua = UserAgent.parse(client[:user_agent])

    %{
      pid: pid,
      path: attrs[:path] || "/",
      site: attrs[:site],
      since: now,
      user_uuid: attrs[:user_uuid],
      browser: ua.browser,
      os: ua.os,
      device_type: ua.device_type,
      referrer: attrs[:referrer]
    }
  end

  defp record_leave(_visit, nil, _now), do: :ok

  defp record_leave(visit, client, now) do
    engaged_ms = now |> DateTime.diff(visit.since, :millisecond) |> min(@max_engaged_ms)

    Collector.track_async(%{
      event_type: "leave",
      path: visit.path,
      site: visit.site,
      ip: client[:ip],
      user_agent: client[:user_agent],
      language: client[:language],
      user_uuid: visit.user_uuid,
      engaged_ms: max(engaged_ms, 0),
      # The leave belongs to the session the page view opened, even when the
      # page was open longer than the inactivity window.
      session_anchor: visit.since,
      inserted_at: now,
      metadata: %{"source" => "live_presence"}
    })
  end

  defp filter_site(visits, nil), do: visits
  defp filter_site(visits, site), do: Enum.filter(visits, &(&1.site == site))
end
