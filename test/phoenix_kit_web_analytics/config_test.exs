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

    test "a pattern matches past a leading locale segment too" do
      for path <- ~w(/et/admin /et/admin/users /en-GB/admin /fil/admin /zh-Hant/admin) do
        assert Config.excluded?(path, ["/admin*"]), path
      end

      assert Config.excluded?("/et", ["/"])
      assert Config.excluded?("/et/healthz", ["/healthz"])
      refute Config.excluded?("/et/healthz/deep", ["/healthz"])
    end

    test "a first segment that isn't shaped like a locale is part of the path" do
      for path <-
            ~w(/blog/admin /api/admin /mcp/admin /EN/admin /e/admin /en-x/admin /en-GBR1/admin) do
        refute Config.excluded?(path, ["/admin*"]), path
      end

      refute Config.excluded?("/et/blog", ["/admin*"])
      refute Config.excluded?("validate", ["/admin*"])
    end

    test "router locale parameters follow the same rule as request paths" do
      assert Config.excluded?("/:locale/admin/users", ["/admin*"])
      assert Config.excluded?("/:locale", ["/"])
      refute Config.excluded?("/:locale/faq/admin", ["/admin*"])
      refute Config.excluded?("/:slug/admin", ["/admin*"])
      refute Config.excluded?("/:slug", ["/"])
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

    test "collection_config/0 reads tracking as off when nothing says it's on" do
      config = Config.collection_config()

      refute config.enabled?
      assert "/admin*" in config.exclusions
      assert config.session_timeout_minutes == 30
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

defmodule PhoenixKitWebAnalytics.ConfigFailureTest do
  @moduledoc """
  What `collection_config/0` answers when the settings read fails.

  Sync: it writes `internal_networks` in the application env.
  """

  use ExUnit.Case, async: false

  alias PhoenixKitWebAnalytics.Config

  test "app-config networks still exempt and the blocklist stays empty" do
    Application.put_env(:phoenix_kit_web_analytics, :internal_networks, ["203.0.113.0/24"])
    on_exit(fn -> Application.delete_env(:phoenix_kit_web_analytics, :internal_networks) end)

    config = Config.config_without_settings()

    assert config.internal_networks == ["203.0.113.0/24"]
    assert config.rate_limit == :on
    refute config.enabled?
    assert config.blocked_networks == []
    assert config.api_paths == []
  end

  test "a non-list in app config contributes no networks" do
    Application.put_env(:phoenix_kit_web_analytics, :internal_networks, "203.0.113.0/24")
    on_exit(fn -> Application.delete_env(:phoenix_kit_web_analytics, :internal_networks) end)

    assert Config.config_without_settings().internal_networks == []
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

defmodule PhoenixKitWebAnalytics.ConfigClientHitsTest do
  # Changes app env, so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitWebAnalytics.Config

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_web_analytics, :client_hits_per_minute)
      :persistent_term.erase({Config, :client_hits_warned})
    end)

    :persistent_term.erase({Config, :client_hits_warned})
    :ok
  end

  defp limit_for(value) do
    Application.put_env(:phoenix_kit_web_analytics, :client_hits_per_minute, value)
    Config.client_hits_per_minute()
  end

  test "client_hits_per_minute: 60 by default, only 0 or false turn it off" do
    Application.delete_env(:phoenix_kit_web_analytics, :client_hits_per_minute)
    assert Config.client_hits_per_minute() == 60

    for value <- [0, false, "0", 0.0], do: assert(limit_for(value) == false, inspect(value))

    for {value, limit} <- [{25, 25}, {"25", 25}, {" 25 ", 25}, {25.0, 25}],
        do: assert(limit_for(value) == limit)
  end

  test "client_hits_per_minute: anything else is the default, with one warning" do
    log =
      capture_log(fn ->
        for value <- ["sixty", -5, nil, 60.5, :on, "25x"] do
          assert limit_for(value) == 60, inspect(value)
        end
      end)

    assert log =~ "client_hits_per_minute"
    assert length(String.split(log, "is not a whole number")) == 2
  end
end
