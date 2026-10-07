defmodule PhoenixKitWebAnalytics.Collector do
  @moduledoc """
  The write path: takes a raw hit, enriches it, and stores one
  `PhoenixKitWebAnalytics.Schemas.Event`.

  ## A hit never costs the request anything

  `track_async/1` hands the work to a `Task.Supervisor` and returns
  immediately, so the enrichment (a settings read, one session-stitching query,
  the insert) happens after the response is on its way out. The request process
  spends microseconds building a map.

  The task supervisor is started with a `max_children` cap (20 by default,
  `config :phoenix_kit_web_analytics, max_concurrent_writes: n`). Under a
  flood, once the cap is reached, further hits are **dropped** rather than
  queued — an analytics backlog must not become the reason a host runs out of
  database connections. Drops are logged at debug level. With no supervisor
  running at all (a host that didn't start the module's children) hits are
  dropped too, with one warning, rather than spawned without a cap.

  In tests, `config :phoenix_kit_web_analytics, async_tracking: false` makes
  `track_async/1` write inline in the caller, so the write happens on the
  test's sandbox connection and can be asserted on.

  ## Sessions

  A hit joins the visitor's most recent session on the same site when that
  session saw activity within the inactivity window; otherwise it starts a
  new one. The lookup and the insert run in one transaction under an advisory
  lock on the visitor, so two hits arriving together (a page and its
  prefetch, a double-click) can't both decide to start a session.

  Before any of that, a hit takes one of #{3} slots for its visitor on this
  node, and is dropped when they're all taken. One "visitor" can be a whole
  office behind one address or a crawler: without the cap its hits would
  queue on the advisory lock, each holding a database connection while it
  waits, until the pool is theirs.

  ## Traffic flags

  A hit's `PhoenixKitWebAnalytics.TrafficFlags` — the site's own people and
  their networks — are worked out before the transaction, from memory only
  (`PhoenixKitWebAnalytics.InternalTraffic`). Inside it, the hit also takes
  every bit its session already has, so a visit is flagged whole going
  forward; and when a bit first appears in a visit (an anonymous visitor
  signs in as an admin), the visit's earlier hits get it too, in the same
  transaction and under the same lock.

  ## Raw hit shape

  Every key is optional except `:path`:

      %{
        event_type: "pageview" | "event",   # default "pageview"
        event_name: "signup",               # required for "event"
        path: "/pricing",
        page_title: "Pricing",
        site: "myapp.com",
        referrer: "https://news.ycombinator.com/",
        query_params: %{"utm_source" => "hn"},
        ip: {127, 0, 0, 1},
        user_agent: "Mozilla/5.0 …",
        language: "en-US",
        user_uuid: "018e…",
        roles: ["Admin"],                   # the user's held roles (a scope)
        status: 200,
        duration_ms: 12,                    # server render time (page views)
        engaged_ms: 45_000,                 # time on page ("leave")
        scroll_depth: 80,                   # 0–100 ("leave", client script)
        target: "https://example.com/x",    # what was clicked ("interaction")
        session_anchor: ~U[…],              # when the hit's page was opened
        location: %{country_code: "EE"},     # pre-resolved (edge headers)
        metadata: %{"plan" => "pro"}
      }

  `:ip` and `:user_agent` are used for the daily visitor hash and the client
  classification, then discarded — see `PhoenixKitWebAnalytics.Visitor`.

  `:roles` is only read for the hit's traffic flags (below), never stored.

  `:session_anchor` is for hits reported *after* the page they belong to — a
  leave recorded when a tab closes an hour after it opened. The visitor hash
  and the session lookup use the anchor instead of the insert time, so the
  leave joins the session its page view started rather than opening a new one.
  """

  require Logger

  import Bitwise
  import Ecto.Query

  alias PhoenixKitWebAnalytics.BotSignals
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Geo
  alias PhoenixKitWebAnalytics.InternalTraffic
  alias PhoenixKitWebAnalytics.Referrer
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Tracking
  alias PhoenixKitWebAnalytics.TrafficFlags
  alias PhoenixKitWebAnalytics.UserAgent
  alias PhoenixKitWebAnalytics.Visitor

  @task_supervisor PhoenixKitWebAnalytics.TaskSupervisor
  # Near a default Ecto pool (10) rather than far above it: each write holds a
  # connection for its transaction, and the host's own requests share the pool.
  @default_max_writes 20
  # A late hit (a leave) may land up to this long after its anchor and still
  # see the page view that opened it.
  @anchor_slack_seconds 5
  @warned_key {__MODULE__, :no_supervisor_warned}

  @gate PhoenixKitWebAnalytics.Collector.Gate
  @max_in_flight_per_visitor 3

  @doc """
  Child spec for the registry that counts each visitor's writes in flight.
  Returned from `PhoenixKitWebAnalytics.children/0`.
  """
  @spec gate_spec() :: Supervisor.child_spec()
  def gate_spec, do: Supervisor.child_spec({Registry, keys: :duplicate, name: @gate}, id: @gate)

  @doc """
  Child spec for the task supervisor that runs the async writes.

  Returned from `PhoenixKitWebAnalytics.children/0`, so a host running
  PhoenixKit's module supervision gets it with no configuration.
  """
  @spec task_supervisor_spec() :: Supervisor.child_spec()
  def task_supervisor_spec do
    Supervisor.child_spec(
      {Task.Supervisor,
       name: @task_supervisor,
       max_children:
         Application.get_env(
           :phoenix_kit_web_analytics,
           :max_concurrent_writes,
           @default_max_writes
         )},
      id: @task_supervisor
    )
  end

  @doc """
  Stores a hit off the request path. Always returns `:ok`.
  """
  @spec track_async(map()) :: :ok
  def track_async(hit) when is_map(hit) do
    cond do
      not Application.get_env(:phoenix_kit_web_analytics, :async_tracking, true) ->
        safe_track(hit)

      Process.whereis(@task_supervisor) ->
        supervised_track(hit)

      true ->
        warn_no_supervisor()
        :ok
    end
  end

  @doc """
  Runs `fun` under the same supervisor and cap as the writes — for other
  after-the-fact work that must stay off the caller's process (alerts). Inline
  when `async_tracking` is off. Always returns `:ok`; failures are logged.
  """
  @spec run_async((-> any())) :: :ok
  def run_async(fun) when is_function(fun, 0) do
    job = fn ->
      try do
        fun.()
      rescue
        error -> Logger.debug("[WebAnalytics] background job failed: #{Exception.message(error)}")
      catch
        :exit, reason -> Logger.debug("[WebAnalytics] background job exited: #{inspect(reason)}")
      end
    end

    cond do
      not Application.get_env(:phoenix_kit_web_analytics, :async_tracking, true) -> job.()
      Process.whereis(@task_supervisor) -> Task.Supervisor.start_child(@task_supervisor, job)
      true -> warn_no_supervisor()
    end

    :ok
  end

  @doc """
  Stores a hit synchronously.

  Used by tests (an async task can't see the Ecto sandbox connection) and by
  callers that want the result. Returns `{:error, :disabled}` when tracking is
  off and `{:error, :bot}` when the hit was filtered as automated traffic —
  both are ordinary outcomes, not failures.
  """
  @spec track(map()) ::
          {:ok, Event.t()} | {:error, :disabled | :bot | :invalid | Ecto.Changeset.t() | term()}
  def track(hit) when is_map(hit) do
    config = Config.collection_config()

    cond do
      not config.enabled? -> {:error, :disabled}
      not is_binary(hit[:path]) -> {:error, :invalid}
      true -> do_track(hit, config)
    end
  end

  @doc """
  Resolves which session a visitor's hit belongs to.

  Reuses the visitor's previous session on `site` when their last hit there is
  within `timeout_minutes`, otherwise mints a new one. `site` defaults to
  `:any`, which ignores the site. This is the whole reason
  no session cookie is needed: the stitch is an indexed lookup on
  (`visitor_id`, `inserted_at`), server-side.
  """
  @spec resolve_session(String.t(), pos_integer(), DateTime.t(), String.t() | nil | :any) ::
          Ecto.UUID.t()
  def resolve_session(visitor_id, timeout_minutes, now, site \\ :any) do
    visitor_id |> stitch(timeout_minutes, now, site) |> Map.fetch!(:session_id)
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp supervised_track(hit) do
    case Task.Supervisor.start_child(@task_supervisor, fn -> safe_track(hit) end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.debug("[WebAnalytics] dropped hit (#{inspect(reason)}): #{inspect(hit[:path])}")
        :ok
    end
  end

  # The task boundary: whatever goes wrong in one hit stays in that hit.
  defp safe_track(hit) do
    track(hit)
    :ok
  rescue
    error ->
      Logger.debug("[WebAnalytics] track failed: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("[WebAnalytics] track exited: #{inspect(reason)}")
      :ok
  end

  defp warn_no_supervisor do
    unless :persistent_term.get(@warned_key, false) do
      :persistent_term.put(@warned_key, true)

      Logger.warning(
        "[WebAnalytics] #{inspect(@task_supervisor)} is not running, so hits are dropped. " <>
          "Start the module's children (PhoenixKitWebAnalytics.children/0)."
      )
    end
  end

  defp do_track(hit, config) do
    ua = UserAgent.parse(hit[:user_agent])

    if ua.bot? and not config.track_bots? do
      {:error, :bot}
    else
      insert_event(hit, config, ua)
    end
  end

  defp insert_event(hit, config, ua) do
    now = hit[:inserted_at] || DateTime.utc_now()
    anchor = session_anchor(hit[:session_anchor], now)

    case visitor_id(hit, anchor) do
      nil ->
        {:error, :no_salt}

      visitor_id ->
        site = Referrer.normalize_host(hit[:site])
        flags = hit_flags(hit, config)

        result =
          through_gate(visitor_id, fn ->
            insert_stitched(hit, config, ua, {visitor_id, flags}, site, now, anchor)
          end)

        case result do
          {:ok, {%Event{} = event, new_session?}} ->
            PhoenixKitWebAnalytics.Alerts.event_recorded(event, new_session?)
            {:ok, event}

          # Flagged as a bot by its behaviour, with bot traffic not kept.
          {:ok, :bot} ->
            {:error, :bot}

          {:error, _} = error ->
            error
        end
    end
  end

  # A staff member's hit also marks their network (the plug does the same for
  # requests to excluded paths, before this point).
  defp hit_flags(hit, config) do
    flags = InternalTraffic.flags(hit, config)

    if (flags &&& TrafficFlags.bit(:admin)) != 0,
      do: InternalTraffic.note_admin_network(hit[:ip], config)

    flags
  end

  defp insert_stitched(hit, config, ua, {visitor_id, flags}, site, now, anchor) do
    speed = speed(hit, config, visitor_id)

    repo().transaction(fn ->
      lock_visitor(visitor_id)

      stitch =
        stitch(visitor_id, config.session_timeout_minutes, anchor, site,
          anchored?: is_struct(hit[:session_anchor], DateTime)
        )

      attrs =
        hit
        |> base_attrs(now)
        |> Map.merge(identity_attrs(visitor_id, stitch.session_id, ua))
        |> Map.merge(source_attrs(hit))
        |> Map.merge(location_attrs(hit))
        |> carry_language(stitch)
        |> Map.put(:session_start, stitch.new?)
        |> Map.put(:traffic_flags, flags ||| stitch.flags)

      judge_and_store(attrs, stitch, speed, config)
    end)
  end

  defp judge_and_store(attrs, stitch, speed, config) do
    case bot_verdict(attrs, stitch, speed, config) do
      {:flag, reason} ->
        # Going over the speed limit also flags the visit's earlier hits.
        if speed == :crossed, do: BotSignals.flag_session(stitch.session_id, "rate")

        if config.track_bots?,
          do: store(flag_attrs(attrs, reason), stitch),
          else: :bot

      # A "no JavaScript" verdict can be wrong (a tab idle past the judging,
      # a slow first connection), so its hits are kept, flagged, whatever
      # track_bots says — lifting the flag brings them back.
      {:flag_kept, reason} ->
        store(flag_attrs(attrs, reason), stitch)

      :clear ->
        result = store(attrs, stitch)
        BotSignals.clear_no_js(stitch.session_id)
        result

      :ok ->
        store(attrs, stitch)
    end
  end

  defp store(attrs, stitch) do
    case %Event{} |> Event.changeset(attrs) |> repo().insert() do
      {:ok, event} ->
        flag_session(stitch, attrs.traffic_flags)
        {event, stitch.new?}

      {:error, changeset} ->
        repo().rollback(changeset)
    end
  end

  # A bit the visit didn't have yet goes to its earlier hits too: the visit
  # is one person's, and an anonymous start followed by an admin sign-in is
  # an admin's visit. One session's rows, through the (session_id,
  # inserted_at) index; inside the hit's transaction, under its lock.
  defp flag_session(%{new?: true}, _flags), do: :ok

  defp flag_session(%{session_id: session_id, flags: previous}, flags) do
    case flags &&& bnot(previous) do
      0 ->
        :ok

      added ->
        from(e in Event,
          where: e.session_id == ^session_id,
          where: fragment("(? & ?) <> ?", e.traffic_flags, ^added, ^added),
          update: [set: [traffic_flags: fragment("? | ?", e.traffic_flags, ^added)]]
        )
        |> repo().update_all([])

        :ok
    end
  end

  # Page views per visitor per minute, for the speed signal.
  defp speed(hit, %{detect_bots?: true}, visitor_id) do
    if (hit[:event_type] || "pageview") == "pageview",
      do: BotSignals.count_pageview(visitor_id),
      else: :ok
  end

  defp speed(_hit, _config, _visitor_id), do: :ok

  # Whether this hit is a bot's by behaviour — see BotSignals. A visit
  # already flagged passes its flag on, except that a "no JavaScript" flag
  # is lifted by a report only JavaScript could have sent.
  defp bot_verdict(_attrs, _stitch, _speed, %{detect_bots?: false}), do: :ok

  defp bot_verdict(attrs, stitch, speed, _config) do
    cond do
      speed in [:crossed, :over] -> {:flag, "rate"}
      stitch.bot in ["webdriver", "rate"] -> {:flag, stitch.bot}
      stitch.bot == "no_js" and BotSignals.js_evidence?(attrs) -> :clear
      stitch.bot == "no_js" -> {:flag_kept, "no_js"}
      true -> :ok
    end
  end

  defp flag_attrs(attrs, reason) do
    attrs
    |> Map.put(:is_bot, true)
    |> Map.update(:metadata, %{"bot" => reason}, &Map.put(&1 || %{}, "bot", reason))
  end

  # Registered for the length of the write; the registry forgets a crashed
  # writer by itself. Without the registry (children not started) there is
  # no cap.
  defp through_gate(visitor_id, fun) do
    if Process.whereis(@gate) do
      {:ok, _owner} = Registry.register(@gate, visitor_id, nil)

      try do
        if length(Registry.lookup(@gate, visitor_id)) > @max_in_flight_per_visitor do
          Logger.debug("[WebAnalytics] dropped hit: too many writes in flight for one visitor")
          {:error, :visitor_busy}
        else
          fun.()
        end
      after
        Registry.unregister(@gate, visitor_id)
      end
    else
      fun.()
    end
  end

  # A hit with no client identity at all — a server-side `track_event/2` with
  # neither IP nor User-Agent — would otherwise hash every such event on a day
  # to one "unknown" visitor and stitch them into one endless session. Such an
  # event is its own visitor, unless it names a user.
  defp visitor_id(hit, anchor) do
    cond do
      hit[:ip] || hit[:user_agent] ->
        case Config.hash_salt() do
          nil -> nil
          salt -> Visitor.visitor_id(hit[:ip], hit[:user_agent], salt, DateTime.to_date(anchor))
        end

      is_binary(hit[:user_uuid]) ->
        "user:" <> hit[:user_uuid]

      true ->
        "anon:" <> String.replace(UUIDv7.generate(), "-", "")
    end
  end

  # Bounded wait: a flood of hits for one visitor must not park connections
  # behind the lock. A hit that can't get it in time fails and is dropped.
  defp lock_visitor(visitor_id) do
    repo().query!("SET LOCAL lock_timeout = '2s'", [], log: false)
    repo().query!("SELECT pg_advisory_xact_lock(hashtext($1))", [visitor_id], log: false)
  end

  # The visitor's latest hit on this site inside the window decides the
  # session; its language fills in for hits that can't see the
  # Accept-Language header (LiveView navigations, leaves).
  #
  # An anchored (late) hit looks only up to its anchor: a leave for a page
  # opened at t0 must join t0's session, not a newer one the visitor started
  # since.
  defp stitch(visitor_id, timeout_minutes, now, site, opts \\ []) do
    cutoff = DateTime.add(now, -timeout_minutes * 60, :second)

    query =
      from(e in Event,
        where: e.visitor_id == ^visitor_id and e.inserted_at >= ^cutoff,
        order_by: [desc: e.inserted_at],
        limit: 1,
        select: %{
          session_id: e.session_id,
          language: e.language,
          bot: fragment("?->>'bot'", e.metadata),
          flags: e.traffic_flags
        }
      )
      |> where_site(site)
      |> until_anchor(now, Keyword.get(opts, :anchored?, false))

    case repo().one(query) do
      nil -> new_session()
      previous -> Map.merge(previous, %{new?: false, flags: previous.flags || 0})
    end
  rescue
    # A failed stitch must not lose the event — start a new session instead.
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.debug("[WebAnalytics] session stitch failed: #{Exception.message(error)}")
      new_session()
  end

  defp new_session,
    do: %{session_id: UUIDv7.generate(), language: nil, bot: nil, flags: 0, new?: true}

  defp until_anchor(query, _anchor, false), do: query

  defp until_anchor(query, anchor, true) do
    upper = DateTime.add(anchor, @anchor_slack_seconds, :second)
    where(query, [e], e.inserted_at <= ^upper)
  end

  defp where_site(query, :any), do: query
  defp where_site(query, nil), do: where(query, [e], is_nil(e.site))
  defp where_site(query, site), do: where(query, [e], e.site == ^site)

  defp carry_language(%{language: nil} = attrs, %{language: language}),
    do: %{attrs | language: language}

  defp carry_language(attrs, _stitch), do: attrs

  defp base_attrs(hit, now) do
    %{
      event_type: hit[:event_type] || "pageview",
      event_name: hit[:event_name],
      site: Referrer.normalize_host(hit[:site]),
      path: normalize_path(hit[:path]),
      page_title: presence(hit[:page_title]),
      user_uuid: hit[:user_uuid],
      language: normalize_language(hit[:language]),
      status: hit[:status],
      duration_ms: hit[:duration_ms],
      engaged_ms: hit[:engaged_ms],
      scroll_depth: hit[:scroll_depth],
      target: presence(hit[:target]),
      metadata: hit[:metadata] || %{},
      inserted_at: now
    }
  end

  defp identity_attrs(visitor_id, session_id, ua) do
    %{
      visitor_id: visitor_id,
      session_id: session_id,
      browser: ua.browser,
      browser_version: ua.browser_version,
      os: ua.os,
      os_version: ua.os_version,
      device_type: ua.device_type,
      is_bot: ua.bot?
    }
  end

  defp session_anchor(%DateTime{} = anchor, now) do
    if DateTime.compare(anchor, now) == :gt, do: now, else: anchor
  end

  defp session_anchor(_anchor, now), do: now

  # UTM parameters win over the Referer header: a campaign URL is the visitor
  # telling us where they came from, and it survives redirects that strip the
  # referrer.
  defp source_attrs(hit) do
    params = hit[:query_params] || %{}
    referrer = hit[:referrer] |> presence() |> strip_query()
    {source, medium} = Referrer.classify(referrer, hit[:site])

    utm_source = param(params, "utm_source")
    utm_medium = param(params, "utm_medium")
    {click_param, click_id} = click_attrs(params)
    tagged_medium = utm_medium(utm_medium, utm_source, medium)

    %{
      referrer: referrer,
      referrer_source: utm_source || click_referrer_source(click_param, medium, source),
      referrer_medium: click_referrer_medium(click_param, medium, tagged_medium),
      utm_source: utm_source,
      utm_medium: utm_medium,
      utm_campaign: param(params, "utm_campaign"),
      utm_term: param(params, "utm_term"),
      utm_content: param(params, "utm_content"),
      click_id: click_id,
      click_param: click_param
    }
  end

  # The first identifier present wins; order follows click_param_names/0, so a
  # URL carrying both `wbraid` and `msclkid` is recorded under the same one
  # every time rather than whichever way the map happened to be ordered.
  defp click_attrs(params) do
    Enum.find_value(Tracking.click_param_names(), {nil, nil}, fn name ->
      case param(params, name) do
        nil -> nil
        value -> {name, value}
      end
    end)
  end

  # A click identifier says nothing about an internal hit: with Google's
  # `url_passthrough` the identifier rides along on every internal link of an
  # ad visit. An ad-only identifier names the platform; `fbclid` (also on
  # organic and Instagram clicks) only fills in for a missing referrer.
  defp click_referrer_source(nil, _medium, source), do: source
  defp click_referrer_source(_click_param, "internal", source), do: source

  defp click_referrer_source(click_param, _medium, source) do
    if Tracking.paid_click?(click_param),
      do: Tracking.click_source(click_param),
      else: source || Tracking.click_source(click_param)
  end

  # An ad-only identifier is proof of a paid click on its own: the ad platform
  # put it there. Without this, an auto-tagged ad visit lands in the table as
  # "direct" (no utm_medium, often no referrer) and is invisible in every
  # report.
  defp click_referrer_medium(nil, _medium, tagged), do: tagged
  defp click_referrer_medium(_click_param, "internal", tagged), do: tagged

  defp click_referrer_medium(click_param, _medium, tagged) do
    cond do
      Tracking.paid_click?(click_param) -> "paid"
      tagged == "none" -> "social"
      true -> tagged
    end
  end

  # `utm_medium` is free text ("cpc", "newsletter", …) but the column is a
  # controlled vocabulary, so map the common values and fall back to "referral"
  # for anything else tagged with a UTM source.
  defp utm_medium(nil, nil, referrer_medium), do: referrer_medium
  defp utm_medium(nil, _source, _referrer_medium), do: "referral"

  defp utm_medium(medium, _source, referrer_medium) do
    case String.downcase(medium) do
      m when m in ~w(organic search) -> "organic"
      m when m in ~w(social social-media socialmedia) -> "social"
      m when m in ~w(email newsletter) -> "email"
      m when m in ~w(cpc ppc paid paid_search paidsearch display banner) -> "paid"
      m when m in ~w(referral affiliate) -> "referral"
      _ -> if referrer_medium == "none", do: "referral", else: referrer_medium
    end
  end

  # An edge-provided location (Cloudflare et al.) is already there and free;
  # only fall back to the configured resolver when it isn't.
  defp location_attrs(hit) do
    case hit[:location] do
      %{country_code: code} = location when is_binary(code) and code != "" ->
        Map.take(location, [:country_code, :region, :city])

      _ ->
        Map.take(Geo.resolve(hit[:ip]), [:country_code, :region, :city])
    end
  end

  # A referrer is stored without its query string or fragment, for the same
  # reason paths are: an internal referrer is often the previous page's full
  # URL — a password-reset link, a search for an email address.
  defp strip_query(nil), do: nil

  defp strip_query(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        URI.to_string(%URI{uri | query: nil, fragment: nil, userinfo: nil})

      _ ->
        url |> String.split(["?", "#"], parts: 2) |> List.first() |> presence()
    end
  end

  # Query strings are not stored: they carry session tokens, emails, and
  # one-time links far more often than anything worth reporting. Campaign
  # parameters are extracted into their own columns before this point.
  defp normalize_path(path) when is_binary(path) do
    path
    |> redact_tokens()
    |> String.split("?")
    |> List.first()
    |> String.split("#")
    |> List.first()
    |> case do
      # Only absolute paths are stored: a relative one would split the same
      # page across two rows in every report depending on how it was reported.
      "/" -> "/"
      "/" <> _ = absolute -> String.trim_trailing(absolute, "/")
      _ -> "/"
    end
    |> case do
      "" -> "/"
      normalized -> normalized
    end
  end

  defp normalize_path(_path), do: "/"

  # Core's own routes that carry a one-time secret in the path itself (a
  # password reset, an email confirmation, a magic or QR login link, a
  # private-access link). The token is a live credential until it is used, and
  # a report reader or an alert recipient must not be able to read it. The
  # route keeps its name — "/users/reset-password/:token" is still a page worth
  # counting — and wherever the host mounts the prefix or the locale, the rest
  # of the path is whatever it was.
  @token_routes ~r{(/(?:users/(?:confirm/change-email|magic-link|reset-password|confirm|register/verify|register/complete|qr-login/finish|qr-login/scan)|confirm-email|access/link)/)[^/?#]+}

  defp redact_tokens(path), do: Regex.replace(@token_routes, path, "\\1:token")

  # "en-US,en;q=0.9" -> "en-US"
  defp normalize_language(nil), do: nil

  defp normalize_language(language) when is_binary(language) do
    language
    |> String.split(",")
    |> List.first()
    |> String.split(";")
    |> List.first()
    |> String.trim()
    |> presence()
  end

  defp normalize_language(_language), do: nil

  # A value that isn't valid UTF-8 (`?gclid=%FF`) can't be stored in a text
  # column; dropping it keeps the rest of the hit instead of losing the insert.
  # NULs go before the presence check, so `?gclid=%00` is no identifier rather
  # than an empty one.
  defp param(params, key) when is_map(params) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        if String.valid?(value), do: value |> String.replace(<<0>>, "") |> presence()

      _ ->
        nil
    end
  end

  defp param(_params, _key), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
