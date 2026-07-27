defmodule PhoenixKitWebAnalytics.ReferrerTest do
  use ExUnit.Case, async: true

  doctest PhoenixKitWebAnalytics.Referrer

  alias PhoenixKitWebAnalytics.Referrer

  describe "classify/2" do
    test "no referrer is direct traffic" do
      assert Referrer.classify(nil, "myapp.com") == {nil, "none"}
      assert Referrer.classify("", "myapp.com") == {nil, "none"}
    end

    test "the site's own host is internal navigation, not a referral" do
      assert Referrer.classify("https://myapp.com/blog", "myapp.com") == {nil, "internal"}
      assert Referrer.classify("https://www.myapp.com/blog", "myapp.com") == {nil, "internal"}
      assert Referrer.classify("https://myapp.com/blog", "www.myapp.com") == {nil, "internal"}
    end

    test "search engines are organic" do
      assert Referrer.classify("https://www.google.com/search?q=x", "myapp.com") ==
               {"Google", "organic"}

      assert Referrer.classify("https://duckduckgo.com/", "myapp.com") ==
               {"DuckDuckGo", "organic"}

      assert {"Yandex", "organic"} = Referrer.classify("https://yandex.ru/search/", "myapp.com")
    end

    test "social networks are social" do
      assert {"Hacker News", "social"} =
               Referrer.classify("https://news.ycombinator.com/item?id=1", "myapp.com")

      assert {"Reddit", "social"} = Referrer.classify("https://www.reddit.com/r/elixir", "x.com")
      assert {"X (Twitter)", "social"} = Referrer.classify("https://t.co/abc", "myapp.com")
    end

    test "ambiguous single-letter hosts resolve to the right network" do
      assert {"X (Twitter)", "social"} = Referrer.classify("https://t.co/abc", "myapp.com")
      assert {"Telegram", "social"} = Referrer.classify("https://t.me/channel", "myapp.com")
    end

    test "webmail wins over the search engine sharing its domain" do
      assert {"Email", "email"} = Referrer.classify("https://mail.google.com/", "myapp.com")
    end

    test "unknown hosts are referrals labelled with the bare host" do
      assert Referrer.classify("https://www.example.com/page", "myapp.com") ==
               {"example.com", "referral"}
    end

    test "a lookalike domain is not credited to the real one" do
      assert {"notgoogle.com", "referral"} =
               Referrer.classify("https://notgoogle.com/x", "myapp.com")

      assert {"mybing.example", "referral"} =
               Referrer.classify("https://mybing.example/x", "myapp.com")
    end

    test "subdomains of a known source still resolve to it" do
      assert {"Google", "organic"} = Referrer.classify("https://news.google.com/", "myapp.com")
    end

    test "garbage input degrades to direct rather than raising" do
      for value <- ["not a url", "://", 42, %{}] do
        assert {_source, medium} = Referrer.classify(value, "myapp.com")
        assert medium in ["none", "referral"]
      end
    end
  end

  describe "host_of/1" do
    test "strips scheme, path, and a leading www., and downcases" do
      assert Referrer.host_of("https://WWW.Example.com/a/b?c=1") == "example.com"
      assert Referrer.host_of("http://sub.example.com") == "sub.example.com"
    end

    test "returns nil when there is no host" do
      assert Referrer.host_of("/relative/path") == nil
      assert Referrer.host_of(nil) == nil
    end
  end
end
