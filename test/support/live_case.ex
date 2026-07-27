defmodule PhoenixKitWebAnalytics.LiveCase do
  @moduledoc """
  Test case for LiveView and controller tests. Wires up the test endpoint,
  imports `Phoenix.LiveViewTest` / `Phoenix.ConnTest` helpers, and checks out an
  Ecto sandbox connection.

  Tests using this case are tagged `:integration` and are excluded when the
  test database isn't available, matching the rest of the suite.

      defmodule PhoenixKitWebAnalytics.Web.DashboardLiveTest do
        use PhoenixKitWebAnalytics.LiveCase

        test "renders the overview", %{conn: conn} do
          {:ok, _view, html} = live(conn, "/en/admin/web-analytics")
          assert html =~ "Web Analytics"
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitWebAnalytics.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      import PhoenixKitWebAnalytics.DataCase,
        only: [
          clear_settings_cache: 0,
          days_ago: 1,
          enable_tracking: 0,
          enable_tracking: 1,
          hours_ago: 1,
          insert_event: 0,
          insert_event: 1
        ]

      import PhoenixKitWebAnalytics.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitWebAnalytics.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    PhoenixKitWebAnalytics.DataCase.clear_settings_cache()

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  A real `PhoenixKit.Users.Auth.Scope` struct for tests.

  The admin LiveViews are mounted through core's admin `live_session` in
  production, which pattern-matches on the struct — a plain map won't do.
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, [:owner])
    permissions = Keyword.get(opts, :permissions, ["web_analytics"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    %PhoenixKit.Users.Auth.Scope{
      user: %{uuid: user_uuid, email: email},
      authenticated?: authenticated?,
      cached_roles: MapSet.new(roles),
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc "Plugs a fake scope into the test conn's session. Pair with `fake_scope/1`."
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end
end
