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
