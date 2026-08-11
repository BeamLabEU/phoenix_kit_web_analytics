defmodule PhoenixKitWebAnalyticsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.Tab

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitWebAnalytics.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has the @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitWebAnalytics.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0" do
      assert PhoenixKitWebAnalytics.module_key() == "web_analytics"
    end

    test "module_name/0" do
      assert PhoenixKitWebAnalytics.module_name() == "Web Analytics"
    end

    test "enabled?/0 returns a boolean even with no database" do
      assert is_boolean(PhoenixKitWebAnalytics.enabled?())
    end

    test "enable_system/0 and disable_system/0 are exported" do
      assert function_exported?(PhoenixKitWebAnalytics, :enable_system, 0)
      assert function_exported?(PhoenixKitWebAnalytics, :disable_system, 0)
    end
  end

  describe "version" do
    test "version/0 matches mix.exs" do
      assert PhoenixKitWebAnalytics.version() == "0.2.1"

      assert PhoenixKitWebAnalytics.version() ==
               to_string(Application.spec(:phoenix_kit_web_analytics, :vsn))
    end
  end

  describe "permission_metadata/0" do
    test "returns the required fields and matches module_key/0" do
      meta = PhoenixKitWebAnalytics.permission_metadata()

      assert %{key: key, label: label, icon: icon, description: description} = meta
      assert key == PhoenixKitWebAnalytics.module_key()
      assert is_binary(label) and label != ""
      assert String.starts_with?(icon, "hero-")
      assert is_binary(description) and description != ""
    end
  end

  describe "admin_tabs/0" do
    setup do
      %{tabs: PhoenixKitWebAnalytics.admin_tabs()}
    end

    test "declares a parent tab plus one subtab per report page", %{tabs: tabs} do
      assert length(tabs) == 7

      parents = Enum.filter(tabs, &is_nil(&1.parent))
      assert [%Tab{id: :admin_web_analytics}] = parents

      subtabs = Enum.filter(tabs, &(&1.parent == :admin_web_analytics))
      assert length(subtabs) == 6
    end

    test "every tab gates on this module's permission", %{tabs: tabs} do
      for tab <- tabs do
        assert tab.permission == PhoenixKitWebAnalytics.module_key()
        assert tab.level == :admin
      end
    end

    test "tab ids are unique and paths use hyphens, not underscores", %{tabs: tabs} do
      ids = Enum.map(tabs, & &1.id)
      assert ids == Enum.uniq(ids)

      for tab <- tabs do
        refute String.contains?(tab.path, "_")
        refute String.starts_with?(tab.path, "/")
      end
    end

    test "routes come from the route module, so no tab carries a live_view", %{tabs: tabs} do
      assert Enum.all?(tabs, &is_nil(&1.live_view))
    end
  end

  describe "wiring callbacks" do
    test "route_module/0 and migration_module/0 point at real modules" do
      assert PhoenixKitWebAnalytics.route_module() == PhoenixKitWebAnalytics.Routes
      assert PhoenixKitWebAnalytics.migration_module() == PhoenixKitWebAnalytics.Migrations

      assert Code.ensure_loaded?(PhoenixKitWebAnalytics.Routes)
      assert Code.ensure_loaded?(PhoenixKitWebAnalytics.Migrations)
    end

    test "css_sources/0 returns this OTP app" do
      assert PhoenixKitWebAnalytics.css_sources() == [:phoenix_kit_web_analytics]
    end

    test "children/0 supervises the write pool and the retention worker" do
      children = PhoenixKitWebAnalytics.children()

      assert length(children) == 2
      assert PhoenixKitWebAnalytics.Retention in children
    end
  end

  describe "route module" do
    test "defines the same set of routes in localized and non-localized form" do
      localized = Macro.to_string(PhoenixKitWebAnalytics.Routes.admin_locale_routes())
      plain = Macro.to_string(PhoenixKitWebAnalytics.Routes.admin_routes())

      for page <- ~w(pages sources technology events settings) do
        assert localized =~ "/admin/web-analytics/#{page}"
        assert plain =~ "/admin/web-analytics/#{page}"
      end

      # Every localized route needs a distinct :as name from its plain twin.
      assert localized =~ "_localized"
      refute plain =~ "_localized"
    end

    test "collection endpoints skip the browser pipeline (no CSRF for sendBeacon)" do
      generated = Macro.to_string(PhoenixKitWebAnalytics.Routes.generate("/"))

      assert generated =~ ":phoenix_kit_api"
      refute generated =~ ":browser"
      assert generated =~ "/phoenix-kit/analytics/event"
      assert generated =~ "/phoenix-kit/analytics/pixel.gif"
    end
  end
end
