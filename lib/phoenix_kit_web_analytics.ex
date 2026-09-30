defmodule PhoenixKitWebAnalytics do
  @moduledoc """
  Web analytics for PhoenixKit sites, recorded by the server — who comes,
  where from, what they do, and when they leave.

  ## Where the data comes from

    * `PhoenixKitWebAnalytics.Plug` — one line in the host's browser pipeline
      records every HTML page view.
    * `PhoenixKitWebAnalytics.LiveHook` — on LiveView pages, records live
      navigation, every event the LiveView handles (by name, never form
      contents), and — through `PhoenixKitWebAnalytics.LivePresence` — when
      the visitor leaves and who is online right now.
    * The optional client script (`js_sources/0`) — outbound and download
      clicks, scroll depth, exits from pages without a LiveView. Its reports
      are stored only when switched on in Settings.
    * `track_event/2` — facts your server already knows.

  No cookie, no IP address, no raw User-Agent and no query string is stored;
  visitors are a salted daily hash — see `PhoenixKitWebAnalytics.Visitor`.

  ## Reports and alerts

  Admin pages: overview, right now, sessions with a per-visit timeline, pages,
  acquisition, technology, events, settings. Everything they show comes from
  `PhoenixKitWebAnalytics.Reports`, a plain module you can call:

      alias PhoenixKitWebAnalytics.Reports

      Reports.top_paths(Reports.filter(period: "30d"), limit: 20)

  `PhoenixKitWebAnalytics.Alerts` registers a "Website activity" notification
  type — new visitors (filtered), sign-ups, tracked events — delivered through
  PhoenixKit's notification channels (in-app, email, Telegram, digests).

  ## Installation

      # host mix.exs
      {:phoenix_kit_web_analytics, "~> 0.2"}

  Then `mix deps.get` and `mix phoenix_kit.update`, add the plug and the hook,
  list `:peer_data` and `:user_agent` in the LiveView socket's `connect_info`
  (websocket and longpoll), and enable the module on the admin Modules page.

  ## Data growth

  `PhoenixKitWebAnalytics.Retention` rolls completed days into daily totals and
  prunes raw events past the retention window (365 days by default), so the
  trend line is permanent while the row count is bounded.
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Reports

  @version "0.2.3"

  # ── Required callbacks ─────────────────────────────────────────────────────

  @impl PhoenixKit.Module
  def module_key, do: "web_analytics"

  @impl PhoenixKit.Module
  def module_name, do: gettext("Web Analytics")

  @impl PhoenixKit.Module
  @doc """
  Whether tracking is on.

  Defensive against the DB being unavailable (boot ordering, a test sandbox
  owner that just stopped): every failure path answers `false`, so the plug
  treats "we don't know" as "don't track".
  """
  def enabled? do
    Settings.get_boolean_setting(Config.enabled_key(), false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  @doc """
  Turns tracking on, generating the visitor-hash salt if this is a first
  enable — so the very first request already hashes against a real secret.
  """
  def enable_system do
    Config.hash_salt()
    Settings.update_boolean_setting_with_module(Config.enabled_key(), true, module_key())
  end

  @impl PhoenixKit.Module
  def disable_system,
    do: Settings.update_boolean_setting_with_module(Config.enabled_key(), false, module_key())

  # ── Optional callbacks ─────────────────────────────────────────────────────

  @impl PhoenixKit.Module
  def version, do: @version

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: gettext("Web Analytics"),
      icon: "hero-chart-bar",
      description: gettext("Cookieless, server-side traffic analytics")
    }
  end

  @impl PhoenixKit.Module
  @doc """
  Sidebar entries. Routes come from `route_module/0`, so no tab carries a
  `:live_view` — these are navigation and active-state anchors only.
  """
  def admin_tabs do
    [
      %Tab{
        id: :admin_web_analytics,
        label: gettext_noop("Web Analytics"),
        icon: "hero-chart-bar",
        path: "web-analytics",
        priority: 650,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        gettext_backend: PhoenixKitWebAnalytics.Gettext
      },
      subtab(
        :admin_web_analytics_overview,
        gettext_noop("Overview"),
        "hero-chart-bar",
        "web-analytics",
        651,
        match: :exact
      ),
      subtab(
        :admin_web_analytics_live,
        gettext_noop("Right now"),
        "hero-signal",
        "web-analytics/live",
        652
      ),
      subtab(
        :admin_web_analytics_sessions,
        gettext_noop("Visits"),
        "hero-users",
        "web-analytics/sessions",
        653
      ),
      subtab(
        :admin_web_analytics_pages,
        gettext_noop("Pages"),
        "hero-document-text",
        "web-analytics/pages",
        654
      ),
      subtab(
        :admin_web_analytics_sources,
        gettext_noop("Acquisition"),
        "hero-arrow-trending-up",
        "web-analytics/sources",
        655
      ),
      subtab(
        :admin_web_analytics_technology,
        gettext_noop("Technology"),
        "hero-device-phone-mobile",
        "web-analytics/technology",
        656
      ),
      subtab(
        :admin_web_analytics_events,
        gettext_noop("Events"),
        "hero-bolt",
        "web-analytics/events",
        657
      ),
      subtab(
        :admin_web_analytics_settings,
        gettext_noop("Settings"),
        "hero-cog-6-tooth",
        "web-analytics/settings",
        658
      )
    ]
  end

  @impl PhoenixKit.Module
  @doc "The admin pages plus the public collection endpoints."
  def route_module, do: PhoenixKitWebAnalytics.Routes

  @impl PhoenixKit.Module
  @doc "The events + daily stats tables (run by `mix phoenix_kit.update`)."
  def migration_module, do: PhoenixKitWebAnalytics.Migrations

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_web_analytics]

  @impl PhoenixKit.Module
  @doc """
  The optional client script (clicks the server can't see, scroll depth, exits
  from non-LiveView pages), folded into the host's `phoenix_kit_modules.js`.
  It sends nothing the server accepts until **Client script** is switched on
  in settings.
  """
  def js_sources do
    [
      %{
        app: :phoenix_kit_web_analytics,
        file: "static/assets/phoenix_kit_web_analytics.js",
        global: "PhoenixKitWebAnalyticsHooks"
      }
    ]
  end

  @impl PhoenixKit.Module
  @doc """
  Background workers: the task supervisor that absorbs writes off the request
  path, and the hourly rollup/prune pass.
  """
  def children do
    [
      Collector.task_supervisor_spec(),
      PhoenixKitWebAnalytics.LivePresence,
      PhoenixKitWebAnalytics.ReportCache,
      PhoenixKitWebAnalytics.Alerts,
      PhoenixKitWebAnalytics.Retention
    ]
  end

  @impl PhoenixKit.Module
  @doc """
  The **Website activity** notification type — new visitors, sign-ups and
  tracked events. See `PhoenixKitWebAnalytics.Alerts`.
  """
  def notification_types, do: PhoenixKitWebAnalytics.Alerts.notification_types()

  @impl PhoenixKit.Module
  @doc "Summary shown on the admin Modules page."
  def get_config do
    stats = Reports.storage_stats()

    %{
      enabled: enabled?(),
      events_stored: stats.events,
      retention_days: Config.retention_days(),
      beacon_enabled: Config.beacon_enabled?()
    }
  rescue
    _ -> %{enabled: false}
  end

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Records a custom event from server-side code.

  Use this for things that happen in your context modules rather than in the
  browser — an order placed, a subscription upgraded — where the event is a
  fact the server already knows and shouldn't depend on the client to report.

      PhoenixKitWebAnalytics.track_event("order.placed", %{
        path: "/checkout",
        metadata: %{"total_cents" => 4900},
        user_uuid: user.uuid
      })

  `attrs` accepts any key from `PhoenixKitWebAnalytics.Collector`'s hit shape.
  Returns `:ok` immediately; the write happens in a supervised task.

  Without `:ip` and `:user_agent` the event still records, but under a visitor
  hash that won't match that person's page views — pass `conn` values through
  when the event happens inside a request and you want it attributed to the
  same visitor.
  """
  @spec track_event(String.t(), map()) :: :ok
  def track_event(name, attrs \\ %{}) when is_binary(name) do
    attrs
    |> Map.merge(%{event_type: "event", event_name: name})
    |> Map.put_new(:path, "/")
    |> Collector.track_async()
  end

  @doc """
  Records a page view from server-side code.

  Only needed for pages the plug can't see — a response rendered by something
  other than the browser pipeline. Ordinary pages are already counted.
  """
  @spec track_pageview(map()) :: :ok
  def track_pageview(attrs) when is_map(attrs) do
    attrs
    |> Map.put(:event_type, "pageview")
    |> Map.put_new(:path, "/")
    |> Collector.track_async()
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp subtab(id, label, icon, path, priority, opts \\ []) do
    %Tab{
      id: id,
      label: label,
      icon: icon,
      path: path,
      priority: priority,
      level: :admin,
      permission: module_key(),
      parent: :admin_web_analytics,
      match: Keyword.get(opts, :match, :prefix),
      gettext_backend: PhoenixKitWebAnalytics.Gettext
    }
  end
end
