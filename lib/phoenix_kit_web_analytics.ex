defmodule PhoenixKitWebAnalytics do
  @moduledoc """
  Privacy-first web analytics for PhoenixKit — the numbers a hosted analytics
  product gives you, without the script tag.

  ## What makes it different

  Tracking happens **server-side**, in
  `PhoenixKitWebAnalytics.Plug`. One line in the host's browser pipeline counts
  every HTML response:

      pipeline :browser do
        # … existing plugs …
        plug PhoenixKitWebAnalytics.Plug
      end

  From there:

    * **Nothing is added to your pages.** No script tag, no bundle to download,
      no render-blocking request, no third-party domain. Page weight and Core
      Web Vitals are exactly what they were.
    * **No cookies, no consent banner.** Visitors are identified by a salted
      hash of IP + User-Agent that rotates daily and is never stored in
      reversible form — see `PhoenixKitWebAnalytics.Visitor`. No IP address is
      written to the database.
    * **Ad blockers can't remove it.** There is no client-side request to
      block, so the numbers are the server's, not a script's.
    * **The data is yours.** It lives in two tables in the host's own database.

  For LiveView navigation (`push_patch` / `push_navigate`), add
  `PhoenixKitWebAnalytics.LiveHook` to the `live_session`. For custom events
  from the browser, there is an optional ~300-byte inline snippet —
  `PhoenixKitWebAnalytics.Web.Beacon` — that is off by default.

  ## Reports

  Six admin pages under **Web Analytics**: an overview with the trend and
  headline numbers, pages, acquisition (referrers / channels / campaigns),
  technology (browsers, systems, devices, countries), custom events with a live
  feed, and settings. Everything they show comes from
  `PhoenixKitWebAnalytics.Reports`, which is a plain module you can call from
  your own code:

      import PhoenixKitWebAnalytics.Reports

      "30d" |> then(&filter(period: &1)) |> top_paths(limit: 20)

  ## Installation

      # host mix.exs
      {:phoenix_kit_web_analytics, "~> 0.2"}

  Then `mix deps.get` and `mix phoenix_kit.update` (creates
  `phoenix_kit_web_analytics_events` and
  `phoenix_kit_web_analytics_daily_stats`), add the plug, and enable the module
  on the admin Modules page.

  ## Data growth

  This is the one PhoenixKit table that grows with traffic rather than with
  content. `PhoenixKitWebAnalytics.Retention` rolls completed days into daily
  totals and prunes raw events past the retention window (365 days by default),
  so the trend line is permanent while the row count is bounded.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Reports

  @version "0.2.1"

  # ── Required callbacks ─────────────────────────────────────────────────────

  @impl PhoenixKit.Module
  def module_key, do: "web_analytics"

  @impl PhoenixKit.Module
  def module_name, do: "Web Analytics"

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
      label: "Web Analytics",
      icon: "hero-chart-bar",
      description: "Cookieless, server-side traffic analytics"
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
        label: "Web Analytics",
        icon: "hero-chart-bar",
        path: "web-analytics",
        priority: 650,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false
      },
      subtab(:admin_web_analytics_overview, "Overview", "hero-chart-bar", "web-analytics", 651,
        match: :exact
      ),
      subtab(
        :admin_web_analytics_pages,
        "Pages",
        "hero-document-text",
        "web-analytics/pages",
        652
      ),
      subtab(
        :admin_web_analytics_sources,
        "Acquisition",
        "hero-arrow-trending-up",
        "web-analytics/sources",
        653
      ),
      subtab(
        :admin_web_analytics_technology,
        "Technology",
        "hero-device-phone-mobile",
        "web-analytics/technology",
        654
      ),
      subtab(:admin_web_analytics_events, "Events", "hero-bolt", "web-analytics/events", 655),
      subtab(
        :admin_web_analytics_settings,
        "Settings",
        "hero-cog-6-tooth",
        "web-analytics/settings",
        656
      )
    ]
  end

  @impl PhoenixKit.Module
  @doc "Six admin pages plus the public collection endpoints."
  def route_module, do: PhoenixKitWebAnalytics.Routes

  @impl PhoenixKit.Module
  @doc "The events + daily stats tables (run by `mix phoenix_kit.update`)."
  def migration_module, do: PhoenixKitWebAnalytics.Migrations

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_web_analytics]

  @impl PhoenixKit.Module
  @doc """
  Background workers: the task supervisor that absorbs writes off the request
  path, and the hourly rollup/prune pass.
  """
  def children do
    [
      Collector.task_supervisor_spec(),
      PhoenixKitWebAnalytics.Retention
    ]
  end

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
      match: Keyword.get(opts, :match, :prefix)
    }
  end
end
