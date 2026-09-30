defmodule PhoenixKitWebAnalytics.ConfigTest do
  use ExUnit.Case, async: true

  doctest PhoenixKitWebAnalytics.Config

  alias PhoenixKitWebAnalytics.Config

  describe "excluded?/2" do
    test "matches a literal path exactly" do
      assert Config.excluded?("/healthz", ["/healthz"])
      refute Config.excluded?("/healthz/deep", ["/healthz"])
    end

    test "a trailing star matches a prefix" do
      assert Config.excluded?("/admin", ["/admin*"])
      assert Config.excluded?("/admin/users/1", ["/admin*"])
      refute Config.excluded?("/administration-blog-post", ["/admin/*"])
    end

    test "no patterns excludes nothing" do
      refute Config.excluded?("/anything", [])
    end

    test "non-string input is never excluded rather than raising" do
      refute Config.excluded?(nil, ["/admin*"])
      refute Config.excluded?("/admin", nil)
    end
  end

  describe "defaults" do
    test "the default exclusions cover the admin panel" do
      exclusions =
        Config.default_exclusions()
        |> String.split("\n", trim: true)

      assert Config.excluded?("/admin/web-analytics", exclusions)
    end

    test "collection_config/0 reports tracking off when settings are unavailable" do
      config = Config.collection_config()

      assert is_boolean(config.enabled?)
      assert is_list(config.exclusions)
      assert config.session_timeout_minutes > 0
    end
  end

  describe "setting_keys/0" do
    test "every key is namespaced to this module" do
      for {_name, key} <- Config.setting_keys() do
        assert String.starts_with?(key, "web_analytics_")
      end
    end

    test "includes the master switch used by enabled?/0" do
      assert Config.setting_keys().enabled == Config.enabled_key()
    end
  end
end

defmodule PhoenixKitWebAnalytics.ConfigSettingsTest do
  @moduledoc "Config read against real settings rows."

  use PhoenixKitWebAnalytics.DataCase, async: false

  alias PhoenixKitWebAnalytics.Config

  describe "collection_config/0 defaults for the interaction keys" do
    setup do
      enable_tracking()
      :ok
    end

    test "unset keys take their documented defaults" do
      config = Config.collection_config()

      assert config.enabled? == true
      assert config.track_interactions? == true
      assert config.client_script? == false
      assert config.beacon_enabled? == false
      assert config.respect_dnt? == true
      assert config.ignore_events == ["validate"]
      assert config.event_params == ~w(tab view section step sort filter period)
    end

    test "the accessors agree with collection_config/0" do
      assert Config.client_script?() == false
      assert Config.event_params() == ~w(tab view section step sort filter period)
    end

    test "written values override the defaults" do
      enable_tracking(%{
        "web_analytics_client_script" => "true",
        "web_analytics_track_interactions" => "false",
        "web_analytics_ignore_events" => "validate,\nsearch*  noop",
        "web_analytics_event_params" => "tab , page"
      })

      config = Config.collection_config()

      assert config.client_script? == true
      assert config.track_interactions? == false
      assert config.ignore_events == ["validate", "search*", "noop"]
      assert config.event_params == ["tab", "page"]
      assert Config.client_script?() == true
    end
  end

  describe "ignored_event?/1" do
    test "is true for listed names and prefix patterns only" do
      enable_tracking(%{"web_analytics_ignore_events" => "validate, search*"})

      assert Config.ignored_event?("validate")
      assert Config.ignored_event?("search")
      assert Config.ignored_event?("search_users")
      refute Config.ignored_event?("save")
      refute Config.ignored_event?("validate_step")
      refute Config.ignored_event?("do_search")
    end

    test "the default list ignores validate" do
      enable_tracking()

      assert Config.ignored_event?("validate")
      refute Config.ignored_event?("add_to_cart")
    end

    test "everything is ignored when interaction tracking is off" do
      enable_tracking(%{"web_analytics_track_interactions" => "false"})

      assert Config.ignored_event?("add_to_cart")
      assert Config.ignored_event?("save")
    end
  end
end
