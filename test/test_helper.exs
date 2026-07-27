# Test helper for the PhoenixKitWebAnalytics suite.
#
# Level 1: Unit tests (User-Agent parsing, referrer classification, visitor
#          hashing, period maths) always run — they touch no database.
# Level 2: Integration tests need PostgreSQL and are excluded automatically
#          when it isn't available (`:integration` tag).
#
# To enable integration tests:
#
#     mix test.setup           # createdb
#     mix test
#
# The test endpoint runs with `server: false` (no port opened); LiveView tests
# drive it through `Phoenix.LiveViewTest.live/2` only.

# Elixir 1.19's `mix test` no longer auto-loads modules from the test
# `:elixirc_paths` at test-helper time — only files matching
# `:test_load_filters` are loaded by the runner. The support modules are
# compiled but not loaded, so they need explicit `Code.require_file/2` before
# this file references them.
support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "test_migration.ex",
  "test_layouts.ex",
  "hooks.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "data_case.ex",
  "live_case.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

db_name =
  Application.get_env(:phoenix_kit_web_analytics, PhoenixKitWebAnalytics.Test.Repo)[:database] ||
    "phoenix_kit_web_analytics_test"

db_check =
  try do
    case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
      {output, 0} ->
        exists =
          output
          |> String.split("\n")
          |> Enum.any?(fn line ->
            line |> String.split("|") |> List.first("") |> String.trim() == db_name
          end)

        if exists, do: :exists, else: :not_found

      _ ->
        :try_connect
    end
  rescue
    # `psql` isn't in PATH — fall through to the connect path, which fails
    # gracefully and excludes :integration tests.
    ErlangError -> :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Test database "#{db_name}" not found — integration tests will be excluded.
       Run `mix test.setup` to create the test database.
    """)

    false
  else
    try do
      {:ok, _} = PhoenixKitWebAnalytics.Test.Repo.start_link()

      # Core's own versioned migrations build the shared schema
      # (phoenix_kit_settings, the uuid_generate_v7() function, …).
      PhoenixKit.Migration.ensure_current(PhoenixKitWebAnalytics.Test.Repo, log: false)

      # Then this module's tables, through the same coordinator a real host
      # runs via `mix phoenix_kit.update` — so the suite can never pass against
      # a schema that differs from what installs get.
      Ecto.Migrator.up(
        PhoenixKitWebAnalytics.Test.Repo,
        20_260_726_000_001,
        PhoenixKitWebAnalytics.Test.Migration,
        log: false
      )

      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitWebAnalytics.Test.Repo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_web_analytics, :test_repo_available, repo_available)

# Minimal PhoenixKit services so Settings, the settings cache, and the module
# registry resolve during tests.
{:ok, _} = PhoenixKit.Cache.Registry.start_link()
{:ok, _} = PhoenixKit.Cache.start_link(name: :settings)
{:ok, _} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _} = PhoenixKit.ModuleRegistry.start_link([])

exclude = if repo_available, do: [], else: [:integration]

# Force PhoenixKit's URL prefix cache to an empty string so `Paths.dashboard()`
# and friends produce paths the test router can match. Admin paths always get
# the default locale ("en") prefix, so the router scope is
# `/en/admin/web-analytics`.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

if repo_available do
  {:ok, _} = PhoenixKitWebAnalytics.Test.Endpoint.start_link()
end

ExUnit.start(exclude: exclude)
