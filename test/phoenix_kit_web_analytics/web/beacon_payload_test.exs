defmodule PhoenixKitWebAnalytics.Web.BeaconPayloadTest do
  @moduledoc """
  The trust boundary for the public collection endpoints: what an untrusted
  payload can and cannot put into an event.
  """

  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]

  doctest PhoenixKitWebAnalytics.Web.BeaconPayload

  alias PhoenixKitWebAnalytics.Web.BeaconPayload

  defp request(headers \\ []) do
    Enum.reduce(headers, conn(:post, "/phoenix-kit/analytics/event", %{}), fn {name, value},
                                                                              conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
  end

  describe "identity and origin cannot be spoofed" do
    test "site is the request host, not anything in the payload" do
      hit = BeaconPayload.to_hit(request(), %{"p" => "https://evil.example/steal", "site" => "x"})

      assert hit.site == "www.example.com"
      refute hit.site == "evil.example"
    end

    test "only the path survives from a client-sent URL" do
      hit = BeaconPayload.to_hit(request(), %{"p" => "https://evil.example/steal?a=1#frag"})

      assert hit.path == "/steal"
    end

    test "user_uuid is never read from the payload" do
      hit = BeaconPayload.to_hit(request(), %{"user_uuid" => "018e-fake", "n" => "signup"})

      assert hit.user_uuid == nil
    end
  end

  describe "event type" do
    test "a named payload is a custom event" do
      hit = BeaconPayload.to_hit(request(), %{"n" => "signup"})

      assert hit.event_type == "event"
      assert hit.event_name == "signup"
    end

    test "an unnamed payload is a page view" do
      hit = BeaconPayload.to_hit(request(), %{"p" => "/pricing"})

      assert hit.event_type == "pageview"
      assert hit.event_name == nil
    end

    test "an explicit pageview marker wins over a name" do
      assert BeaconPayload.event_type(%{"e" => "pageview", "n" => "signup"}) == "pageview"
    end
  end

  describe "content caps" do
    test "event names are truncated, not rejected" do
      hit = BeaconPayload.to_hit(request(), %{"n" => String.duplicate("x", 5_000)})

      assert byte_size(hit.event_name) == 120
    end

    test "properties are capped by count and by value size" do
      props = Map.new(1..50, fn i -> {"key#{i}", String.duplicate("v", 1_000)} end)

      capped = BeaconPayload.props(props)

      assert map_size(capped) == 20
      assert Enum.all?(Map.values(capped), &(byte_size(&1) == 200))
    end

    test "non-string property values survive with their type" do
      capped = BeaconPayload.props(%{"count" => 3, "ok" => true, "missing" => nil})

      assert capped["count"] == 3
      assert capped["ok"] == true
      assert capped["missing"] == nil
    end

    test "non-map properties become an empty map" do
      for value <- ["string", 42, nil, [1, 2]] do
        assert BeaconPayload.props(value) == %{}
      end
    end
  end

  describe "campaign parameters" do
    test "are read from the client URL's query string" do
      hit =
        BeaconPayload.to_hit(request(), %{"p" => "/landing?utm_source=hn&utm_campaign=launch"})

      assert hit.query_params["utm_source"] == "hn"
      assert hit.query_params["utm_campaign"] == "launch"
    end

    test "unrelated query parameters are dropped" do
      hit = BeaconPayload.to_hit(request(), %{"p" => "/reset?token=secret&utm_source=hn"})

      refute Map.has_key?(hit.query_params, "token")
      assert map_size(hit.query_params) == 1
    end
  end

  describe "client headers" do
    test "user agent and language are read from the request" do
      hit =
        [{"user-agent", "Mozilla/5.0"}, {"accept-language", "et-EE,et;q=0.9"}]
        |> request()
        |> BeaconPayload.to_hit(%{"p" => "/"})

      assert hit.user_agent == "Mozilla/5.0"
      assert hit.language == "et-EE,et;q=0.9"
    end

    test "missing headers become nil rather than empty strings" do
      hit = BeaconPayload.to_hit(request(), %{"p" => "/"})

      assert hit.user_agent == nil
      assert hit.language == nil
    end
  end

  describe "degenerate payloads" do
    test "never raise" do
      for params <- [%{}, %{"n" => ""}, %{"p" => "not a url"}, %{"p" => 42}, "not a map", nil] do
        hit = BeaconPayload.to_hit(request(), params)

        assert is_binary(hit.path)
        assert hit.event_type in ["pageview", "event"]
      end
    end
  end

  describe "kind/1" do
    test "maps every e value" do
      assert BeaconPayload.kind(%{"e" => "pageview"}) == :pageview
      assert BeaconPayload.kind(%{"e" => "click"}) == :click
      assert BeaconPayload.kind(%{"e" => "scroll"}) == :scroll
      assert BeaconPayload.kind(%{"e" => "leave"}) == :leave
    end

    test "an event is recognised by a non-empty name" do
      assert BeaconPayload.kind(%{"e" => "event", "n" => "signup"}) == :event
      assert BeaconPayload.kind(%{"n" => "signup"}) == :event
    end

    test "anything else is a page view" do
      for params <- [
            %{},
            %{"e" => "event"},
            %{"e" => "event", "n" => ""},
            %{"e" => "purchase"},
            %{"e" => "CLICK"},
            %{"n" => 42},
            %{"e" => nil}
          ] do
        assert BeaconPayload.kind(params) == :pageview, inspect(params)
      end
    end

    test "a client-script kind wins over a name" do
      assert BeaconPayload.kind(%{"e" => "click", "n" => "signup"}) == :click
      assert BeaconPayload.kind(%{"e" => "leave", "n" => "signup"}) == :leave
    end
  end

  describe "client_script_hit?/1" do
    test "is true only for clicks, scroll and leaves" do
      for e <- ~w(click scroll leave) do
        assert BeaconPayload.client_script_hit?(%{"e" => e})
      end

      refute BeaconPayload.client_script_hit?(%{"e" => "pageview"})
      refute BeaconPayload.client_script_hit?(%{"n" => "signup"})
      refute BeaconPayload.client_script_hit?(%{"e" => "event", "n" => "signup"})
      refute BeaconPayload.client_script_hit?(%{})
    end
  end

  describe "click payloads" do
    test "become an interaction named by the click kind" do
      for kind <- ~w(click outbound download contact) do
        hit = BeaconPayload.to_hit(request(), %{"e" => "click", "k" => kind, "x" => "a.com/b"})

        assert hit.event_type == "interaction"
        assert hit.event_name == kind
        assert hit.target == "a.com/b"
        assert hit.metadata == %{"source" => "client_script"}
      end
    end

    test "an unknown or missing kind is a plain click" do
      for params <- [
            %{"e" => "click", "k" => "exfiltrate"},
            %{"e" => "click", "k" => 1},
            %{"e" => "click"}
          ] do
        assert BeaconPayload.to_hit(request(), params).event_name == "click"
      end
    end

    test "the target is truncated to 512 bytes without splitting a character" do
      hit =
        BeaconPayload.to_hit(request(), %{
          "e" => "click",
          "x" => "a" <> String.duplicate("€", 1_000)
        })

      assert byte_size(hit.target) <= 512
      assert byte_size(hit.target) >= 510
      assert String.valid?(hit.target)
    end

    test "a non-string target is nil" do
      assert BeaconPayload.to_hit(request(), %{"e" => "click", "x" => %{"a" => 1}}).target == nil
    end
  end

  describe "scroll payloads" do
    test "become a scroll interaction with a clamped depth" do
      hit = BeaconPayload.to_hit(request(), %{"e" => "scroll", "sd" => 55})

      assert hit.event_type == "interaction"
      assert hit.event_name == "scroll"
      assert hit.scroll_depth == 55

      assert BeaconPayload.to_hit(request(), %{"e" => "scroll", "sd" => 150}).scroll_depth == 100
      assert BeaconPayload.to_hit(request(), %{"e" => "scroll", "sd" => -3}).scroll_depth == 0
      assert BeaconPayload.to_hit(request(), %{"e" => "scroll", "sd" => 55.6}).scroll_depth == 56
    end

    test "a non-numeric depth is nil" do
      for sd <- ["50", nil, [1]] do
        assert BeaconPayload.to_hit(request(), %{"e" => "scroll", "sd" => sd}).scroll_depth == nil
      end
    end
  end

  describe "leave payloads" do
    @four_hours 4 * 60 * 60 * 1000

    test "carry engaged time, scroll depth and an anchor at the page's open time" do
      hit = BeaconPayload.to_hit(request(), %{"e" => "leave", "ms" => 60_000, "sd" => 70})

      assert hit.event_type == "leave"
      assert hit.engaged_ms == 60_000
      assert hit.scroll_depth == 70
      assert hit.metadata == %{"source" => "client_script"}
      assert DateTime.diff(hit.inserted_at, hit.session_anchor, :millisecond) == 60_000
      assert DateTime.diff(DateTime.utc_now(), hit.inserted_at, :second) in 0..5
    end

    test "engaged time is clamped to four hours, and the anchor with it" do
      hit = BeaconPayload.to_hit(request(), %{"e" => "leave", "ms" => 99_999_999_999})

      assert hit.engaged_ms == @four_hours
      assert DateTime.diff(hit.inserted_at, hit.session_anchor, :millisecond) == @four_hours
    end

    test "negative time is zero and a float is rounded" do
      assert BeaconPayload.to_hit(request(), %{"e" => "leave", "ms" => -500}).engaged_ms == 0
      assert BeaconPayload.to_hit(request(), %{"e" => "leave", "ms" => 1234.6}).engaged_ms == 1235
    end

    test "missing time leaves engaged_ms nil and anchors at now" do
      hit = BeaconPayload.to_hit(request(), %{"e" => "leave", "ms" => "lots", "sd" => 250})

      assert hit.engaged_ms == nil
      assert hit.scroll_depth == 100
      assert hit.session_anchor == hit.inserted_at
    end
  end

  describe "every hit shape" do
    @payloads [
      %{"e" => "pageview", "p" => "/"},
      %{"n" => "signup"},
      %{"e" => "click", "k" => "outbound"},
      %{"e" => "scroll", "sd" => 10},
      %{"e" => "leave", "ms" => 10}
    ]

    test "carries :event_name and :user_uuid keys" do
      for params <- @payloads do
        hit = BeaconPayload.to_hit(request(), params)

        assert Map.has_key?(hit, :event_name), inspect(params)
        assert Map.has_key?(hit, :user_uuid), inspect(params)
      end
    end

    test "user_uuid is nil even when the payload sends one" do
      uuid = "018e0000-0000-7000-8000-000000000000"

      for params <- @payloads,
          spoof <- [%{"user_uuid" => uuid}, %{"u" => uuid}, %{"user" => %{"uuid" => uuid}}] do
        hit = BeaconPayload.to_hit(request(), Map.merge(params, spoof))

        assert hit.user_uuid == nil, inspect(params)
      end
    end
  end
end
