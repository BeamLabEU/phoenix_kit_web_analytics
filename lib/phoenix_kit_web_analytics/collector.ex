defmodule PhoenixKitWebAnalytics.Collector do
  @moduledoc """
  The write path: takes a raw hit, enriches it, and stores one
  `PhoenixKitWebAnalytics.Schemas.Event`.

  ## A hit never costs the request anything

  `track_async/1` hands the work to a `Task.Supervisor` and returns
  immediately, so the enrichment (a settings read, one session-stitching query,
  the insert) happens after the response is on its way out. The request process
  spends microseconds building a map.

  The task supervisor is started with a `max_children` cap. Under a flood, once
  the cap is reached, further hits are **dropped** rather than queued — an
  analytics backlog must not become the reason a host runs out of database
  connections. Drops are logged at debug level.

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
        status: 200,
        duration_ms: 12,
        location: %{country_code: "EE"},     # pre-resolved (edge headers)
        metadata: %{"plan" => "pro"}
      }

  `:ip` and `:user_agent` are used for the daily visitor hash and the client
  classification, then discarded — see `PhoenixKitWebAnalytics.Visitor`.
  """

  require Logger

  import Ecto.Query

  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Geo
  alias PhoenixKitWebAnalytics.Referrer
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.UserAgent
  alias PhoenixKitWebAnalytics.Visitor

  @task_supervisor PhoenixKitWebAnalytics.TaskSupervisor

  @doc """
  Child spec for the task supervisor that runs the async writes.

  Returned from `PhoenixKitWebAnalytics.children/0`, so a host running
  PhoenixKit's module supervision gets it with no configuration.
  """
  @spec task_supervisor_spec() :: Supervisor.child_spec()
  def task_supervisor_spec do
    Supervisor.child_spec(
      {Task.Supervisor, name: @task_supervisor, max_children: 2_000},
      id: @task_supervisor
    )
  end

  @doc """
  Stores a hit off the request path. Always returns `:ok`.

  Falls back to an unsupervised process when the task supervisor isn't running
  (a host that hasn't wired PhoenixKit's module children), so tracking still
  works — just without the backpressure cap.
  """
  @spec track_async(map()) :: :ok
  def track_async(hit) when is_map(hit) do
    if Process.whereis(@task_supervisor) do
      supervised_track(hit)
    else
      spawn(fn -> safe_track(hit) end)
      :ok
    end
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

  Reuses the visitor's previous session when their last hit is within
  `timeout_minutes`, otherwise mints a new one. This is the whole reason no
  session cookie is needed: the stitch is an indexed lookup on
  (`visitor_id`, `inserted_at`), server-side.
  """
  @spec resolve_session(String.t(), pos_integer(), DateTime.t()) :: Ecto.UUID.t()
  def resolve_session(visitor_id, timeout_minutes, now) do
    cutoff = DateTime.add(now, -timeout_minutes * 60, :second)

    query =
      from(e in Event,
        where: e.visitor_id == ^visitor_id and e.inserted_at >= ^cutoff,
        order_by: [desc: e.inserted_at],
        limit: 1,
        select: e.session_id
      )

    case repo().one(query) do
      nil -> UUIDv7.generate()
      session_id -> session_id
    end
  rescue
    # A failed stitch must not lose the event — start a new session instead.
    _ -> UUIDv7.generate()
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
    salt = Config.hash_salt()
    visitor_id = Visitor.visitor_id(hit[:ip], hit[:user_agent], salt, DateTime.to_date(now))
    session_id = resolve_session(visitor_id, config.session_timeout_minutes, now)

    %Event{}
    |> Event.changeset(
      hit
      |> base_attrs(now)
      |> Map.merge(identity_attrs(visitor_id, session_id, ua))
      |> Map.merge(source_attrs(hit))
      |> Map.merge(location_attrs(hit))
    )
    |> repo().insert()
  end

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

  # UTM parameters win over the Referer header: a campaign URL is the visitor
  # telling us where they came from, and it survives redirects that strip the
  # referrer.
  defp source_attrs(hit) do
    params = hit[:query_params] || %{}
    referrer = presence(hit[:referrer])
    {source, medium} = Referrer.classify(referrer, hit[:site])

    utm_source = param(params, "utm_source")
    utm_medium = param(params, "utm_medium")

    %{
      referrer: referrer,
      referrer_source: utm_source || source,
      referrer_medium: utm_medium(utm_medium, utm_source, medium),
      utm_source: utm_source,
      utm_medium: utm_medium,
      utm_campaign: param(params, "utm_campaign"),
      utm_term: param(params, "utm_term"),
      utm_content: param(params, "utm_content")
    }
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

  # Query strings are not stored: they carry session tokens, emails, and
  # one-time links far more often than anything worth reporting. Campaign
  # parameters are extracted into their own columns before this point.
  defp normalize_path(path) when is_binary(path) do
    path
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

  defp param(params, key) when is_map(params), do: presence(Map.get(params, key))
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
