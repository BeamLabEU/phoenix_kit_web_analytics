defmodule PhoenixKitWebAnalytics.Web.BeaconPayloadTest do
  @moduledoc """
  The trust boundary for the public collection endpoints: what an untrusted
  payload can and cannot put into an event.
  """

  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2, conn: 3]

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
end
