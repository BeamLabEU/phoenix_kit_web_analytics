defmodule PhoenixKitWebAnalytics.Routes do
  @moduledoc """
  Route macros for the module's six admin pages and two public collection
  endpoints. Returned from `PhoenixKitWebAnalytics.route_module/0`; PhoenixKit
  splices the admin routes inside its own `live_session :phoenix_kit_admin`
  (auth + admin layout applied automatically) and the public ones near the top
  of the host router.

  Both a localized (`/:locale/admin/...`) and a non-localized set are defined,
  as PhoenixKit requires — each route needs a unique `:as`.

  ## Why the collection endpoints skip `:browser`

  `generate/1` pipes through `:phoenix_kit_api` (JSON, no session, no CSRF)
  rather than `:browser`. The beacon posts with `navigator.sendBeacon`, which
  cannot carry a CSRF token, and the pixel is an `<img>` request — neither has
  a session to fetch or a form to protect. See
  `PhoenixKitWebAnalytics.Web.TrackController` for the trust boundary that
  replaces it.
  """

  @doc "Localized admin routes (inside the `/:locale` scope)."
  def admin_locale_routes do
    quote do
      live("/admin/web-analytics", PhoenixKitWebAnalytics.Web.DashboardLive, :index,
        as: :phoenix_kit_web_analytics_localized
      )

      live("/admin/web-analytics/pages", PhoenixKitWebAnalytics.Web.PagesLive, :index,
        as: :phoenix_kit_web_analytics_pages_localized
      )

      live("/admin/web-analytics/sources", PhoenixKitWebAnalytics.Web.SourcesLive, :index,
        as: :phoenix_kit_web_analytics_sources_localized
      )

      live("/admin/web-analytics/technology", PhoenixKitWebAnalytics.Web.TechnologyLive, :index,
        as: :phoenix_kit_web_analytics_technology_localized
      )

      live("/admin/web-analytics/events", PhoenixKitWebAnalytics.Web.EventsLive, :index,
        as: :phoenix_kit_web_analytics_events_localized
      )

      live("/admin/web-analytics/settings", PhoenixKitWebAnalytics.Web.SettingsLive, :index,
        as: :phoenix_kit_web_analytics_settings_localized
      )
    end
  end

  @doc "Non-localized admin routes."
  def admin_routes do
    quote do
      live("/admin/web-analytics", PhoenixKitWebAnalytics.Web.DashboardLive, :index,
        as: :phoenix_kit_web_analytics
      )

      live("/admin/web-analytics/pages", PhoenixKitWebAnalytics.Web.PagesLive, :index,
        as: :phoenix_kit_web_analytics_pages
      )

      live("/admin/web-analytics/sources", PhoenixKitWebAnalytics.Web.SourcesLive, :index,
        as: :phoenix_kit_web_analytics_sources
      )

      live("/admin/web-analytics/technology", PhoenixKitWebAnalytics.Web.TechnologyLive, :index,
        as: :phoenix_kit_web_analytics_technology
      )

      live("/admin/web-analytics/events", PhoenixKitWebAnalytics.Web.EventsLive, :index,
        as: :phoenix_kit_web_analytics_events
      )

      live("/admin/web-analytics/settings", PhoenixKitWebAnalytics.Web.SettingsLive, :index,
        as: :phoenix_kit_web_analytics_settings
      )
    end
  end

  @doc """
  Public collection endpoints — the optional beacon and pixel.

  These are specific (non-catch-all) paths, so they belong in `generate/1`.
  """
  def generate(url_prefix) do
    quote do
      scope unquote(url_prefix) do
        pipe_through([:phoenix_kit_api])

        post("/phoenix-kit/analytics/event", PhoenixKitWebAnalytics.Web.TrackController, :event)

        get(
          "/phoenix-kit/analytics/pixel.gif",
          PhoenixKitWebAnalytics.Web.TrackController,
          :pixel
        )
      end
    end
  end
end
