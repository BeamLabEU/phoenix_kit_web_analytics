defmodule PhoenixKitWebAnalytics.Test.CoverageRouter do
  @moduledoc """
  Routes for `LiveHook.coverage/1`: PhoenixKit's shape of a localized page
  (every page twice, with and without `/:locale`), an excluded localized page,
  and a `live` route outside any `live_session`. Only read, never dispatched.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  scope "/", PhoenixKitWebAnalytics.Test do
    live_session :hooked,
      on_mount: [{PhoenixKitWebAnalytics.LiveHook, :track_navigation}] do
      live("/shop", TrackedLive, :index)
      live("/:locale/shop", TrackedLive, :index)
      live("/:locale", TrackedLive, :index)
      live("/:locale/admin/orders", TrackedLive, :index)
    end

    live_session :unhooked do
      live("/blog", TrackedLive, :index)
      live("/:locale/blog", TrackedLive, :index)
      live("/:locale/admin/posts", TrackedLive, :index)
    end

    live("/bare", TrackedLive, :index)
  end
end
