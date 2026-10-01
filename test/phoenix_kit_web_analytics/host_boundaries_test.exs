defmodule PhoenixKitWebAnalytics.HostBoundariesTest do
  @moduledoc """
  What the module hands a host and the host hands back: the beacon and pixel
  components, the client script's bundle entry, edge-resolved countries and
  the labels shown for stored client names.
  """

  use PhoenixKitWebAnalytics.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Web.Beacon
  alias PhoenixKitWebAnalytics.Web.Components

  describe "<.beacon /> and <.pixel />" do
    test "the beacon posts to the collection endpoint the router serves" do
      html = render_component(&Beacon.beacon/1, auto_pageview: false, nonce: "abc")

      assert html =~ ~s(data-phoenix-kit-analytics="/phoenix-kit/analytics/event")
      assert html =~ ~s(nonce="abc")
      assert html =~ ~s(data-auto-pageview="false")
    end

    test "the pixel names its page and busts caches when asked" do
      html = render_component(&Beacon.pixel/1, cache_buster: "42", path: "/pricing")

      assert html =~ "/phoenix-kit/analytics/pixel.gif?"
      assert html =~ "p=%2Fpricing"
      assert html =~ "cb=42"
    end
  end

  describe "js_sources/0" do
    test "points at a shipped file that defines the global and the player hook" do
      [%{app: app, file: file, global: global}] = PhoenixKitWebAnalytics.js_sources()
      source = File.read!(Path.join(:code.priv_dir(app), file))

      assert source =~ "window.#{global} = window.#{global} || {}"
      # The visit page mounts this hook by name.
      assert source =~ "window.#{global}.PhoenixKitWebAnalyticsReplay ="
    end
  end

  describe "a country resolved at the edge" do
    test "each supported CDN header becomes the hit's country" do
      enable_tracking()

      for {header, i} <-
            Enum.with_index(
              ~w(cf-ipcountry x-vercel-ip-country fastly-geo-country x-country-code)
            ) do
        Plug.Test.conn(:get, "/page-#{i}")
        |> Plug.Conn.put_req_header(
          "user-agent",
          "Mozilla/5.0 (Macintosh) Chrome/120.0 Safari/537.36"
        )
        |> Plug.Conn.put_req_header(header, "ee")
        |> PhoenixKitWebAnalytics.Plug.call(PhoenixKitWebAnalytics.Plug.init([]))
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, "")
      end

      # "XX" is Cloudflare's "unknown".
      Plug.Test.conn(:get, "/unknown")
      |> Plug.Conn.put_req_header(
        "user-agent",
        "Mozilla/5.0 (Macintosh) Chrome/120.0 Safari/537.36"
      )
      |> Plug.Conn.put_req_header("cf-ipcountry", "XX")
      |> PhoenixKitWebAnalytics.Plug.call(PhoenixKitWebAnalytics.Plug.init([]))
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, "")

      countries = Map.new(Repo.all(Event), &{&1.path, &1.country_code})
      assert Enum.all?(0..3, &(countries["/page-#{&1}"] == "EE"))
      assert countries["/unknown"] == nil
    end
  end

  describe "client names" do
    test "the parser's placeholders are translated, real names are not" do
      Gettext.with_locale(PhoenixKitWebAnalytics.Gettext, "et", fn ->
        refute Components.client_label("Unknown") == "Unknown"
        refute Components.client_label("Other") == "Other"
        assert Components.client_label("Chrome") == "Chrome"
        assert Components.client_label(nil) == nil
      end)
    end
  end
end
