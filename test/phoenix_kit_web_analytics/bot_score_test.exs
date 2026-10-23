defmodule PhoenixKitWebAnalytics.BotScoreTest do
  use ExUnit.Case, async: true

  doctest PhoenixKitWebAnalytics.BotScore
  doctest PhoenixKitWebAnalytics.Signals

  alias PhoenixKitWebAnalytics.BotScore
  alias PhoenixKitWebAnalytics.Signals
  alias PhoenixKitWebAnalytics.Web.Components

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

  defp headers(names, extra \\ %{}) do
    Map.merge(
      %{"http" => "HTTP/2", "scheme" => "https", "names" => names, "values" => %{}},
      extra
    )
  end

  @browser_headers ~w(host accept accept-language sec-ch-ua sec-fetch-site sec-fetch-mode user-agent)

  describe "request_reasons/1" do
    test "a browser sending what a browser sends has none" do
      assert BotScore.request_reasons(%{user_agent: @chrome, headers: headers(@browser_headers)}) ==
               []
    end

    test "a declared bot and a missing User-Agent" do
      assert BotScore.request_reasons(%{user_agent: "curl/8.4.0"}) == ["declared_bot"]
      assert BotScore.request_reasons(%{user_agent: nil}) == ["no_user_agent"]
    end

    test "headers that aren't kept say nothing" do
      assert BotScore.request_reasons(%{user_agent: @chrome, headers: nil}) == []
    end

    test "a browser's User-Agent on a script's headers" do
      assert BotScore.request_reasons(%{user_agent: @chrome, headers: headers(["host"])}) ==
               ~w(no_accept_language no_accept no_fetch_metadata no_client_hints)
    end

    test "fetch metadata and client hints aren't expected over plain HTTP" do
      names = ~w(host accept accept-language)

      assert BotScore.request_reasons(%{
               user_agent: @chrome,
               headers: headers(names, %{"scheme" => "http"})
             }) == []
    end

    test "HTTP/1.0" do
      assert "old_http" in BotScore.request_reasons(%{
               user_agent: @chrome,
               headers: headers(@browser_headers, %{"http" => "HTTP/1.0"})
             })
    end

    test "a phone's User-Agent from a hosting provider" do
      assert BotScore.request_reasons(%{user_agent: @iphone, hosting: true}) ==
               ~w(hosting_network mobile_from_hosting)

      assert BotScore.request_reasons(%{user_agent: @chrome, hosting: true}) == [
               "hosting_network"
             ]

      assert BotScore.request_reasons(%{user_agent: @iphone, hosting: false}) == []
    end
  end

  describe "signal_reasons/2" do
    test "a device that matches its User-Agent has none" do
      signals = %{"plat" => "Win32", "gr" => "ANGLE (NVIDIA)", "sw" => 1920, "langs" => ["en"]}
      assert BotScore.signal_reasons(signals, @chrome) == []
    end

    test "a Linux machine calling itself an iPhone, drawing in software, with no screen" do
      signals = %{
        "plat" => "Linux x86_64",
        "gr" => "Google SwiftShader",
        "sw" => 0,
        "langs" => [],
        "tp" => 0
      }

      assert BotScore.signal_reasons(signals, @iphone) ==
               ~w(platform_mismatch software_renderer no_screen no_languages touch_mismatch)
    end

    test "an iPad asking for the desktop site isn't a mismatch" do
      mac =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15"

      assert BotScore.signal_reasons(%{"plat" => "MacIntel", "tp" => 5}, mac) == []
    end

    test "a measurement that is missing says nothing" do
      assert BotScore.signal_reasons(%{}, @iphone) == []
    end
  end

  describe "score, level and merge" do
    test "the score is the sum of the weights, and reads as a level" do
      assert BotScore.score([]) == 0
      assert BotScore.score(["hosting_network", "mobile_from_hosting"]) == 70
      assert BotScore.score(["hosting_network", "hosting_network"]) == 40
      assert BotScore.score(["something new"]) == 0

      assert BotScore.level(70) == :likely
      assert BotScore.level(40) == :suspicious
      assert BotScore.level(25) == :low
      assert BotScore.percent(190) == 100
    end

    test "a source replaces its own reasons and leaves the others'" do
      current = ["rate", "no_accept", "no_screen"]

      assert BotScore.merge(current, :request, []) == ["rate", "no_screen"]

      assert BotScore.merge(current, :signals, ["no_languages"]) == [
               "rate",
               "no_languages",
               "no_accept"
             ]

      # A source can't report a reason that isn't its own.
      assert BotScore.merge([], :signals, ["rate"]) == []
    end

    test "every reason has a label in each language, not its raw key" do
      for locale <- ~w(en et ru uk), reason <- Map.keys(BotScore.weights()) do
        label =
          Gettext.with_locale(PhoenixKitWebAnalytics.Gettext, locale, fn ->
            Components.bot_reason_label(reason)
          end)

        assert is_binary(label) and label != "" and label != reason,
               "#{reason} has no label in #{locale}"
      end
    end

    test "what forgetting a kind of data takes back is that source's own" do
      for {kind, source} <- [headers: :request, network: :request, signals: :signals] do
        assert BotScore.derived_from(kind) != []
        assert BotScore.derived_from(kind) -- BotScore.owned(source) == []
      end

      assert BotScore.derived_from(:signals) == BotScore.owned(:signals)
      assert BotScore.derived_from(:ip) == []
      assert BotScore.derived_from(:user_agent) == []
    end

    test "every reason belongs to exactly one source" do
      owned = Enum.flat_map([:request, :signals, :behaviour], &BotScore.owned/1)
      assert Enum.sort(owned) == Enum.sort(Map.keys(BotScore.weights()))
    end
  end

  describe "Signals.clean/1" do
    test "keeps known measurements of the right shape, zeroes and falses included" do
      assert Signals.clean(%{
               "tz" => " Europe/Tallinn ",
               "tp" => 0,
               "wd" => false,
               "dpr" => 2.5,
               "langs" => ["et", 7, "en"],
               "fonts" => []
             }) == %{
               "tz" => "Europe/Tallinn",
               "tp" => 0,
               "wd" => false,
               "dpr" => 2.5,
               "langs" => ["et", "en"],
               "fonts" => []
             }
    end

    test "drops unknown keys, wrong types and values out of range" do
      assert Signals.clean(%{
               "password" => "hunter2",
               "hc" => "8",
               "sw" => 9_999_999,
               "wd" => "true",
               "tz" => %{"nested" => true},
               "cv" => <<0xFF, 0xFE>>
             }) == nil

      assert Signals.clean("not a map") == nil
    end

    test "long values are cut" do
      assert %{"gr" => renderer} = Signals.clean(%{"gr" => String.duplicate("x", 5_000)})
      assert byte_size(renderer) == 200
    end
  end

  describe "Signals.device_hash/2" do
    @device %{
      "cv" => "a1b2c3d4",
      "gr" => "ANGLE (Apple, M2)",
      "sw" => 1728,
      "tz" => "Europe/Tallinn"
    }

    test "the same device has the same hash, whatever its window" do
      hash = Signals.device_hash(@device, "salt")

      assert hash =~ ~r/\A[0-9a-f]{32}\z/

      assert Signals.device_hash(Map.merge(@device, %{"iw" => 800, "dark" => true}), "salt") ==
               hash
    end

    test "another device, or another salt, has another" do
      hash = Signals.device_hash(@device, "salt")

      refute Signals.device_hash(%{@device | "cv" => "ffffffff"}, "salt") == hash
      refute Signals.device_hash(@device, "another salt") == hash
    end

    test "none without something that tells devices apart" do
      assert Signals.device_hash(%{"sw" => 1920, "tz" => "Europe/Tallinn"}, "salt") == nil
      assert Signals.device_hash(nil, "salt") == nil
    end
  end
end
