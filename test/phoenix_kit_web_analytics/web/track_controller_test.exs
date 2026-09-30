defmodule PhoenixKitWebAnalytics.Web.TrackControllerTest do
  use PhoenixKitWebAnalytics.LiveCase, async: false

  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Test.Repo

  @beacon_path "/phoenix-kit/analytics/event"
  @pixel_path "/phoenix-kit/analytics/pixel.gif"

  describe "with the beacon disabled (the default)" do
    test "accepts the request but stores nothing", %{conn: conn} do
      conn = post(conn, @beacon_path, %{"n" => "signup", "p" => "/pricing"})

      assert conn.status == 204
      assert Repo.aggregate(Event, :count) == 0
    end

    test "the pixel still returns a GIF", %{conn: conn} do
      conn = get(conn, @pixel_path)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "image/gif"
      assert Repo.aggregate(Event, :count) == 0
    end
  end

  describe "with the beacon enabled" do
    setup do
      enable_tracking(%{"web_analytics_beacon_enabled" => "true"})
      :ok
    end

    test "the pixel is never cached", %{conn: conn} do
      conn = get(conn, @pixel_path, %{"p" => "/cached-page"})

      assert get_resp_header(conn, "cache-control") |> List.first() =~ "no-store"
    end

    test "the response body is a valid 1x1 GIF", %{conn: conn} do
      conn = get(conn, @pixel_path)

      assert <<"GIF89a", _rest::binary>> = conn.resp_body
    end

    test "an event payload responds 204 with no body", %{conn: conn} do
      conn = post(conn, @beacon_path, %{"n" => "signup", "p" => "/pricing"})

      assert conn.status == 204
      assert conn.resp_body == ""
    end
  end

  describe "robustness" do
    setup do
      enable_tracking(%{"web_analytics_beacon_enabled" => "true"})
      :ok
    end

    # What a payload may and may not influence is enforced (and tested) in
    # PhoenixKitWebAnalytics.Web.BeaconPayload — the controller only has to
    # survive whatever it is sent.
    test "malformed payloads are accepted quietly rather than crashing", %{conn: conn} do
      for params <- [
            %{},
            %{"n" => ""},
            %{"p" => "not a url"},
            %{"props" => "not a map"},
            %{"n" => String.duplicate("x", 5_000)}
          ] do
        assert post(conn, @beacon_path, params).status == 204
      end
    end
  end

  defp beacon_text(conn, body) do
    conn
    |> put_req_header("content-type", "text/plain;charset=UTF-8")
    |> post(@beacon_path, body)
  end

  defp events, do: Repo.all(Event)

  describe "text/plain bodies (navigator.sendBeacon)" do
    setup do
      enable_tracking(%{"web_analytics_beacon_enabled" => "true"})
      :ok
    end

    test "a JSON body sent as text/plain is decoded and stored", %{conn: conn} do
      conn = beacon_text(conn, ~s({"e":"event","n":"signup","p":"/pricing"}))

      assert conn.status == 204

      assert [%Event{event_type: "event", event_name: "signup", path: "/pricing"}] = events()
    end

    test "a text/plain body that isn't a JSON object is never stored as an event", %{
      conn: conn
    } do
      for body <- ["", "not json", "[1,2,3]", ~s("signup"), "{broken"] do
        assert beacon_text(conn, body).status == 204
      end

      refute Enum.any?(events(), &(&1.event_type == "event"))
    end

    test "a body over 16 KB is not read: 204, and its event is not stored", %{conn: conn} do
      body = oversized_body()

      assert byte_size(body) > 16_384
      assert beacon_text(conn, body).status == 204
      refute Enum.any?(events(), &(&1.event_name == "oversized"))
    end

    # Regression: an empty or undecodable body used to fall back to params %{},
    # which BeaconPayload.kind/1 reads as a page view — junk POSTs counted as
    # views of "/".
    test "an empty, undecodable or oversized body stores nothing at all", %{conn: conn} do
      for body <- ["", "not json", "[1,2,3]", "{broken", oversized_body()] do
        assert beacon_text(conn, body).status == 204
      end

      assert events() == []
    end
  end

  defp oversized_body do
    Jason.encode!(%{
      "e" => "event",
      "n" => "oversized",
      "p" => "/big",
      "props" => %{"pad" => String.duplicate("x", 20_000)}
    })
  end

  describe "which switch accepts which hit" do
    @click %{"e" => "click", "k" => "outbound", "x" => "example.org/x", "p" => "/pricing"}
    @leave %{"e" => "leave", "ms" => 5_000, "sd" => 40, "p" => "/pricing"}
    @scroll %{"e" => "scroll", "sd" => 60, "p" => "/pricing"}
    @pageview %{"e" => "pageview", "p" => "/pricing"}
    @custom %{"n" => "signup", "p" => "/pricing"}

    test "client-script hits are dropped with only the beacon on", %{conn: conn} do
      enable_tracking(%{"web_analytics_beacon_enabled" => "true"})

      for params <- [@click, @leave, @scroll] do
        assert post(conn, @beacon_path, params).status == 204
      end

      assert events() == []
    end

    test "client-script hits are stored with the client script on", %{conn: conn} do
      enable_tracking(%{"web_analytics_client_script" => "true"})

      for params <- [@click, @leave, @scroll] do
        assert post(conn, @beacon_path, params).status == 204
      end

      stored = events() |> Enum.map(&{&1.event_type, &1.event_name}) |> Enum.sort()

      assert stored == [{"interaction", "outbound"}, {"interaction", "scroll"}, {"leave", nil}]

      leave = Enum.find(events(), &(&1.event_type == "leave"))
      assert leave.engaged_ms == 5_000
      assert leave.scroll_depth == 40
    end

    test "page views need the beacon switch", %{conn: conn} do
      enable_tracking(%{"web_analytics_client_script" => "true"})
      post(conn, @beacon_path, @pageview)
      assert events() == []

      enable_tracking(%{"web_analytics_beacon_enabled" => "true"})
      post(conn, @beacon_path, @pageview)
      assert [%Event{event_type: "pageview", path: "/pricing"}] = events()
    end

    test "custom events are accepted with either switch", %{conn: conn} do
      enable_tracking(%{"web_analytics_client_script" => "true"})
      post(conn, @beacon_path, @custom)
      assert [%Event{event_name: "signup"}] = events()

      Repo.delete_all(Event)

      enable_tracking(%{
        "web_analytics_client_script" => "false",
        "web_analytics_beacon_enabled" => "true"
      })

      post(conn, @beacon_path, @custom)
      assert [%Event{event_name: "signup"}] = events()
    end

    test "nothing is stored with tracking itself off", %{conn: conn} do
      PhoenixKit.Settings.update_setting_with_module(
        "web_analytics_beacon_enabled",
        "true",
        "web_analytics"
      )

      clear_settings_cache()

      post(conn, @beacon_path, @custom)
      assert events() == []
    end
  end

  describe "opt-out signals" do
    setup do
      enable_tracking(%{"web_analytics_beacon_enabled" => "true"})
      :ok
    end

    test "DNT: 1 stores nothing", %{conn: conn} do
      conn = conn |> put_req_header("dnt", "1") |> post(@beacon_path, %{"n" => "signup"})

      assert conn.status == 204
      assert events() == []
    end

    test "Sec-GPC: 1 stores nothing, for the pixel too", %{conn: conn} do
      assert conn
             |> put_req_header("sec-gpc", "1")
             |> post(@beacon_path, %{"n" => "signup"})
             |> Map.fetch!(:status) == 204

      pixel = build_conn() |> put_req_header("sec-gpc", "1") |> get(@pixel_path, %{"p" => "/a"})

      assert pixel.status == 200
      assert <<"GIF89a", _::binary>> = pixel.resp_body
      assert events() == []
    end

    test "DNT: 0 is not an opt-out", %{conn: conn} do
      conn |> put_req_header("dnt", "0") |> post(@beacon_path, %{"n" => "signup"})

      assert [%Event{event_name: "signup"}] = events()
    end

    test "the headers are ignored when respect_dnt is off", %{conn: conn} do
      enable_tracking(%{
        "web_analytics_beacon_enabled" => "true",
        "web_analytics_respect_dnt" => "false"
      })

      conn |> put_req_header("dnt", "1") |> post(@beacon_path, %{"n" => "signup"})

      assert [%Event{event_name: "signup"}] = events()
    end
  end

  describe "path exclusions" do
    setup do
      enable_tracking(%{"web_analytics_beacon_enabled" => "true"})
      :ok
    end

    test "a hit on an excluded path is not stored", %{conn: conn} do
      assert post(conn, @beacon_path, %{"n" => "signup", "p" => "/admin/x"}).status == 204

      assert get(build_conn(), @pixel_path, %{"p" => "https://www.example.com/admin"}).status ==
               200

      assert events() == []
    end

    test "a hit on a non-excluded path is", %{conn: conn} do
      post(conn, @beacon_path, %{"n" => "signup", "p" => "/blog/admin"})

      assert [%Event{path: "/blog/admin"}] = events()
    end
  end

  describe "pixel path from the Referer" do
    setup do
      enable_tracking(%{"web_analytics_beacon_enabled" => "true"})
      :ok
    end

    test "a same-origin Referer supplies the path when p is missing", %{conn: conn} do
      assert conn.host == "www.example.com"

      conn =
        conn
        |> put_req_header("referer", "http://www.example.com/blog/post?token=abc")
        |> get(@pixel_path)

      assert conn.status == 200
      assert [%Event{event_type: "pageview", path: "/blog/post"}] = events()
    end

    test "the same host without www. counts as same-origin", %{conn: conn} do
      conn |> put_req_header("referer", "https://EXAMPLE.com/docs") |> get(@pixel_path)

      assert [%Event{path: "/docs"}] = events()
    end

    test "a cross-origin Referer is not trusted for the path", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "https://evil.example/phish")
        |> get(@pixel_path)

      assert conn.status == 200
      assert [%Event{path: "/"}] = events()
    end

    test "an explicit p wins over the Referer", %{conn: conn} do
      conn
      |> put_req_header("referer", "http://www.example.com/from-referer")
      |> get(@pixel_path, %{"p" => "/explicit"})

      assert [%Event{path: "/explicit"}] = events()
    end
  end
end
