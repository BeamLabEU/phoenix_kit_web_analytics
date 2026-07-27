defmodule PhoenixKitWebAnalytics.Test.Hooks do
  @moduledoc """
  `on_mount` hooks used by the LiveView test endpoint.

  Production runs these LiveViews inside `live_session :phoenix_kit_admin`,
  which core configures to populate `:phoenix_kit_current_scope` and
  `:phoenix_kit_current_user` from the host's authentication. The test endpoint
  doesn't load core's hooks, so this module replicates the effect from the test
  session.
  """

  import Phoenix.Component, only: [assign: 3]

  def on_mount(:assign_scope, _params, session, socket) do
    case Map.get(session, "phoenix_kit_test_scope") do
      nil ->
        {:cont, socket}

      %{user: user} = scope ->
        socket =
          socket
          |> assign(:phoenix_kit_current_scope, scope)
          |> assign(:phoenix_kit_current_user, user)

        {:cont, socket}
    end
  end
end
