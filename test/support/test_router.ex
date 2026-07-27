defmodule PhoenixKitWebAnalytics.Test.Router do
  @moduledoc """
  Minimal router for the LiveView test suite. The scope matches the URLs
  `PhoenixKitWebAnalytics.Paths` produces, so `live/2` calls in tests use
  exactly the URLs the LiveViews patch themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the settings
  table is unavailable, and admin paths always get the default locale prefix —
  so the base is `/en/admin/web-analytics`.
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

  scope "/en/admin/web-analytics", PhoenixKitWebAnalytics.Web do
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
    end
  end

  scope "/", PhoenixKitWebAnalytics.Web do
    pipe_through(:api)

    post("/phoenix-kit/analytics/event", TrackController, :event)
    get("/phoenix-kit/analytics/pixel.gif", TrackController, :pixel)
  end
end
