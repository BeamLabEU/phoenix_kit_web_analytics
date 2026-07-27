defmodule PhoenixKitWebAnalytics.UserAgentTest do
  use ExUnit.Case, async: true

  alias PhoenixKitWebAnalytics.UserAgent

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @safari_mac "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1"
  @ipad "Mozilla/5.0 (iPad; CPU OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/604.1"
  @android_phone "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
  @android_tablet "Mozilla/5.0 (Linux; Android 13; SM-X700) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @firefox "Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0"
  @edge "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"

  describe "browser detection" do
    test "Chrome on Windows" do
      parsed = UserAgent.parse(@chrome)

      assert parsed.browser == "Chrome"
      assert parsed.browser_version == "120.0.0.0"
      assert parsed.os == "Windows"
      assert parsed.device_type == "desktop"
      refute parsed.bot?
    end

    test "Safari is not reported as Chrome" do
      assert UserAgent.parse(@safari_mac).browser == "Safari"
    end

    test "Firefox" do
      parsed = UserAgent.parse(@firefox)

      assert parsed.browser == "Firefox"
      assert parsed.browser_version == "121.0"
      assert parsed.os == "Linux"
    end

    test "Edge wins over the Chrome token it also carries" do
      assert UserAgent.parse(@edge).browser == "Edge"
    end
  end

  describe "operating systems" do
    test "macOS version underscores are normalized to dots" do
      parsed = UserAgent.parse(@safari_mac)

      assert parsed.os == "macOS"
      assert parsed.os_version == "10.15.7"
    end

    test "iOS" do
      parsed = UserAgent.parse(@iphone)

      assert parsed.os == "iOS"
      assert parsed.os_version == "17.2"
    end

    test "Android" do
      assert UserAgent.parse(@android_phone).os == "Android"
    end
  end

  describe "device classification" do
    test "iPhone is mobile, iPad is tablet" do
      assert UserAgent.parse(@iphone).device_type == "mobile"
      assert UserAgent.parse(@ipad).device_type == "tablet"
    end

    test "Android with the Mobile token is a phone, without it a tablet" do
      assert UserAgent.parse(@android_phone).device_type == "mobile"
      assert UserAgent.parse(@android_tablet).device_type == "tablet"
    end
  end

  describe "bot detection" do
    test "recognises crawlers, tools, and monitors" do
      bots = [
        "Googlebot/2.1 (+http://www.google.com/bot.html)",
        "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)",
        "curl/8.4.0",
        "python-requests/2.31.0",
        "Mozilla/5.0 (compatible; AhrefsBot/7.0)",
        "facebookexternalhit/1.1",
        "Mozilla/5.0 (X11; Linux x86_64) HeadlessChrome/120.0.0.0"
      ]

      for ua <- bots do
        assert UserAgent.bot?(ua), "expected #{ua} to be detected as a bot"
        assert UserAgent.parse(ua).device_type == "bot"
      end
    end

    test "real browsers are not flagged" do
      for ua <- [@chrome, @safari_mac, @iphone, @firefox, @edge, @android_phone] do
        refute UserAgent.bot?(ua), "expected #{ua} not to be detected as a bot"
      end
    end
  end

  describe "degenerate input" do
    test "nil, empty, and unparseable strings never raise" do
      for ua <- [nil, "", "???", 12_345, %{}] do
        parsed = UserAgent.parse(ua)

        assert is_map(parsed)
        assert is_binary(parsed.browser)
        assert is_boolean(parsed.bot?)
      end
    end

    test "a missing User-Agent is not assumed to be a bot" do
      refute UserAgent.parse(nil).bot?
      refute UserAgent.bot?(nil)
    end
  end
end
