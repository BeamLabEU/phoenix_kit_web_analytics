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
          await_fresh_minute: 0,
          clear_settings_cache: 0,
          days_ago: 1,
          enable_tracking: 0,
          enable_tracking: 1,
          hours_ago: 1,
          insert_event: 0,
          insert_event: 1
        ]

      import PhoenixKitWebAnalytics.ActivityLogAssertions
      import PhoenixKitWebAnalytics.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Role
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

  Roles are given as core's system-role keys (`:owner`, `:admin`, `:user`)
  or as role names, and stored the way core's `Scope.for_user/1` stores
  them — a list of names — so `Scope.owner?/1`, `has_role?/2` and
  `held_roles/1` answer as they would for a real user. `:held_roles` sets
  the user's real roles apart from the ones in effect (a narrowed scope).
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = opts |> Keyword.get(:roles, [:owner]) |> Enum.map(&role_name/1)
    held_roles = opts |> Keyword.get(:held_roles, roles) |> Enum.map(&role_name/1)
    permissions = Keyword.get(opts, :permissions, ["web_analytics"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    %PhoenixKit.Users.Auth.Scope{
      user: %{uuid: user_uuid, email: email},
      authenticated?: authenticated?,
      cached_roles: roles,
      held_roles: held_roles,
      cached_permissions: MapSet.new(permissions)
    }
  end

  defp role_name(role) when is_atom(role), do: Map.fetch!(Role.system_roles(), role)

  defp role_name(role) when is_binary(role), do: role

  @doc "Plugs a fake scope into the test conn's session. Pair with `fake_scope/1`."
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end
end
