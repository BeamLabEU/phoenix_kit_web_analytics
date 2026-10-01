defmodule PhoenixKitWebAnalytics.BotSignals do
  @moduledoc """
  Spotting automated visitors by what they do, not only by what they call
  themselves.

  The User-Agent check (`PhoenixKitWebAnalytics.UserAgent.bot?/1`) catches
  every bot that announces itself. These signals catch the ones that send a
  normal browser's User-Agent:

    * **Automation flag** — the client script reports `navigator.webdriver`,
      which Selenium, Puppeteer and Playwright set. Needs the client script.
    * **Speed** — more than 30 page views a minute from one visitor (by
      default; `config :phoenix_kit_web_analytics, bot_pageviews_per_minute:`); a
      person can't read pages that fast.
    * **No JavaScript** — a LiveView page whose live connection never came:
      no exit, click, live navigation or client-script report from that
      visitor all day. A browser connects within a second; a scraper that
      only fetches HTML never does. Only pages that run
      `PhoenixKitWebAnalytics.LiveHook` count — elsewhere a missing
      connection proves nothing.

  A visit flagged this way has its events marked `is_bot` with the reason in
  `metadata["bot"]` (`"webdriver"`, `"rate"`, `"no_js"`), so every report
  drops it like any declared bot, and later hits of the visit inherit the
  flag (dropped, while bot traffic isn't kept). A `"no_js"` verdict can be
  wrong, so its later hits are always kept, flagged, and the flag undoes
  itself if the visit shows it ran JavaScript after all (a tab left open
  without a click until its exit).

  On by default; `web_analytics_detect_bots` switches all three off.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Visitor

  @table :phoenix_kit_web_analytics_bot_signals
  @sweep_ms 60_000
  @default_pageviews_per_minute 30
  # A browser's live connection comes within a second; a visit is judged
  # once it has had this long.
  @judge_after_minutes 30
  # Two hours of visit starts per hourly pass: each visit is seen at least
  # once even when a pass runs late.
  @window_hours 2
  @batch 2_000

  # Reports that only a browser running JavaScript sends.
  @js_sources ["live_presence", "live_navigation", "client_script"]

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The sources whose reports prove a visitor ran JavaScript."
  @spec js_sources() :: [String.t()]
  def js_sources, do: @js_sources

  @doc """
  Whether an event proves its visitor ran JavaScript: any interaction, or a
  report from a live connection or the client script.
  """
  @spec js_evidence?(map()) :: boolean()
  def js_evidence?(%{event_type: "interaction"}), do: true
  def js_evidence?(%{metadata: %{"source" => source}}) when source in @js_sources, do: true
  def js_evidence?(_event), do: false

  # ── speed ─────────────────────────────────────────────────────────────────

  @doc """
  Counts a page view for `visitor_id` in the current minute. Returns
  `:ok`, `:crossed` the moment the visitor goes over the limit, and `:over`
  for every page view after that minute's crossing.
  """
  @spec count_pageview(String.t()) :: :ok | :crossed | :over
  def count_pageview(visitor_id) do
    count = count(:pageview, visitor_id)
    limit = pageviews_per_minute()

    cond do
      count <= limit -> :ok
      count == limit + 1 -> :crossed
      true -> :over
    end
  end

  @doc """
  Counts one `kind` of report from `visitor_id` in the current minute and
  returns the count so far (`0` when the counters aren't running). The
  per-visitor speed limits — page views, recording chunks — share it.
  """
  @spec count(atom(), String.t()) :: non_neg_integer()
  def count(kind, visitor_id) do
    key = {:rate, {kind, visitor_id}, minute()}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  rescue
    ArgumentError -> 0
  end

  defp minute, do: div(System.system_time(:second), 60)

  defp pageviews_per_minute,
    do:
      Application.get_env(
        :phoenix_kit_web_analytics,
        :bot_pageviews_per_minute,
        @default_pageviews_per_minute
      )

  # ── flagging ──────────────────────────────────────────────────────────────

  @doc """
  Marks every event of `session_id` as a bot's, with `reason`. Returns the
  number of events marked.
  """
  @spec flag_session(Ecto.UUID.t(), String.t()) :: non_neg_integer()
  def flag_session(session_id, reason) do
    {count, _} = flag(from(e in Event, where: e.session_id == ^session_id), reason)
    count
  end

  @doc """
  Marks today's events of the visitor behind `client` as a bot's — the
  client script's automation report. Runs off the caller's process.
  """
  @spec flag_client(map(), String.t()) :: :ok
  def flag_client(client, reason) do
    Collector.run_async(fn ->
      with salt when is_binary(salt) <- Config.hash_salt() do
        visitor_id = Visitor.visitor_id(client[:ip], client[:user_agent], salt)
        today = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")

        flag(
          from(e in Event, where: e.visitor_id == ^visitor_id and e.inserted_at >= ^today),
          reason
        )
      end
    end)
  end

  @doc """
  Clears a `"no_js"` flag from a session that has since shown it ran
  JavaScript. Other reasons stay.
  """
  @spec clear_no_js(Ecto.UUID.t()) :: non_neg_integer()
  def clear_no_js(session_id) do
    {count, _} =
      from(e in Event,
        where: e.session_id == ^session_id and fragment("?->>'bot' = 'no_js'", e.metadata),
        update: [
          set: [is_bot: false, metadata: fragment("? - 'bot'", e.metadata)]
        ]
      )
      |> repo().update_all([])

    count
  end

  # The reason goes in metadata, so a flagged visit says why it was.
  defp flag(query, reason) do
    query
    |> update([e],
      set: [
        is_bot: true,
        metadata:
          fragment(
            "COALESCE(?, '{}'::jsonb) || jsonb_build_object('bot', ?::text)",
            e.metadata,
            ^reason
          )
      ]
    )
    |> repo().update_all([])
  end

  # ── no JavaScript ─────────────────────────────────────────────────────────

  @doc """
  Judges the visits that started in the #{@window_hours} hours before the
  last #{@judge_after_minutes} minutes (time enough to connect): a visit
  that loaded a LiveView page running the hook, by a visitor with no
  JavaScript report all day, is flagged `"no_js"`. Run by every retention
  pass. Returns the number of visits flagged.

  Stateless on purpose: the window overlaps the previous pass's, and judging
  a visit twice gives the same answer (a flagged one is skipped, one with
  JavaScript stays clear) — so no watermark is written, which would add an
  activity-log entry every hour. Pages through the window in batches
  (`:batch`, #{@batch} by default), so a busy hour is judged whole.
  """
  @spec judge_no_js(DateTime.t(), keyword()) :: non_neg_integer()
  def judge_no_js(now \\ DateTime.utc_now(), opts \\ []) do
    if detect?() do
      to = DateTime.add(now, -@judge_after_minutes * 60, :second)
      from = DateTime.add(to, -@window_hours * 3600, :second)
      judge_batches(from, to, nil, Keyword.get(opts, :batch, @batch), 0)
    else
      0
    end
  rescue
    error ->
      Logger.warning("[WebAnalytics] bot judgement failed: #{Exception.message(error)}")
      0
  end

  # Keyset paging over visit starts, oldest first; each batch flagged in one
  # statement.
  defp judge_batches(from, to, after_key, batch, flagged) do
    rows = no_js_starts(from, to, after_key, batch)
    ids = Enum.map(rows, &elem(&1, 1))

    if ids != [] do
      flag(from(e in Event, where: e.session_id in ^ids), "no_js")
    end

    flagged = flagged + length(ids)

    if length(rows) < batch,
      do: flagged,
      else: judge_batches(from, to, List.last(rows), batch, flagged)
  end

  defp no_js_starts(from, to, after_key, batch) do
    from(s in Event,
      as: :start,
      where: s.session_start and s.inserted_at >= ^from and s.inserted_at < ^to,
      where: not s.is_bot,
      where: exists(hooked_page_view()),
      where: not exists(js_report_that_day()),
      order_by: [asc: s.inserted_at, asc: s.session_id],
      limit: ^batch,
      select: {s.inserted_at, s.session_id}
    )
    |> after_start(after_key)
    |> repo().all()
  end

  defp after_start(query, nil), do: query

  defp after_start(query, {at, session_id}) do
    where(
      query,
      [s],
      s.inserted_at > ^at or (s.inserted_at == ^at and s.session_id > ^session_id)
    )
  end

  # The visit loaded a page whose LiveView runs the hook.
  defp hooked_page_view do
    from(p in Event,
      where: p.session_id == parent_as(:start).session_id,
      where: p.event_type == "pageview" and fragment("?->>'lv' = 'true'", p.metadata)
    )
  end

  # Anything only JavaScript sends, from the same visitor. The visitor ID is
  # already one day's (the hash includes the date), so no time bounds: a
  # visit that crosses midnight keeps its ID, and its exit after midnight
  # still counts.
  defp js_report_that_day do
    from(h in Event,
      where: h.visitor_id == parent_as(:start).visitor_id,
      where:
        h.event_type == "interaction" or
          fragment("?->>'source' = ANY(?)", h.metadata, type(^@js_sources, {:array, :string}))
    )
  end

  @doc "Whether behavioural bot detection is on (`web_analytics_detect_bots`)."
  @spec detect?() :: boolean()
  def detect?, do: Config.collection_config().detect_bots?

  # ── server ────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    current = minute()
    :ets.select_delete(@table, [{{{:rate, :_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("[WebAnalytics] BotSignals ignored #{inspect(message)}")
    {:noreply, state}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
