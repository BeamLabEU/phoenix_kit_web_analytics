defmodule PhoenixKitWebAnalytics.TrackingTest do
  # Not async: the X-Forwarded-For tests flip application env that every
  # client_ip/1 caller reads.
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 2]

  alias PhoenixKitWebAnalytics.Tracking

  describe "utm_params/1" do
    test "keeps only the campaign parameters" do
      query =
        "utm_source=hn&utm_medium=social&utm_campaign=launch&utm_term=x&utm_content=y" <>
          "&token=secret&email=a%40b.c"

      assert Tracking.utm_params(query) == %{
               "utm_source" => "hn",
               "utm_medium" => "social",
               "utm_campaign" => "launch",
               "utm_term" => "x",
               "utm_content" => "y"
             }
    end

    test "decodes percent-encoding and plus signs" do
      assert Tracking.utm_params("utm_campaign=spring%20sale&utm_source=a+b") == %{
               "utm_campaign" => "spring sale",
               "utm_source" => "a b"
             }
    end

    test "nil, empty and utm-free queries give an empty map" do
      assert Tracking.utm_params(nil) == %{}
      assert Tracking.utm_params("") == %{}
      assert Tracking.utm_params("page=2&sort=asc") == %{}
    end

    test "bad percent-encoding does not raise or leak other keys" do
      result = Tracking.utm_params("utm_source=%ZZ&utm_medium=%&token=%E0%A4%A")

      assert Map.keys(result) -- Tracking.utm_param_names() == []
      refute Map.has_key?(result, "token")

      # A malformed sibling doesn't cost the valid campaign parameter.
      assert Tracking.utm_params("utm_source=hn&token=%ZZ") == %{"utm_source" => "hn"}
    end

    test "utm_param_names/0 lists exactly the five campaign keys" do
      assert Enum.sort(Tracking.utm_param_names()) ==
               ~w(utm_campaign utm_content utm_medium utm_source utm_term)
    end
  end

  describe "campaign_params/1" do
    test "keeps campaign parameters and ad-click identifiers, drops the rest" do
      query =
        "utm_source=google&utm_medium=cpc&gclid=EAIaIQobCh&msclkid=abc" <>
          "&session=secret&q=garden+chairs"

      assert Tracking.campaign_params(query) == %{
               "utm_source" => "google",
               "utm_medium" => "cpc",
               "gclid" => "EAIaIQobCh",
               "msclkid" => "abc"
             }
    end

    test "an auto-tagged ad click with no utm parameters is still kept" do
      assert Tracking.campaign_params("gclid=Cj0KCQjw") == %{"gclid" => "Cj0KCQjw"}
    end

    test "nil, empty and parameter-free queries give an empty map" do
      assert Tracking.campaign_params(nil) == %{}
      assert Tracking.campaign_params("") == %{}
      assert Tracking.campaign_params("page=2&sort=asc") == %{}
    end

    test "bad percent-encoding does not raise or leak other keys" do
      result = Tracking.campaign_params("gclid=%ZZ&token=%E0%A4%A")

      assert Map.keys(result) -- Tracking.campaign_param_names() == []
      refute Map.has_key?(result, "token")
      assert Tracking.campaign_params("gclid=abc&token=%ZZ") == %{"gclid" => "abc"}
    end

    test "campaign_param_names/0 is the campaign keys plus the click ones" do
      assert Tracking.campaign_param_names() ==
               Tracking.utm_param_names() ++ Tracking.click_param_names()
    end

    test "click_source/1 maps an identifier to its platform" do
      assert Tracking.click_source("gclid") == "Google"
      assert Tracking.click_source("gbraid") == "Google"
      assert Tracking.click_source("wbraid") == "Google"
      assert Tracking.click_source("msclkid") == "Bing"
      assert Tracking.click_source("fbclid") == "Facebook"
      assert Tracking.click_source("utm_source") == nil
    end

    test "paid_click?/1 is true for ad-only identifiers, false for fbclid" do
      assert Tracking.paid_click?("gclid")
      assert Tracking.paid_click?("msclkid")
      refute Tracking.paid_click?("fbclid")
      refute Tracking.paid_click?("utm_source")
    end

    test "every click parameter name has a platform" do
      for name <- Tracking.click_param_names() do
        assert Tracking.click_source(name), "no platform for #{name}"
      end
    end
  end

  describe "truncate_utf8/2" do
    test "strings within the limit are returned unchanged" do
      assert Tracking.truncate_utf8("hello", 5) == "hello"
      assert Tracking.truncate_utf8("hello", 100) == "hello"
      assert Tracking.truncate_utf8("", 0) == ""
      assert Tracking.truncate_utf8("äö", 4) == "äö"
    end

    test "ASCII is cut to exactly max bytes" do
      assert Tracking.truncate_utf8("abcdef", 3) == "abc"
      assert Tracking.truncate_utf8("abc", 0) == ""
    end

    test "never splits a two-byte character" do
      assert Tracking.truncate_utf8("aä", 2) == "a"
      assert Tracking.truncate_utf8("aä", 3) == "aä"
    end

    test "never splits a three-byte character at either continuation byte" do
      euro = "€"
      assert byte_size(euro) == 3

      assert Tracking.truncate_utf8("€€", 4) == "€"
      assert Tracking.truncate_utf8("€€", 5) == "€"
      assert Tracking.truncate_utf8("€€", 6) == "€€"
      assert Tracking.truncate_utf8("€", 2) == ""
    end

    test "never splits a four-byte character at any continuation byte" do
      for max <- 4..7 do
        assert Tracking.truncate_utf8("😀😀", max) == "😀"
      end

      for max <- 1..3 do
        assert Tracking.truncate_utf8("😀", max) == ""
      end
    end

    test "a long mixed string always comes back valid and within the limit" do
      value = String.duplicate("aä€😀", 200)

      for max <- 500..520 do
        truncated = Tracking.truncate_utf8(value, max)

        assert String.valid?(truncated)
        assert byte_size(truncated) <= max
        # Drops at most one partial character (≤ 3 bytes).
        assert byte_size(truncated) >= max - 3
        assert String.starts_with?(value, truncated)
      end
    end
  end

  describe "client_ip/1" do
    setup do
      previous = Application.fetch_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for)

      on_exit(fn ->
        case previous do
          {:ok, value} ->
            Application.put_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for, value)

          :error ->
            Application.delete_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for)
        end
      end)

      :ok
    end

    defp with_xff(value) do
      conn(:get, "/")
      |> Map.put(:remote_ip, {10, 0, 0, 1})
      |> Plug.Conn.put_req_header("x-forwarded-for", value)
    end

    test "uses remote_ip and ignores X-Forwarded-For by default" do
      Application.delete_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for)

      assert Tracking.client_ip(with_xff("203.0.113.9")) == {10, 0, 0, 1}
    end

    test "uses the first X-Forwarded-For entry when trusted" do
      Application.put_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for, true)

      assert Tracking.client_ip(with_xff("203.0.113.9, 10.0.0.2, 10.0.0.3")) ==
               {203, 0, 113, 9}

      assert Tracking.client_ip(with_xff(" 2001:db8::1 ")) == {8193, 3512, 0, 0, 0, 0, 0, 1}
    end

    test "falls back to remote_ip on a garbage or missing header" do
      Application.put_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for, true)

      assert Tracking.client_ip(with_xff("not-an-ip, 203.0.113.9")) == {10, 0, 0, 1}
      assert Tracking.client_ip(with_xff("")) == {10, 0, 0, 1}

      bare = conn(:get, "/") |> Map.put(:remote_ip, {10, 0, 0, 1})
      assert Tracking.client_ip(bare) == {10, 0, 0, 1}
    end
  end

  describe "socket_ip/2" do
    setup do
      previous = Application.fetch_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for)

      on_exit(fn ->
        case previous do
          {:ok, value} ->
            Application.put_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for, value)

          :error ->
            Application.delete_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for)
        end
      end)

      :ok
    end

    @peer {10, 0, 0, 1}

    test "returns the peer address when forwarding isn't trusted" do
      Application.delete_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for)

      assert Tracking.socket_ip(@peer, [{"x-forwarded-for", "203.0.113.9"}]) == @peer
    end

    test "uses the first forwarded entry when trusted" do
      Application.put_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for, true)

      assert Tracking.socket_ip(@peer, [
               {"x-real-ip", "1.1.1.1"},
               {"x-forwarded-for", "203.0.113.9, 10.0.0.2"}
             ]) == {203, 0, 113, 9}
    end

    test "falls back to the peer on nil, missing or garbage headers" do
      Application.put_env(:phoenix_kit_web_analytics, :trust_x_forwarded_for, true)

      assert Tracking.socket_ip(@peer, nil) == @peer
      assert Tracking.socket_ip(@peer, []) == @peer
      assert Tracking.socket_ip(@peer, [{"x-forwarded-for", "garbage"}]) == @peer
    end
  end

  describe "current_user_uuid/1" do
    test "reads the current user assign" do
      assert Tracking.current_user_uuid(%{phoenix_kit_current_user: %{uuid: "u-1"}}) == "u-1"
    end

    test "reads the current scope assign" do
      assert Tracking.current_user_uuid(%{phoenix_kit_current_scope: %{user: %{uuid: "u-2"}}}) ==
               "u-2"
    end

    test "is nil for anonymous or unrelated assigns" do
      assert Tracking.current_user_uuid(%{}) == nil
      assert Tracking.current_user_uuid(%{phoenix_kit_current_user: nil}) == nil
      assert Tracking.current_user_uuid(%{phoenix_kit_current_scope: %{user: nil}}) == nil
      assert Tracking.current_user_uuid(%{current_user: %{uuid: "other"}}) == nil
    end
  end

  describe "dnt_session_key/0" do
    test "is a stable, namespaced string" do
      # The plug writes it and the LiveView hook reads it — possibly across a
      # deploy — so its value is part of the contract.
      assert Tracking.dnt_session_key() == "phoenix_kit_web_analytics_dnt"
      assert Tracking.dnt_session_key() == Tracking.dnt_session_key()
    end
  end
end
