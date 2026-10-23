defmodule PhoenixKitWebAnalytics.Test.Router do
  @moduledoc """
  Minimal router for the LiveView test suite. The scope matches the URLs
  `PhoenixKitWebAnalytics.Paths` produces, so `live/2` calls in tests use
  exactly the URLs the LiveViews patch themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the settings
  table is unavailable, and the primary locale is prefixless (core 2.62 on;
  before that admin paths carried `/en`) — so the base is `/admin/web-analytics`.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitWebAnalytics.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  pipeline :api do
    plug(:accepts, ["json", "html"])
  end

  scope "/admin/web-analytics", PhoenixKitWebAnalytics.Web do
    pipe_through(:browser)

    live_session :web_analytics_test,
      layout: {PhoenixKitWebAnalytics.Test.Layouts, :app},
      on_mount: {PhoenixKitWebAnalytics.Test.Hooks, :assign_scope} do
      live("/", DashboardLive, :index)
      live("/pages", PagesLive, :index)
      live("/sources", SourcesLive, :index)
      live("/technology", TechnologyLive, :index)
      live("/events", EventsLive, :index)
      live("/settings", SettingsLive, :index)
      live("/bots", BotsLive, :index)
      live("/live", LiveNowLive, :index)
      live("/sessions", SessionsLive, :index)
      live("/sessions/:session_id", SessionLive, :show)
    end
  end

  # A host's public pages, tracked by the LiveView hook.
  scope "/shop", PhoenixKitWebAnalytics.Test do
    pipe_through(:browser)

    live_session :tracked_test,
      on_mount: [
        {PhoenixKitWebAnalytics.Test.Hooks, :assign_scope},
        {PhoenixKitWebAnalytics.LiveHook, :track_navigation}
      ] do
      live("/", TrackedLive, :index)
      live("/other", TrackedLive, :index)
    end
  end

  # A host's public pages that don't run the hook — what the warning on the
  # dashboard and in Settings points out.
  scope "/plain", PhoenixKitWebAnalytics.Test do
    pipe_through(:browser)

    live_session :untracked_test,
      on_mount: {PhoenixKitWebAnalytics.Test.Hooks, :assign_scope} do
      live("/", TrackedLive, :index)
    end
  end

  scope "/", PhoenixKitWebAnalytics.Web do
    pipe_through(:api)

    post("/phoenix-kit/analytics/event", TrackController, :event)
    get("/phoenix-kit/analytics/pixel.gif", TrackController, :pixel)
    get("/phoenix-kit/analytics/recording", TrackController, :recording_config)
    post("/phoenix-kit/analytics/recording", TrackController, :recording)
  end
end
