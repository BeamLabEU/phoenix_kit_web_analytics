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
end
