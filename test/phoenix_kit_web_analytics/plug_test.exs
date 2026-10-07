defmodule PhoenixKitWebAnalytics.PlugTest do
  @moduledoc """
  The plug's decision logic — which requests it will and won't consider.

  These run without a database: with tracking off (or settings unreachable) the
  plug must be a no-op, which is exactly the property worth pinning down. The
  storage side is covered by
  `PhoenixKitWebAnalytics.CollectorTest`.
  """

  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2, conn: 3]

  alias PhoenixKitWebAnalytics.Plug, as: TrackingPlug

  defp registered_callbacks(conn), do: conn.private[:before_send] || []

  describe "init/1" do
    test "normalizes the exclude option to a list" do
      assert TrackingPlug.init([])[:exclude] == []
      assert TrackingPlug.init(exclude: "/healthz")[:exclude] == ["/healthz"]
      assert TrackingPlug.init(exclude: ["/a", "/b"])[:exclude] == ["/a", "/b"]
    end
  end

  describe "skip/1" do
    test "marks a request as not-to-be-tracked" do
      conn = conn(:get, "/preview")

      refute TrackingPlug.skipped?(conn)
      assert conn |> TrackingPlug.skip() |> TrackingPlug.skipped?()
    end

    test "a skipped request never registers a callback" do
      conn =
        conn(:get, "/preview")
        |> TrackingPlug.skip()
        |> TrackingPlug.call(TrackingPlug.init([]))

      assert registered_callbacks(conn) == []
    end
  end

  describe "call/2" do
    test "ignores non-GET requests without reading settings" do
      for method <- [:post, :put, :patch, :delete, :head] do
        conn = conn(method, "/") |> TrackingPlug.call(TrackingPlug.init([]))

        assert registered_callbacks(conn) == []
      end
    end

    test "registers nothing while tracking is off" do
      conn = conn(:get, "/") |> TrackingPlug.call(TrackingPlug.init([]))

      assert registered_callbacks(conn) == []
    end

    test "passes the connection through unchanged" do
      original = conn(:get, "/pricing?utm_source=hn")
      result = TrackingPlug.call(original, TrackingPlug.init([]))

      assert result.request_path == original.request_path
      assert result.status == original.status
      assert result.state == original.state
    end
  end
end

