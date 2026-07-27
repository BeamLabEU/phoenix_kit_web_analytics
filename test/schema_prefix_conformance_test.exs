defmodule PhoenixKitWebAnalytics.SchemaPrefixConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the runtime half of named-schema (`--prefix`) support: every
  table-backed schema must `use PhoenixKit.SchemaPrefix` so its queries target
  the schema the migrations installed into. A schema missing it silently falls
  back to `search_path` resolution — invisible on public installs, broken on
  prefixed ones.
  """

  test "every table-backed schema uses PhoenixKit.SchemaPrefix" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(fn path ->
        content = File.read!(path)

        String.contains?(content, ~s[schema "phoenix_kit]) and
          not String.contains?(content, "use PhoenixKit.SchemaPrefix")
      end)

    assert offenders == [],
           "table-backed schemas missing `use PhoenixKit.SchemaPrefix` " <>
             "(add it right after `use Ecto.Schema`): #{inspect(offenders)}"
  end

  test "migrations never hardcode a schema-qualified table name" do
    migration = File.read!("lib/phoenix_kit_web_analytics/migrations.ex")

    refute migration =~ ~s["public.phoenix_kit_web_analytics]
  end
end
