defmodule PhoenixKitWebAnalytics.LiveHookTest do
  @moduledoc """
  `PhoenixKitWebAnalytics.LiveHook` driven through a real LiveView
  (`PhoenixKitWebAnalytics.Test.TrackedLive` at `/shop`): what it records on a
  page load, a live navigation, clicks, form submits and patches — and,
  as importantly, what it must not record.

  Hits are written inline (`async_tracking: false`), so every assertion reads
  the events table straight after the interaction.
  """

  use PhoenixKitWebAnalytics.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKitWebAnalytics.BotSignals
  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.LiveHook
  alias PhoenixKitWebAnalytics.LivePresence
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Test.Repo
  alias PhoenixKitWebAnalytics.Tracking
  alias PhoenixKitWebAnalytics.Visitor

  @ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36"
  @peer %{address: {1, 2, 3, 4}, port: 1, ssl_cert: nil}

  # What `Phoenix.LiveViewTest` hands the socket as connect_info: the map in
  # `conn.private[:live_view_connect_info]` when set.
  defp put_connect_info(conn, info),
    do: Plug.Conn.put_private(conn, :live_view_connect_info, Map.new(info))

  defp with_client(conn), do: put_connect_info(conn, peer_data: @peer, user_agent: @ua)

  defp events(type \\ nil) do
    query = from(e in Event, order_by: [asc: e.inserted_at])
    query = if type, do: where(query, [e], e.event_type == ^type), else: query
    Repo.all(query)
  end

  describe "page views" do
    setup do
      enable_tracking()
    end

    test "a page load records no page view from the hook (the plug owns it)", %{conn: conn} do
      {:ok, _view, _html} = conn |> with_client() |> live("/shop")

      assert events("pageview") == []
    end

    test "a live navigation records one page view, referred by the live referer",
         %{conn: conn} do
      {:ok, _view, _html} =
        conn
        |> with_client()
        |> put_connect_params(%{"_live_referer" => "http://www.example.com/pricing?token=abc"})
        |> live("/shop")

      assert [pageview] = events("pageview")
      assert pageview.path == "/shop"
      # The host is normalized (www. dropped).
      assert pageview.site == "example.com"
      assert pageview.metadata["source"] == "live_navigation"
      assert pageview.referrer == "http://www.example.com/pricing"
      refute inspect(pageview) =~ "token=abc"
    end

    test "a live navigation from another site keeps the landing URL's click id",
         %{conn: conn} do
      {:ok, _view, _html} =
        conn
        |> with_client()
        |> put_connect_params(%{"_live_referer" => "https://ads.example.net/"})
        |> live("/shop?gclid=EAIaIQob&token=secret")

      assert [pageview] = events("pageview")
      assert pageview.click_id == "EAIaIQob"
      assert pageview.click_param == "gclid"
      refute inspect(pageview) =~ "token=secret"
    end

    # Phoenix.LiveViewTest always joins with `_mounts: 0`, so a reconnect is
    # driven by calling the on_mount callback with the connect params a
    # reconnecting client sends, then running the handle_params hook it
    # attached.
    test "REGRESSION: a reconnect of a live-navigated page records no page view" do
      socket = connected_socket(%{"_live_referer" => "http://www.example.com/", "_mounts" => 1})

      assert {:cont, socket} = LiveHook.on_mount(:track_navigation, %{}, %{}, socket)
      run_handle_params_hook(socket, "http://www.example.com/shop")

      assert events("pageview") == []
    end

    test "the same live navigation on its first mount (_mounts 0) is recorded" do
      # The positive control for the reconnect test above: same socket shape,
      # `_mounts` 0 — proves the harness really exercises the hook.
      socket = connected_socket(%{"_live_referer" => "http://www.example.com/", "_mounts" => 0})

      assert {:cont, socket} = LiveHook.on_mount(:track_navigation, %{}, %{}, socket)
      run_handle_params_hook(socket, "http://www.example.com/shop")

      assert [%Event{path: "/shop"}] = events("pageview")
    end

    test "a patch that only changes the query string records no page view", %{conn: conn} do
      {:ok, view, _html} = conn |> with_client() |> live("/shop")

      render_hook(view, "go", %{"to" => "/shop?x=1"})
      assert_patch(view, "/shop?x=1")

      assert events("pageview") == []
    end

    test "a patch to another path records a live-navigation page view", %{conn: conn} do
      {:ok, view, _html} = conn |> with_client() |> live("/shop")

      render_hook(view, "go", %{"to" => "/shop/other"})
      assert_patch(view, "/shop/other")

      assert [pageview] = events("pageview")
      assert pageview.path == "/shop/other"
      assert pageview.metadata["source"] == "live_navigation"
      assert pageview.referrer == "http://www.example.com/shop"
    end

    test "a connect delivered from Chrome's prefetch cache with a click id is recovered" do
      socket =
        connected_socket(%{
          "_mounts" => 0,
          "nav_delivery" => "navigational-prefetch"
        })

      assert {:cont, socket} = LiveHook.on_mount(:track_navigation, %{}, %{}, socket)
      run_handle_params_hook(socket, "http://www.example.com/shop?gclid=abc123")

      assert [pageview] = events("pageview")
      refute pageview.is_bot
      assert pageview.click_id == "abc123"
      assert pageview.click_param == "gclid"
      assert pageview.referrer_medium == "paid"
    end

    test "a connect delivered from a prerender activation is recovered the same way" do
      socket = connected_socket(%{"_mounts" => 0, "prerendered" => true})

      assert {:cont, socket} = LiveHook.on_mount(:track_navigation, %{}, %{}, socket)
      run_handle_params_hook(socket, "http://www.example.com/shop?gclid=abc123")

      assert [pageview] = events("pageview")
      refute pageview.is_bot
      assert pageview.click_id == "abc123"
    end

    test "REGRESSION: a reconnect (_mounts > 0) of a prefetch-delivered page is not recorded again" do
      socket =
        connected_socket(%{"_mounts" => 1, "nav_delivery" => "navigational-prefetch"})

      assert {:cont, socket} = LiveHook.on_mount(:track_navigation, %{}, %{}, socket)
      run_handle_params_hook(socket, "http://www.example.com/shop?gclid=abc123")

      assert events("pageview") == []
    end

    test "a page served from the prefetch cache is recovered over a real connect",
         %{conn: conn} do
      {:ok, _view, _html} =
        conn
        |> with_client()
        |> put_connect_params(%{
          "nav_delivery" => "navigational-prefetch",
          "doc_referrer" => "https://www.google.com/"
        })
        |> live("/shop?gclid=EAIaIQob")

      assert [pageview] = events("pageview")
      assert pageview.metadata["source"] == "prefetch_connect"
      assert pageview.click_id == "EAIaIQob"
      assert pageview.referrer == "https://www.google.com/"
      refute pageview.is_bot
    end

    test "a live navigation that also carries prefetch params is one live-navigation view",
         %{conn: conn} do
      {:ok, _view, _html} =
        conn
        |> with_client()
        |> put_connect_params(%{
          "_live_referer" => "http://www.example.com/pricing",
          "nav_delivery" => "navigational-prefetch"
        })
        |> live("/shop")

      assert [pageview] = events("pageview")
      assert pageview.metadata["source"] == "live_navigation"
      assert pageview.referrer == "http://www.example.com/pricing"
    end

    # Under LongPoll a prerendered page can join before anyone opens it.
    test "REGRESSION: a connect made while the page is still prerendering records nothing" do
      socket = connected_socket(%{"_mounts" => 0, "prerendered" => true, "prerendering" => true})

      assert {:cont, socket} = LiveHook.on_mount(:track_navigation, %{}, %{}, socket)
      run_handle_params_hook(socket, "http://www.example.com/shop")

      assert events("pageview") == []
    end

    test "REGRESSION: the visitor's own prerender doesn't make their recovered visit a bot's" do
      salt = Config.hash_salt()

      # What the plug stores for Chrome's prerender, from the visitor's own
      # address and browser.
      {:ok, prefetch} =
        Collector.track(%{
          path: "/shop",
          site: "example.com",
          ip: @peer.address,
          user_agent: @ua,
          bot: "prefetch"
        })

      socket = connected_socket(%{"_mounts" => 0, "prerendered" => true})
      assert {:cont, socket} = LiveHook.on_mount(:track_navigation, %{}, %{}, socket)
      run_handle_params_hook(socket, "http://www.example.com/shop")

      assert [recovered] = Repo.all(from(e in Event, where: not e.is_bot))
      assert recovered.visitor_id == Visitor.visitor_id(@peer.address, @ua, salt)
      refute recovered.session_id == prefetch.session_id
      assert recovered.session_start
      refute Map.has_key?(recovered.metadata, "bot")

      filter = Reports.filter(period: "7d")
      assert [%{session_id: session_id}] = Reports.sessions(filter)
      assert session_id == recovered.session_id
    end

    test "a normal connect with neither live_referer nor prefetch markers records nothing from the hook" do
      socket = connected_socket(%{"_mounts" => 0})

      assert {:cont, socket} = LiveHook.on_mount(:track_navigation, %{}, %{}, socket)
      run_handle_params_hook(socket, "http://www.example.com/shop")

      assert events("pageview") == []
    end

    test "doc_referrer flows into the stored referrer for an organic prefetch-delivered click" do
      socket =
        connected_socket(%{
          "_mounts" => 0,
          "nav_delivery" => "navigational-prefetch",
          "doc_referrer" => "https://www.google.com/search"
        })

      assert {:cont, socket} = LiveHook.on_mount(:track_navigation, %{}, %{}, socket)
      run_handle_params_hook(socket, "http://www.example.com/shop")

      assert [pageview] = events("pageview")
      assert pageview.referrer == "https://www.google.com/search"
    end
  end

  describe "interactions" do
    test "a click records the event name, the page and only allow-listed params",
         %{conn: conn} do
      enable_tracking()
      {:ok, view, _html} = conn |> with_client() |> live("/shop")

      view |> element("#add") |> render_click()

      assert [interaction] = events("interaction")
      assert interaction.event_name == "add_to_cart"
      assert interaction.path == "/shop"
      assert interaction.metadata["source"] == "live_event"
      assert interaction.metadata["params"] == %{"tab" => "pricing"}
      refute inspect(interaction) =~ "secret@example.com"
    end

    test "the same event twice within a second counts once", %{conn: conn} do
      enable_tracking()
      {:ok, view, _html} = conn |> with_client() |> live("/shop")

      view |> element("#add") |> render_click()
      view |> element("#add") |> render_click()

      assert [_one] = events("interaction")
    end

    test "form typing records nothing; a submit records the submit event", %{conn: conn} do
      # "validate" is ignored by name by default; clear the ignore list so the
      # only thing keeping typing out is the `_target` check.
      enable_tracking(%{"web_analytics_ignore_events" => "nothing"})
      {:ok, view, _html} = conn |> with_client() |> live("/shop")

      # A browser always sends `_target` with phx-change; LiveViewTest only when told.
      view
      |> form("#contact", %{message: "my private text"})
      |> render_change(%{"_target" => ["message"]})

      assert events("interaction") == []

      view |> form("#contact", %{message: "my private text"}) |> render_submit()

      assert [submit] = events("interaction")
      assert submit.event_name == "save"
      refute inspect(submit) =~ "my private text"
    end

    test "an event in the ignore list is not recorded", %{conn: conn} do
      enable_tracking(%{"web_analytics_ignore_events" => "ping"})
      {:ok, view, _html} = conn |> with_client() |> live("/shop")

      view |> element("#ping") |> render_click()
      assert events("interaction") == []

      # Control: a non-ignored event on the same page still is.
      view |> element("#add") |> render_click()
      assert [%Event{event_name: "add_to_cart"}] = events("interaction")
    end

    test "with interaction tracking off, nothing is recorded", %{conn: conn} do
      enable_tracking(%{"web_analytics_track_interactions" => "false"})
      {:ok, view, _html} = conn |> with_client() |> live("/shop")

      view |> element("#add") |> render_click()
      view |> element("#ping") |> render_click()

      assert events("interaction") == []
    end

    test "an excluded path records no interactions", %{conn: conn} do
      enable_tracking(%{"web_analytics_exclude_paths" => "/shop*"})
      {:ok, view, _html} = conn |> with_client() |> live("/shop")

      view |> element("#add") |> render_click()

      assert events("interaction") == []
    end

    test "an excluded path isn't listed as open, and closing it leaves no leave", %{conn: conn} do
      start_supervised!(LivePresence)
      enable_tracking(%{"web_analytics_exclude_paths" => "/shop*"})
      {:ok, view, _html} = conn |> with_client() |> live("/shop")
      :sys.get_state(LivePresence)

      assert LivePresence.list() == []

      GenServer.stop(view.pid)
      :sys.get_state(LivePresence)
      assert events("leave") == []
    end

    test "an automated visitor isn't listed as open unless bots are recorded", %{conn: conn} do
      start_supervised!(LivePresence)
      enable_tracking()
      bot = put_connect_info(conn, peer_data: @peer, user_agent: "Googlebot/2.1")

      {:ok, _view, _html} = live(bot, "/shop")
      :sys.get_state(LivePresence)

      assert LivePresence.list() == []
    end

    test "a signed-in visitor's rows carry their user uuid", %{conn: conn} do
      enable_tracking()
      scope = fake_scope()

      {:ok, view, _html} =
        conn
        |> put_test_scope(scope)
        |> with_client()
        |> put_connect_params(%{"_live_referer" => "http://www.example.com/"})
        |> live("/shop")

      view |> element("#add") |> render_click()

      rows = events()
      assert Enum.map(rows, & &1.event_type) |> Enum.sort() == ["interaction", "pageview"]
      assert Enum.all?(rows, &(&1.user_uuid == scope.user.uuid))
    end
  end

  describe "the site's own people" do
    test "a staff member's page views and clicks are flagged admin, and so is their open page",
         %{conn: conn} do
      start_supervised!(PhoenixKitWebAnalytics.InternalTraffic)
      start_supervised!(LivePresence)
      enable_tracking()

      {:ok, view, _html} =
        conn
        |> put_test_scope(fake_scope(roles: [:admin]))
        |> with_client()
        |> put_connect_params(%{"_live_referer" => "http://www.example.com/"})
        |> live("/shop")

      view |> element("#add") |> render_click()
      :sys.get_state(LivePresence)

      # The peer 1.2.3.4 is public: the staff member's network is marked too.
      assert Enum.map(events(), & &1.traffic_flags) == [6, 6]
      assert [%{flags: flags}] = LivePresence.list()
      assert Bitwise.band(flags, 2) == 2
      assert LivePresence.list(nil, 7) == []
    end

    test "an ordinary signed-in visitor isn't flagged", %{conn: conn} do
      start_supervised!(PhoenixKitWebAnalytics.InternalTraffic)
      enable_tracking()

      {:ok, view, _html} =
        conn
        |> put_test_scope(fake_scope(roles: [:user]))
        |> with_client()
        |> put_connect_params(%{"_live_referer" => "http://www.example.com/"})
        |> live("/shop")

      view |> element("#add") |> render_click()

      assert Enum.map(events(), & &1.traffic_flags) == [0, 0]
    end
  end

  describe "fake_scope/1" do
    test "answers core's role checks as a real scope would" do
      alias PhoenixKit.Users.Auth.Scope

      assert Scope.owner?(fake_scope())
      assert Scope.has_role?(fake_scope(roles: [:admin]), "Admin")
      refute Scope.owner?(fake_scope(roles: [:user]))

      assert Scope.held_roles(fake_scope(roles: ["User"], held_roles: [:owner, "User"])) == [
               "Owner",
               "User"
             ]

      assert Tracking.current_roles(%{phoenix_kit_current_scope: fake_scope(roles: [:admin])}) ==
               ["Admin"]
    end
  end

  describe "when the hook stays inert" do
    test "a Do Not Track session records nothing at all", %{conn: conn} do
      enable_tracking()

      {:ok, view, _html} =
        conn
        |> Plug.Test.init_test_session(%{Tracking.dnt_session_key() => true})
        |> with_client()
        |> put_connect_params(%{"_live_referer" => "http://www.example.com/"})
        |> live("/shop")

      view |> element("#add") |> render_click()
      render_hook(view, "go", %{"to" => "/shop/other"})

      assert events() == []
    end

    test "without a user agent in connect_info, clicks record nothing", %{conn: conn} do
      enable_tracking()

      {:ok, view, _html} =
        conn
        |> put_connect_info(peer_data: @peer)
        |> put_connect_params(%{"_live_referer" => "http://www.example.com/"})
        |> live("/shop")

      view |> element("#add") |> render_click()

      assert events() == []
    end
  end

  describe "behind a reverse proxy" do
    @proxy_peer %{address: {172, 18, 0, 8}, port: 4000, ssl_cert: nil}

    setup do
      start_supervised!(BotSignals)
      start_supervised!(LivePresence)
      enable_tracking()
    end

    defp live_navigation(conn, connect_info) do
      {:ok, view, _html} =
        conn
        |> put_connect_info(connect_info)
        |> put_connect_params(%{"_live_referer" => "http://www.example.com/"})
        |> live("/shop")

      :sys.get_state(LivePresence)
      view
    end

    defp visitor(ip), do: Visitor.visitor_id(ip, @ua, Config.hash_salt())

    test "reads the visitor from :x_headers, port dropped — one visitor per client",
         %{conn: conn} do
      for forwarded <- ["203.0.113.9:51234", "198.51.100.4:40000"] do
        live_navigation(conn,
          peer_data: @proxy_peer,
          user_agent: @ua,
          x_headers: [{"x-forwarded-for", forwarded}]
        )
      end

      assert Enum.map(events("pageview"), & &1.visitor_id) |> Enum.sort() ==
               Enum.sort([visitor({203, 0, 113, 9}), visitor({198, 51, 100, 4})])

      assert BotSignals.live_visits() == %{tracked: 2, skipped: 0}
    end

    test "without :x_headers in connect_info, records nothing and counts the skip",
         %{conn: conn} do
      view = live_navigation(conn, peer_data: @proxy_peer, user_agent: @ua)
      view |> element("#add") |> render_click()

      assert events() == []
      assert LivePresence.list() == []
      assert BotSignals.live_visits() == %{tracked: 0, skipped: 1}
    end

    test "with :x_headers listed but no forwarded header (no proxy), the peer is the visitor",
         %{conn: conn} do
      view = live_navigation(conn, peer_data: @proxy_peer, user_agent: @ua, x_headers: [])
      view |> element("#add") |> render_click()

      assert [pageview, interaction] = events()
      assert pageview.visitor_id == visitor({172, 18, 0, 8})
      assert interaction.visitor_id == pageview.visitor_id
      assert [_open] = LivePresence.list()
      assert BotSignals.live_visits() == %{tracked: 1, skipped: 0}
    end
  end

  # ── a hand-built connected socket, for the reconnect case ─────────────────

  defp connected_socket(connect_params) do
    %Phoenix.LiveView.Socket{
      endpoint: PhoenixKitWebAnalytics.Test.Endpoint,
      router: PhoenixKitWebAnalytics.Test.Router,
      view: PhoenixKitWebAnalytics.Test.TrackedLive,
      transport_pid: self(),
      private: %{
        connect_params: connect_params,
        connect_info: %{peer_data: @peer, user_agent: @ua},
        lifecycle: %Phoenix.LiveView.Lifecycle{}
      }
    }
  end

  defp run_handle_params_hook(socket, uri) do
    [%{function: fun}] = socket.private.lifecycle.handle_params
    {:cont, socket} = fun.(%{}, uri, socket)
    socket
  end
end
