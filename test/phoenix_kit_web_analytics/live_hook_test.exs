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

  alias PhoenixKitWebAnalytics.LiveHook
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Test.Repo
  alias PhoenixKitWebAnalytics.Tracking

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
