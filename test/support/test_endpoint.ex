defmodule PhoenixKitWebAnalytics.Test.Endpoint do
  @moduledoc """
  Minimal `Phoenix.Endpoint` used by the LiveView and controller tests.

  `phoenix_kit_web_analytics` is a library — in production it borrows the host
  app's endpoint and router. This endpoint exists only so
  `Phoenix.LiveViewTest` and `Phoenix.ConnTest` can drive the module's
  LiveViews and controller through real URLs.
  """

  use Phoenix.Endpoint, otp_app: :phoenix_kit_web_analytics

  @session_options [
    store: :cookie,
    key: "_phoenix_kit_web_analytics_test_key",
    signing_salt: "web-analytics-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :user_agent, session: @session_options]]
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.Session, @session_options)
  plug(PhoenixKitWebAnalytics.Test.Router)
end