defmodule PhoenixKitWebAnalytics.PlugIntegrationTest do
  @moduledoc """
  The plug end to end with tracking on: what it stores for a page view and what
  it does for an opted-out visitor. Writes are inline (`async_tracking: false`
  in the test config), so the before_send callback lands on the sandbox.
  """

  use PhoenixKitWebAnalytics.DataCase, async: false

  import Plug.Test, only: [conn: 2, init_test_session: 2]

  alias PhoenixKitWebAnalytics.Plug, as: TrackingPlug
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Tracking

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  setup do
    enable_tracking()
    :ok
  end

  defp request(path, headers \\ []) do
    Enum.reduce([{"user-agent", @chrome} | headers], conn(:get, path), fn {k, v}, conn ->
      Plug.Conn.put_req_header(conn, k, v)
    end)
  end

  defp respond(conn, content_type \\ "text/html", status \\ 200) do
    conn
    |> TrackingPlug.call(TrackingPlug.init([]))
    |> Plug.Conn.put_resp_content_type(content_type)
    |> Plug.Conn.send_resp(status, "<html></html>")
  end

  describe "a normal HTML page view" do
    test "is stored with path, site, status and campaign" do
      "/pricing/?utm_source=hn&token=secret"
      |> request([{"accept-language", "et-EE,et;q=0.9"}])
      |> respond()

      assert [event] = Repo.all(Event)
      assert event.event_type == "pageview"
      assert event.path == "/pricing"
      # The Host is normalized: www. dropped.
      assert event.site == "example.com"
      assert event.status == 200
      assert event.utm_source == "hn"
      assert event.language == "et-EE"
      assert event.browser == "Chrome"
      assert is_integer(event.duration_ms) and event.duration_ms >= 0
    end

    test "stores an ad-click identifier from an unfetched query string" do
      "/landing?gclid=EAIaIQob&session=secret"
      |> request()
      |> respond()

      assert [event] = Repo.all(Event)
      assert event.click_id == "EAIaIQob"
      assert event.click_param == "gclid"
      assert event.referrer_medium == "paid"
      refute inspect(event) =~ "secret"
    end

    test "stores an ad-click identifier from already-fetched query params" do
      "/landing?msclkid=m1&session=secret"
      |> request()
      |> Plug.Conn.fetch_query_params()
      |> respond()

      assert [event] = Repo.all(Event)
      assert event.click_id == "m1"
      assert event.click_param == "msclkid"
    end

    test "a list-shaped click parameter is ignored, the page view is kept" do
      "/landing?gclid[]=a&gclid[]=b"
      |> request()
      |> Plug.Conn.fetch_query_params()
      |> respond()

      assert [event] = Repo.all(Event)
      assert is_nil(event.click_id)
    end

    test "stores the referrer without its query string" do
      "/landing"
      |> request([{"referer", "https://mail.example.org/reset?token=abc&email=a@b.c#top"}])
      |> respond()

      assert [event] = Repo.all(Event)
      assert event.referrer == "https://mail.example.org/reset"
    end

    test "a non-HTML or non-2xx response stores nothing" do
      "/api/data" |> request() |> respond("application/json")
      "/moved" |> request() |> respond("text/html", 302)
      "/missing" |> request() |> respond("text/html", 404)

      assert Repo.all(Event) == []
    end

    test "an excluded path stores nothing and registers no callback" do
      conn = "/admin/settings" |> request() |> TrackingPlug.call(TrackingPlug.init([]))

      assert (conn.private[:before_send] || []) == []
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, "")

      "/healthz"
      |> request()
      |> TrackingPlug.call(TrackingPlug.init(exclude: "/healthz"))
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, "")

      assert Repo.all(Event) == []
    end

    test "the session-recording player loading a page behind a replay is not a page view" do
      "/pricing?pk_replay=1" |> request() |> respond()

      assert Repo.all(Event) == []
    end

    test "a LiveView page running the hook is marked, so a missing connection can be spotted" do
      hook = %{id: {PhoenixKitWebAnalytics.LiveHook, :track_navigation}}
      other = %{id: {SomeAuth, :default}}

      "/dashboard-page"
      |> request()
      |> Plug.Conn.put_private(
        :phoenix_live_view,
        {SomeLive, [], %{extra: %{on_mount: [other, hook]}}}
      )
      |> respond()

      "/other-page"
      |> request()
      |> Plug.Conn.put_private(:phoenix_live_view, {SomeLive, [], %{extra: %{on_mount: [other]}}})
      |> respond()

      "/plain" |> request() |> respond()

      marks = Map.new(Repo.all(Event), &{&1.path, &1.metadata})
      assert marks["/dashboard-page"] == %{"lv" => true}
      assert marks["/other-page"] == %{}
      assert marks["/plain"] == %{}
    end

    test "skip/1 after the plug ran still drops the hit" do
      "/preview"
      |> request()
      |> TrackingPlug.call(TrackingPlug.init([]))
      |> TrackingPlug.skip()
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, "")

      assert Repo.all(Event) == []
    end
  end

  describe "an opted-out visitor" do
    test "with a fetched session gets the DNT session key and no event" do
      conn =
        "/pricing"
        |> request([{"dnt", "1"}])
        |> init_test_session(%{})
        |> TrackingPlug.call(TrackingPlug.init([]))

      assert Plug.Conn.get_session(conn, Tracking.dnt_session_key()) == true
      assert (conn.private[:before_send] || []) == []

      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, "")
      assert Repo.all(Event) == []
    end

    test "is noted on an excluded page too, so the LiveView hook leaves them alone after it" do
      for {path, opts} <- [{"/admin/settings", []}, {"/healthz", [exclude: "/healthz"]}] do
        conn =
          path
          |> request([{"dnt", "1"}])
          |> init_test_session(%{})
          |> TrackingPlug.call(TrackingPlug.init(opts))

        assert Plug.Conn.get_session(conn, Tracking.dnt_session_key()) == true
      end
    end

    test "Sec-GPC is honoured the same way" do
      conn =
        "/pricing"
        |> request([{"sec-gpc", "1"}])
        |> init_test_session(%{})
        |> TrackingPlug.call(TrackingPlug.init([]))

      assert Plug.Conn.get_session(conn, Tracking.dnt_session_key()) == true
    end

    test "without a fetched session the plug neither crashes nor starts one" do
      conn = "/pricing" |> request([{"dnt", "1"}]) |> TrackingPlug.call(TrackingPlug.init([]))

      refute Map.has_key?(conn.private, :plug_session)
      refute conn.private[:plug_session_fetch] == :done
      assert (conn.private[:before_send] || []) == []

      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, "")
      assert Repo.all(Event) == []
    end

    test "a visitor without DNT gets no session key" do
      conn =
        "/pricing"
        |> request()
        |> init_test_session(%{})
        |> TrackingPlug.call(TrackingPlug.init([]))

      assert Plug.Conn.get_session(conn, Tracking.dnt_session_key()) == nil
    end

    test "with respect_dnt off the visitor is tracked and not marked" do
      enable_tracking(%{"web_analytics_respect_dnt" => "false"})

      conn =
        "/pricing"
        |> request([{"dnt", "1"}])
        |> init_test_session(%{})
        |> respond()

      assert Plug.Conn.get_session(conn, Tracking.dnt_session_key()) == nil
      assert [%Event{path: "/pricing"}] = Repo.all(Event)
    end
  end
end
