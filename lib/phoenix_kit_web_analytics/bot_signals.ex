defmodule PhoenixKitWebAnalytics.BotSignals do
  @moduledoc """
  Spotting automated visitors by what they do, not only by what they call
  themselves.

  The User-Agent check (`PhoenixKitWebAnalytics.UserAgent.bot?/1`) catches
  every bot that announces itself. These signals catch the ones that send a
  normal browser's User-Agent:

    * **Automation flag** — the client script reports `navigator.webdriver`,
      which Selenium, Puppeteer and Playwright set. Needs the client script.
    * **Speed** — more than #{30} page views a minute from one visitor; a
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
  flag. A `"no_js"` flag undoes itself if the visit later shows it ran
  JavaScript after all (a tab left open without a click until its exit).

  On by default; `web_analytics_detect_bots` switches all three off.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Visitor

  @table :phoenix_kit_web_analytics_bot_signals
  @sweep_ms 60_000
  @default_pageviews_per_minute 30
  @watermark_key "web_analytics_bot_sweep_through"
  # A browser's live connection comes within a second; a visit is judged
  # once it has had this long.
  @judge_after_minutes 30
  @max_window_hours 6
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
    key = {:rate, visitor_id, minute()}
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    limit = pageviews_per_minute()

    cond do
      count <= limit -> :ok
      count == limit + 1 -> :crossed
      true -> :over
    end
  rescue
    ArgumentError -> :ok
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
  Judges the visits that started since the last pass and have had
  #{@judge_after_minutes} minutes to connect: a visit that loaded a LiveView
  page running the hook, by a visitor with no JavaScript report all day, is
  flagged `"no_js"`. Run by the retention pass. Returns the number of visits
  flagged.
  """
  @spec judge_no_js(DateTime.t()) :: non_neg_integer()
  def judge_no_js(now \\ DateTime.utc_now()) do
    if detect?() do
      to = DateTime.add(now, -@judge_after_minutes * 60, :second)
      from = watermark() || DateTime.add(to, -@max_window_hours * 3600, :second)
      from = Enum.max([from, DateTime.add(to, -@max_window_hours * 3600, :second)], DateTime)

      if DateTime.compare(from, to) == :lt do
        flagged = flag_no_js_between(from, to)
        save_watermark(to)
        flagged
      else
        0
      end
    else
      0
    end
  rescue
    error ->
      Logger.warning("[WebAnalytics] bot judgement failed: #{Exception.message(error)}")
      0
  end

  defp flag_no_js_between(from, to) do
    sessions =
      from(s in Event,
        as: :start,
        where: s.session_start and s.inserted_at >= ^from and s.inserted_at < ^to,
        where: not s.is_bot,
        where: exists(hooked_page_view()),
        where: not exists(js_report_that_day()),
        limit: @batch,
        select: s.session_id
      )
      |> repo().all()

    Enum.each(sessions, &flag_session(&1, "no_js"))
    length(sessions)
  end

  # The visit loaded a page whose LiveView runs the hook.
  defp hooked_page_view do
    from(p in Event,
      where: p.session_id == parent_as(:start).session_id,
      where: p.event_type == "pageview" and fragment("?->>'lv' = 'true'", p.metadata)
    )
  end

  # Anything only JavaScript sends, from the same visitor the same day.
  defp js_report_that_day do
    from(h in Event,
      where: h.visitor_id == parent_as(:start).visitor_id,
      where: h.inserted_at >= fragment("date_trunc('day', ?)", parent_as(:start).inserted_at),
      where:
        h.inserted_at <
          fragment("date_trunc('day', ?) + interval '1 day'", parent_as(:start).inserted_at),
      where:
        h.event_type == "interaction" or
          fragment("?->>'source' = ANY(?)", h.metadata, type(^@js_sources, {:array, :string}))
    )
  end

  defp watermark do
    case Settings.get_setting(@watermark_key, nil) do
      nil ->
        nil

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, at, _} -> at
          _ -> nil
        end
    end
  end

  defp save_watermark(at) do
    Settings.update_setting_with_module(
      @watermark_key,
      DateTime.to_iso8601(at),
      Config.module_key()
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
