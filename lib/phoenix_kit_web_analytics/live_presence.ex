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

  ## Reconnects are not exits

  A LiveView process also ends when the connection drops for a moment (a
  deploy, a flaky network) and the client rejoins with a new process. So a
  leave is held for a short grace period (10 s by default,
  `config :phoenix_kit_web_analytics, presence_reconnect_grace_ms: ms`); if the
  same visitor rejoins the same page within it, the page continues — one
  view, one leave, time counted from the original start.

  The rejoin can also come first: on a reload Firefox opens the new page's
  connection before closing the old one, which can linger for seconds. So a
  page that opens while the same visitor already has the same page open takes
  that view over, and the older one is hidden for up to 30 s
  (`presence_supersede_ms`). If the older one goes down in that time it was a
  reload — one view, one leave, as above. If it is still open after that, it
  is a real second tab and is shown again.

  ## The site's own people

  Each open page carries its `PhoenixKitWebAnalytics.TrafficFlags`, worked
  out by the hook as for a hit. The readers take a `mask` and leave out
  pages with any of its bits — "Right now" passes the bits the statistics
  leave out. Counts per path keep the flagged pages apart, so leaving them
  out stays as cheap as counting everything.

  ## Scope

  The table is per node. On a multi-node deployment each node reports the
  pages open on it; `list/1` does not gather across the cluster.
  """

  use GenServer

  require Logger

  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.UserAgent

  @table :phoenix_kit_web_analytics_live_presence
  # Newest first: keys are {-since_in_microseconds, pid}, so an ordered walk
  # from the start is "most recently opened" without sorting anything.
  @index :phoenix_kit_web_analytics_live_presence_index
  # {path, open page count} — the "by page" view without scanning every page.
  @paths :phoenix_kit_web_analytics_live_presence_paths
  # {{path, flags}, open page count} for flagged pages only — few, so a
  # reader leaving them out subtracts them from @paths.
  @flagged :phoenix_kit_web_analytics_live_presence_flagged
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
          referrer: String.t() | nil,
          flags: non_neg_integer()
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
    cast({:watch, pid, with_ua(client), attrs, DateTime.utc_now()})
  end

  # The User-Agent is parsed by the caller (the page's own process), not by
  # this one server every page waits behind.
  defp with_ua(client),
    do: Map.put_new_lazy(client, :ua, fn -> UserAgent.parse(client[:user_agent]) end)

  @doc """
  Stops watching a LiveView that patched to a page that isn't tracked (an
  excluded path): a leave for the page it was on, and it drops off the live
  list. Watching starts again if it patches back to a tracked page.
  """
  @spec unwatch(pid(), DateTime.t()) :: :ok
  def unwatch(pid, now \\ DateTime.utc_now()) when is_pid(pid), do: cast({:unwatch, pid, now})

  @doc """
  Records that a watched LiveView moved to a new URL without a remount
  (`push_patch` / `<.link patch>`): a leave for the old path, and the clock
  restarts for the new one.
  """
  @spec navigate(pid(), String.t(), map(), map()) :: :ok
  def navigate(pid, path, client \\ %{}, attrs \\ %{})
      when is_pid(pid) and is_binary(path) do
    cast({:navigate, pid, path, with_ua(client), attrs, DateTime.utc_now()})
  end

  @doc """
  One page of the open pages, newest first — for a site with thousands of
  people online, the Right now list reads `limit` rows from an ordered index
  instead of the whole table.

  Returns `{visits, next_cursor}`; pass `next_cursor` as `:after` for the
  following page (`nil` when there is none). `:mask` leaves out pages with
  any of its `TrafficFlags` bits (none by default).
  """
  @spec page(keyword()) :: {[visit()], term() | nil}
  def page(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    mask = Keyword.get(opts, :mask, 0)

    start =
      case Keyword.get(opts, :after) do
        nil -> :ets.first(@index)
        after_key -> :ets.next(@index, after_key)
      end

    {found, more?} = collect(start, mask, limit, [])
    {Enum.map(found, &elem(&1, 1)), if(more?, do: found |> List.last() |> elem(0))}
  rescue
    ArgumentError -> {[], nil}
  end

  # Walks the index newest first, keeping `limit` shown pages and looking one
  # further to tell whether there is another page.
  defp collect(:"$end_of_table", _mask, _limit, acc), do: {Enum.reverse(acc), false}

  defp collect({_since, pid} = key, mask, limit, acc) do
    case :ets.lookup(@table, pid) do
      [{^pid, visit}] ->
        cond do
          not shown?(visit, mask) -> collect(:ets.next(@index, key), mask, limit, acc)
          length(acc) >= limit -> {Enum.reverse(acc), true}
          true -> collect(:ets.next(@index, key), mask, limit, [{key, visit} | acc])
        end

      [] ->
        collect(:ets.next(@index, key), mask, limit, acc)
    end
  end

  defp shown?(visit, mask),
    do: not PhoenixKitWebAnalytics.TrafficFlags.excluded?(Map.get(visit, :flags, 0), mask)

  @doc """
  Open pages counted per path, most open first — `{path, count}` pairs,
  read from counters kept as pages open and close. `limit` caps the list;
  `mask` leaves out pages with any of its `TrafficFlags` bits.

  One pass over the counters keeping only the top `limit` — no copy or sort
  of every open path, which on a big site can be most of the open pages.
  """
  @spec by_path(pos_integer(), non_neg_integer()) :: [{String.t(), pos_integer()}]
  def by_path(limit \\ 50, mask \\ 0) do
    left_out = left_out_by_path(mask)

    keep = fn {path, count}, acc ->
      case count - Map.get(left_out, path, 0) do
        shown when shown > 0 -> keep_top({path, shown}, acc, limit)
        _none -> acc
      end
    end

    keep
    |> :ets.foldl({:gb_sets.empty(), 0}, @paths)
    |> elem(0)
    |> :gb_sets.to_list()
    |> Enum.reverse()
    |> Enum.map(fn {count, path} -> {path, count} end)
  rescue
    ArgumentError -> []
  end

  # A set ordered by {count, path}, trimmed to `limit` by dropping its
  # smallest.
  defp keep_top({path, count}, {set, size}, limit) when size < limit,
    do: {:gb_sets.add({count, path}, set), size + 1}

  defp keep_top({path, count}, {set, size}, _limit) do
    {smallest, rest} = :gb_sets.take_smallest(set)

    if {count, path} > smallest,
      do: {:gb_sets.add({count, path}, rest), size},
      else: {set, size}
  end

  # Flagged pages under `mask`, counted per path.
  defp left_out_by_path(0), do: %{}

  defp left_out_by_path(mask) do
    :ets.foldl(
      fn {{path, flags}, count}, acc ->
        if PhoenixKitWebAnalytics.TrafficFlags.excluded?(flags, mask),
          do: Map.update(acc, path, count, &(&1 + count)),
          else: acc
      end,
      %{},
      @flagged
    )
  end

  @doc """
  Pages open right now, newest first. `site` restricts to one host; `mask`
  leaves out pages with any of its `TrafficFlags` bits.

  Reads every open page — fine for a test or a small site; the admin page
  uses `page/1` and `by_path/1`, which stay cheap at any size.
  """
  @spec list(String.t() | nil, non_neg_integer()) :: [visit()]
  def list(site \\ nil, mask \\ 0) do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_pid, visit} -> visit end)
    |> filter_site(site)
    |> Enum.filter(&shown?(&1, mask))
    |> Enum.sort_by(& &1.since, {:desc, DateTime})
  rescue
    ArgumentError -> []
  end

  @doc "How many pages are open right now — leaving out `mask`'s flagged ones."
  @spec count(String.t() | nil, non_neg_integer()) :: non_neg_integer()
  def count(site, mask \\ 0)

  def count(nil, mask) do
    # `:ets.info/2` answers :undefined (it doesn't raise) when the table is
    # gone — the server not running on this node.
    case :ets.info(@table, :size) do
      size when is_integer(size) ->
        left_out = mask |> left_out_by_path() |> Map.values() |> Enum.sum()
        max(size - left_out, 0)

      _ ->
        0
    end
  rescue
    ArgumentError -> 0
  end

  def count(site, mask), do: site |> list(mask) |> length()

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
    :ets.new(@index, [:named_table, :protected, :ordered_set, read_concurrency: true])
    :ets.new(@paths, [:named_table, :protected, :set, read_concurrency: true])
    :ets.new(@flagged, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{table: table, clients: %{}, pending: %{}, by_key: %{}, shadowed: %{}}}
  end

  @impl GenServer
  def handle_cast({:watch, pid, client, attrs, now}, state) do
    if :ets.member(@table, pid) do
      {:noreply, state}
    else
      visit = build_visit(pid, client, attrs, now)

      {:noreply, join(state, pid, client, visit)}
    end
  end

  def handle_cast({:unwatch, pid, now}, state) do
    state = if Map.has_key?(state.shadowed, pid), do: restore(state, pid), else: state

    case :ets.lookup(@table, pid) do
      [{^pid, visit}] ->
        client = state.clients[pid]
        record_leave(visit, client, now)
        remove_visit(pid, visit)
        {:noreply, drop_key(state, pending_key(client, visit), pid)}

      [] ->
        {:noreply, state}
    end
  end

  def handle_cast({:navigate, pid, path, client, attrs, now}, state) do
    # A hidden page that navigates is a real tab, not a reload's leftover.
    state = if Map.has_key?(state.shadowed, pid), do: restore(state, pid), else: state

    case :ets.lookup(@table, pid) do
      [{^pid, %{path: ^path}}] ->
        {:noreply, state}

      [{^pid, visit}] ->
        client = state.clients[pid]
        moved = %{visit | path: path, since: now, flags: Map.get(attrs, :flags, visit.flags)}
        record_leave(visit, client, now)
        remove_visit(pid, visit)
        insert_visit(pid, moved)

        {:noreply,
         state
         |> drop_key(pending_key(client, visit), pid)
         |> add_key(pending_key(client, moved), pid)}

      [] ->
        # Not watched: this server restarted while the page stayed open. Start
        # watching from here rather than losing the page for good.
        # No identity to watch with (`:ua` alone is only what we parsed).
        if is_nil(client[:ip]) and is_nil(client[:user_agent]) do
          {:noreply, state}
        else
          visit = build_visit(pid, client, Map.put(attrs, :path, path), now)
          {:noreply, start_watching(state, pid, client, visit)}
        end
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # A page this one hid is still open, so it was a second tab after all:
    # shown again first, which gives this page back its own start.
    state = restore_hidden_by(state, pid)
    {client, clients} = Map.pop(state.clients, pid)
    {hidden, shadowed} = Map.pop(state.shadowed, pid)
    state = %{state | clients: clients, shadowed: shadowed}

    case {hidden, :ets.lookup(@table, pid)} do
      # A reload's old page closing: the new page already carries the view.
      {%{}, _} ->
        {:noreply, state}

      {nil, [{^pid, visit}]} ->
        remove_visit(pid, visit)
        state = drop_key(state, pending_key(client, visit), pid)
        {:noreply, hold_leave(state, visit, client, DateTime.utc_now())}

      {nil, []} ->
        {:noreply, state}
    end
  end

  def handle_info({:unshadow, pid, ref}, state) do
    case state.shadowed do
      %{^pid => %{ref: ^ref}} -> {:noreply, restore(state, pid)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:finalize_leave, key, ref}, state) do
    case Map.get(state.pending, key) do
      %{ref: ^ref, visit: visit, client: client, left_at: left_at} ->
        record_leave(visit, client, left_at)
        {:noreply, %{state | pending: Map.delete(state.pending, key)}}

      _superseded ->
        {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Logger.debug("[WebAnalytics] LivePresence ignored #{inspect(message)}")
    {:noreply, state}
  end

  defp restore_hidden_by(state, pid) do
    case Enum.find(state.shadowed, fn {_older, hidden} -> hidden.new_pid == pid end) do
      nil -> state
      {older, _hidden} -> restore(state, older)
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp cast(message) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      server -> GenServer.cast(server, message)
    end
  end

  defp join(state, pid, client, visit) do
    key = pending_key(client, visit)

    case Map.pop(state.pending, key) do
      # A rejoin of a page whose process just went down continues that view.
      {%{} = left, pending} ->
        start_watching(%{state | pending: pending}, pid, client, %{
          visit
          | since: left.visit.since
        })

      # Or the same page is still open: a reload whose old connection hasn't
      # closed yet — or a second tab, which time will tell.
      {nil, _pending} ->
        case open_with_key(state, key) do
          nil -> start_watching(state, pid, client, visit)
          older -> supersede(state, older, pid, client, visit)
        end
    end
  end

  defp start_watching(state, pid, client, visit) do
    Process.monitor(pid)
    insert_visit(pid, visit)

    state
    |> put_in([:clients, pid], client)
    |> add_key(pending_key(client, visit), pid)
  end

  # The newest open page with this visitor/site/path key, if superseding is on.
  defp open_with_key(state, key) do
    with true <- supersede_ms() > 0,
         %MapSet{} = pids <- state.by_key[key] do
      pids
      |> Enum.flat_map(&:ets.lookup(@table, &1))
      |> Enum.max_by(fn {_pid, visit} -> DateTime.to_unix(visit.since, :microsecond) end, fn ->
        nil
      end)
    else
      _ -> nil
    end
  end

  # The new page takes the older one's view (and start); the older one is
  # hidden — still monitored — until it closes or proves to be a real tab.
  defp supersede(state, {older_pid, older}, pid, client, visit) do
    remove_visit(older_pid, older)
    ref = make_ref()
    Process.send_after(self(), {:unshadow, older_pid, ref}, supersede_ms())

    hidden = %{ref: ref, visit: older, new_pid: pid, new_since: visit.since}

    state
    |> drop_key(pending_key(client, older), older_pid)
    |> put_in([:shadowed, older_pid], hidden)
    |> start_watching(pid, client, %{visit | since: older.since})
  end

  # A hidden page still open: it's a second tab. Show it again, and give the
  # newer page back its own start.
  defp restore(state, pid) do
    {hidden, shadowed} = Map.pop(state.shadowed, pid)
    state = %{state | shadowed: shadowed}
    client = state.clients[pid]
    new_pid = hidden.new_pid

    case :ets.lookup(@table, new_pid) do
      [{^new_pid, %{since: since} = newer}] when since == hidden.visit.since ->
        remove_visit(new_pid, newer)
        insert_visit(new_pid, %{newer | since: hidden.new_since})

      _ ->
        :ok
    end

    insert_visit(pid, hidden.visit)
    add_key(state, pending_key(client, hidden.visit), pid)
  end

  defp add_key(state, key, pid),
    do:
      update_in(
        state.by_key,
        &Map.update(&1, key, MapSet.new([pid]), fn s -> MapSet.put(s, pid) end)
      )

  defp drop_key(state, key, pid) do
    case state.by_key do
      %{^key => pids} ->
        rest = MapSet.delete(pids, pid)

        by_key =
          if MapSet.size(rest) == 0,
            do: Map.delete(state.by_key, key),
            else: Map.put(state.by_key, key, rest)

        %{state | by_key: by_key}

      _ ->
        state
    end
  end

  # The four tables change together, only here, in the server process.
  defp insert_visit(pid, visit) do
    :ets.insert(@table, {pid, visit})
    :ets.insert(@index, {index_key(pid, visit)})
    :ets.update_counter(@paths, visit.path, {2, 1}, {visit.path, 0})

    with key when is_tuple(key) <- flagged_key(visit),
         do: :ets.update_counter(@flagged, key, {2, 1}, {key, 0})
  end

  defp remove_visit(pid, visit) do
    :ets.delete(@table, pid)
    :ets.delete(@index, index_key(pid, visit))

    if :ets.update_counter(@paths, visit.path, {2, -1}, {visit.path, 1}) <= 0,
      do: :ets.delete(@paths, visit.path)

    with key when is_tuple(key) <- flagged_key(visit),
         true <- :ets.update_counter(@flagged, key, {2, -1}, {key, 1}) <= 0,
         do: :ets.delete(@flagged, key)
  end

  defp flagged_key(%{flags: flags, path: path}) when is_integer(flags) and flags > 0,
    do: {path, flags}

  defp flagged_key(_visit), do: nil

  defp index_key(pid, visit), do: {-DateTime.to_unix(visit.since, :microsecond), pid}

  # The leave is recorded when the grace period ends, unless the same visitor
  # rejoins the same page first. It keeps the time it actually happened.
  defp hold_leave(state, _visit, nil, _left_at), do: state

  defp hold_leave(state, visit, client, left_at) do
    key = pending_key(client, visit)
    ref = make_ref()
    Process.send_after(self(), {:finalize_leave, key, ref}, reconnect_grace_ms())

    entry = %{ref: ref, visit: visit, client: client, left_at: left_at}
    put_in(state.pending[key], entry)
  end

  defp pending_key(client, visit), do: {client[:ip], client[:user_agent], visit.site, visit.path}

  defp supersede_ms,
    do: Application.get_env(:phoenix_kit_web_analytics, :presence_supersede_ms, 30_000)

  defp reconnect_grace_ms,
    do: Application.get_env(:phoenix_kit_web_analytics, :presence_reconnect_grace_ms, 10_000)

  defp build_visit(pid, client, attrs, now) do
    ua = client[:ua] || UserAgent.parse(client[:user_agent])

    %{
      pid: pid,
      path: attrs[:path] || "/",
      site: attrs[:site],
      since: now,
      user_uuid: attrs[:user_uuid],
      browser: ua.browser,
      os: ua.os,
      device_type: ua.device_type,
      referrer: attrs[:referrer],
      flags: attrs[:flags] || 0
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
