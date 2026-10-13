defmodule PhoenixKitWebAnalytics.ConsentEntryPointsTest do
  @moduledoc """
  Every way a hit reaches the collector, held to the visitor's answer: the
  LiveView hook and its leaves, the pixel, the automation report, recording
  chunks, the host's own `track_event/2` — and the limits and opt-out notes
  around them.
  """

  use PhoenixKitWebAnalytics.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKitWebAnalytics.BotSignals
  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Consent
  alias PhoenixKitWebAnalytics.LivePresence
  alias PhoenixKitWebAnalytics.Plug, as: TrackingPlug
  alias PhoenixKitWebAnalytics.Recordings
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Schemas.Recording
  alias PhoenixKitWebAnalytics.Schemas.VisitorProfile
  alias PhoenixKitWebAnalytics.Test.Repo
  alias PhoenixKitWebAnalytics.Tracking

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @peer %{address: {1, 2, 3, 4}, port: 1, ssl_cert: nil}
  @recording_path "/phoenix-kit/analytics/recording"
  @beacon_path "/phoenix-kit/analytics/event"
  @pixel_path "/phoenix-kit/analytics/pixel.gif"

  defmodule Source do
    @moduledoc false
    def status(conn, _category) do
      case Plug.Conn.get_req_header(conn, "x-test-consent") do
        ["yes"] -> :granted
        ["no"] -> :denied
        _ -> :unknown
      end
    end
  end

  setup do
    Application.put_env(:phoenix_kit_web_analytics, :consent_source, {Source, :status})
    on_exit(fn -> Application.delete_env(:phoenix_kit_web_analytics, :consent_source) end)
    :ok
  end

  defp request(path, headers) do
    Enum.reduce([{"user-agent", @chrome} | headers], Plug.Test.conn(:get, path), fn {k, v},
                                                                                    conn ->
      Plug.Conn.put_req_header(conn, k, v)
    end)
  end

  defp page(path, headers, session \\ %{}) do
    path
    |> request(headers)
    |> Plug.Test.init_test_session(session)
    |> TrackingPlug.call(TrackingPlug.init([]))
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, "<html></html>")
  end

  defp events(type \\ nil) do
    query = from(e in Event, order_by: [asc: e.inserted_at])
    query = if type, do: where(query, [e], e.event_type == ^type), else: query
    Repo.all(query)
  end

  defp browser(conn), do: put_req_header(conn, "user-agent", @chrome)
  defp yes(conn), do: put_req_header(conn, "x-test-consent", "yes")

  defp wait_until(fun, attempts \\ 100) do
    case fun.() do
      result when result not in [nil, false, []] ->
        result

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      _ ->
        flunk("condition not met within 1s")
    end
  end

  defp live_visit(conn, session) do
    conn
    |> Plug.Test.init_test_session(session)
    |> Plug.Conn.put_private(:live_view_connect_info, %{peer_data: @peer, user_agent: @chrome})
    |> put_connect_params(%{"_live_referer" => "http://www.example.com/"})
    |> live("/shop")
  end

  defp note(value), do: %{Consent.session_key() => value}

  describe "the LiveView hook, counting only after a yes" do
    setup do
      enable_tracking(%{"web_analytics_consent_measurement" => "consent"})
      start_supervised!(LivePresence)
      :ok
    end

    test "a session with no answer is not listed as on a page, and leaves no leave",
         %{conn: conn} do
      {:ok, unanswered, _html} = live_visit(conn, %{})
      :sys.get_state(LivePresence)
      assert LivePresence.list() == []

      # A visitor who agreed, opened after and closed after: once their
      # leave has landed, the first one's would have.
      {:ok, agreed, _html} = live_visit(build_conn(), note("granted"))
      :sys.get_state(LivePresence)
      assert [%{path: "/shop"}] = LivePresence.list()

      GenServer.stop(unanswered.pid)
      GenServer.stop(agreed.pid)

      assert [_one] = wait_until(fn -> events("leave") end)
      :sys.get_state(LivePresence)
      assert [%Event{}] = events("leave")
      assert [%Event{}] = events("pageview")
    end
  end

  describe "the LiveView hook, counting until a no" do
    setup do
      enable_tracking(%{
        "web_analytics_consent_measurement" => "unless_objected",
        "web_analytics_respect_dnt" => "false"
      })

      :ok
    end

    test "a noted refusal or a noted browser objection records nothing", %{conn: conn} do
      for value <- ["denied", "denied:objected", "unknown:objected"] do
        {:ok, view, _html} = live_visit(conn, note(value))
        view |> element("#add") |> render_click()
      end

      assert events() == []
    end

    test "a visitor noted as not having answered is recorded", %{conn: conn} do
      {:ok, view, _html} = live_visit(conn, note("unknown"))
      view |> element("#add") |> render_click()

      assert [%Event{event_type: "pageview"}, %Event{event_type: "interaction"}] = events()
    end

    # The plug ran before :fetch_session, or never served the page. The
    # visitor may have refused; nothing here can tell.
    test "a session the plug left no note in records nothing", %{conn: conn} do
      {:ok, view, _html} = live_visit(conn, %{})
      view |> element("#add") |> render_click()

      assert events() == []
    end

    test "a note that is not one the plug writes records nothing", %{conn: conn} do
      {:ok, view, _html} = live_visit(conn, note("grantedX"))
      view |> element("#add") |> render_click()

      assert events() == []
    end
  end

  describe "a leave" do
    setup do
      enable_tracking(%{"web_analytics_consent_measurement" => "consent"})
      start_supervised!(LivePresence)
      :ok
    end

    defp open_page(consent, path) do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      client = %{ip: {1, 2, 3, 4}, user_agent: @chrome, language: nil, consent: consent}
      LivePresence.watch(pid, client, %{path: path, site: "example.com"})
      pid
    end

    test "is stored for a page opened with a yes, and not for one opened without" do
      refused = open_page(Consent.none(), "/refused")
      agreed = open_page(Consent.all(), "/agreed")
      :sys.get_state(LivePresence)

      Process.exit(refused, :kill)
      Process.exit(agreed, :kill)

      assert [%Event{path: "/agreed"}] = wait_until(fn -> events("leave") end)
      :sys.get_state(LivePresence)
      assert [%Event{path: "/agreed"}] = events("leave")
    end
  end

  describe "the pixel, counting only after a yes" do
    test "no answer stores nothing, a yes one page view", %{conn: conn} do
      enable_tracking(%{
        "web_analytics_consent_measurement" => "consent",
        "web_analytics_beacon_enabled" => "true"
      })

      assert %{status: 200} = conn |> browser() |> get(@pixel_path, %{"p" => "/cached"})
      assert events() == []

      conn |> browser() |> yes() |> get(@pixel_path, %{"p" => "/cached"})

      assert [%Event{event_type: "pageview", path: "/cached", visitor_id: visitor}] = events()
      refute String.starts_with?(visitor, "anon:")
    end

    test "without an answer the view is counted with no visitor, when asked", %{conn: conn} do
      enable_tracking(%{
        "web_analytics_consent_measurement" => "consent",
        "web_analytics_without_consent" => "anonymous",
        "web_analytics_beacon_enabled" => "true"
      })

      conn |> browser() |> get(@pixel_path, %{"p" => "/cached"})

      assert [%Event{path: "/cached", visitor_id: "anon:" <> _, metadata: %{"anon" => true}}] =
               events()
    end
  end

  describe "the automation report" do
    defp automation(conn) do
      conn
      |> browser()
      |> put_req_header("content-type", "text/plain")
      |> post(@beacon_path, Jason.encode!(%{"e" => "automation"}))
    end

    defp flagged, do: Repo.all(from(e in Event, select: {e.is_bot, e.metadata["bot"]}))

    defp visit do
      {:ok, _event} =
        Collector.track(%{
          path: "/",
          site: "www.example.com",
          ip: {127, 0, 0, 1},
          user_agent: @chrome
        })
    end

    test "flags nobody whose visits may not be counted", %{conn: conn} do
      enable_tracking(%{
        "web_analytics_client_script" => "true",
        "web_analytics_consent_measurement" => "consent"
      })

      visit()

      automation(conn)
      assert flagged() == [{false, nil}]

      build_conn() |> yes() |> automation()
      assert flagged() == [{true, "webdriver"}]
    end

    test "flags nobody who asked not to be tracked", %{conn: conn} do
      enable_tracking(%{"web_analytics_client_script" => "true"})
      visit()

      conn |> put_req_header("sec-gpc", "1") |> automation()
      build_conn() |> put_req_header("dnt", "1") |> automation()
      assert flagged() == [{false, nil}]

      # With the opt-out not honoured, the same report counts.
      enable_tracking(%{
        "web_analytics_client_script" => "true",
        "web_analytics_respect_dnt" => "false"
      })

      build_conn() |> put_req_header("sec-gpc", "1") |> automation()
      assert flagged() == [{true, "webdriver"}]
    end
  end

  describe "a recording chunk" do
    @chunk %{
      "k" => "pageKeyAbc123",
      "s" => 0,
      "p" => "/pricing",
      "w" => 1280,
      "h" => 800,
      "f" => [[0, "s", 0, 0], [120, "m", 10, 20]]
    }

    defp client(attrs) do
      Map.merge(%{ip: {1, 2, 3, 4}, user_agent: @chrome, site: "example.com"}, attrs)
    end

    test "is refused for a visitor who did not allow recordings" do
      enable_tracking(%{"web_analytics_recording" => "true"})

      refused = %{Consent.all() | recording: false}

      assert Recordings.store(client(%{consent: refused}), @chunk) == {:error, :not_recording}
      assert Repo.aggregate(Recording, :count) == 0

      assert Recordings.store(client(%{consent: Consent.all()}), @chunk) == :ok
      assert Repo.aggregate(Recording, :count) == 1
    end

    # A visitor is address + User-Agent, so a new User-Agent is a new one.
    test "one address is held to 180 a minute, whatever User-Agents it sends" do
      enable_tracking(%{"web_analytics_recording" => "true"})
      start_supervised!(BotSignals)
      await_fresh_minute()

      results =
        for i <- 1..185 do
          Recordings.store(
            client(%{user_agent: "#{@chrome} Variant/#{i}"}),
            %{@chunk | "k" => "pageKey#{String.pad_leading("#{i}", 4, "0")}"}
          )
        end

      assert Enum.count(results, &(&1 == :ok)) == 180
      assert Enum.count(results, &(&1 == {:error, :too_fast})) == 5
      assert Repo.aggregate(Recording, :count) == 180

      # Another address is counted on its own.
      assert Recordings.store(client(%{ip: {5, 6, 7, 8}}), %{@chunk | "k" => "otherAddr1"}) == :ok
    end
  end

  describe "device measurements" do
    @device %{"cv" => "a1b2c3d4", "gr" => "ANGLE (Apple, M2)", "plat" => "Win32", "sw" => 1920}

    test "one address is held to 30 reports a minute, whatever User-Agents it sends", %{
      conn: conn
    } do
      enable_tracking(%{
        "web_analytics_client_script" => "true",
        "web_analytics_store_signals" => "true"
      })

      start_supervised!(BotSignals)
      await_fresh_minute()

      for i <- 1..35 do
        conn
        |> put_req_header("user-agent", "#{@chrome} Variant/#{i}")
        |> put_req_header("content-type", "text/plain")
        |> post(@beacon_path, Jason.encode!(%{"e" => "signals", "s" => @device}))
      end

      assert Repo.aggregate(VisitorProfile, :count) == 30
    end
  end

  describe "a browser's opt-out, honoured (the default), beside the rules" do
    setup do
      enable_tracking(%{
        "web_analytics_consent_measurement" => "unless_objected",
        "web_analytics_consent_device" => "unless_objected",
        "web_analytics_client_script" => "true",
        "web_analytics_store_signals" => "true"
      })

      :ok
    end

    # `respect_dnt` is the blunter switch: a yes in the banner does not
    # outweigh it, as it does the consent rule's own reading of the signal.
    test "a yes from the banner does not undo it", %{conn: conn} do
      result = page("/pricing", [{"sec-gpc", "1"}, {"x-test-consent", "yes"}])

      assert events() == []
      refute Map.has_key?(Plug.Conn.get_session(result), Consent.session_key())
      assert Plug.Conn.get_session(result, Tracking.dnt_session_key()) == true

      assert %{"signals" => false} =
               conn
               |> browser()
               |> yes()
               |> put_req_header("sec-gpc", "1")
               |> get(@recording_path, %{"p" => "/"})
               |> json_response(200)

      # Without the signal the same visitor is measured.
      assert %{"signals" => true} =
               build_conn()
               |> browser()
               |> yes()
               |> get(@recording_path, %{"p" => "/"})
               |> json_response(200)
    end
  end

  describe "the opt-out note the plug leaves for the hook" do
    @dnt Tracking.dnt_session_key()

    test "is written while the browser sends the signal" do
      enable_tracking()

      assert "/pricing" |> page([{"dnt", "1"}]) |> Plug.Conn.get_session(@dnt) == true
    end

    test "is taken back when the browser stops sending it" do
      enable_tracking()
      conn = page("/pricing", [], %{@dnt => true})

      refute Map.has_key?(Plug.Conn.get_session(conn), @dnt)
      assert [%Event{path: "/pricing"}] = events()
    end

    test "is taken back when the site stops honouring the signal" do
      enable_tracking(%{"web_analytics_respect_dnt" => "false"})
      conn = page("/pricing", [{"sec-gpc", "1"}], %{@dnt => true})

      refute Map.has_key?(Plug.Conn.get_session(conn), @dnt)
    end

    test "is taken back beside a consent rule, too" do
      enable_tracking(%{"web_analytics_consent_measurement" => "consent"})
      conn = page("/pricing", [], %{@dnt => true})

      refute Map.has_key?(Plug.Conn.get_session(conn), @dnt)
    end

    test "stays while the signal does" do
      enable_tracking()
      conn = page("/pricing", [{"sec-gpc", "1"}], %{@dnt => true})

      assert Plug.Conn.get_session(conn, @dnt) == true
    end

    test "a request with no session fetched is left without one" do
      enable_tracking()

      conn = "/pricing" |> request([]) |> TrackingPlug.call(TrackingPlug.init([]))

      refute conn.private[:plug_session_fetch] == :done
    end
  end

  describe "request headers" do
    setup do
      enable_tracking(%{
        "web_analytics_consent_profile" => "consent",
        "web_analytics_store_ip" => "full",
        "web_analytics_store_headers" => "true"
      })

      :ok
    end

    # The before_send callback runs in this process, so the hit it hands
    # the collector can be read off a call trace (a process can't be its
    # own tracer, hence the relay).
    defp traced_hit(fun) do
      test = self()
      relay = spawn(fn -> relay_trace(test) end)
      :erlang.trace_pattern({Collector, :track_async, 1}, true, [:global])
      :erlang.trace(test, true, [:call, {:tracer, relay}])

      try do
        fun.()
        assert_receive {:trace, ^test, :call, {Collector, :track_async, [hit]}}
        hit
      after
        :erlang.trace(test, false, [:call])
        :erlang.trace_pattern({Collector, :track_async, 1}, false, [:global])
        Process.exit(relay, :kill)
      end
    end

    defp relay_trace(test) do
      receive do
        message -> send(test, message)
      end

      relay_trace(test)
    end

    test "are not copied out of the request for a visitor who did not allow details" do
      hit = traced_hit(fn -> page("/pricing", [{"x-secret-route", "internal"}]) end)

      refute Map.has_key?(hit, :headers)
      assert [%Event{}] = events()
      assert Repo.all(VisitorProfile) == []
    end

    test "are copied, and kept, with a yes" do
      hit = traced_hit(fn -> page("/pricing", [{"x-test-consent", "yes"}]) end)

      assert %{"names" => names} = hit.headers
      assert "user-agent" in names
      assert [%VisitorProfile{headers: %{"names" => ^names}}] = Repo.all(VisitorProfile)
    end

    test "a profile written for other details holds no headers the visit did not allow" do
      # Details allowed, headers switched off: the profile exists, without them.
      enable_tracking(%{
        "web_analytics_consent_profile" => "consent",
        "web_analytics_store_ip" => "full",
        "web_analytics_store_headers" => "false"
      })

      page("/pricing", [{"x-test-consent", "yes"}])

      assert [%VisitorProfile{headers: nil, ip: ip}] = Repo.all(VisitorProfile)
      assert is_binary(ip)
    end
  end

  describe "track_event/2 and track_pageview/1 from the host's own code" do
    setup do
      enable_tracking(%{
        "web_analytics_consent_measurement" => "consent",
        "web_analytics_store_ip" => "full"
      })

      :ok
    end

    test "with the conn, nothing is stored for a visitor who has not agreed" do
      conn = request("/checkout", [])

      assert PhoenixKitWebAnalytics.track_event("order.placed", %{conn: conn}) == :ok
      assert PhoenixKitWebAnalytics.track_pageview(%{conn: conn, path: "/export"}) == :ok

      assert events() == []
      assert Repo.all(VisitorProfile) == []
    end

    test "with the conn, a visitor who agreed is the plug's own visitor" do
      page("/checkout", [{"x-test-consent", "yes"}])
      conn = request("/checkout", [{"x-test-consent", "yes"}])

      PhoenixKitWebAnalytics.track_event("order.placed", %{conn: conn, path: "/checkout"})
      PhoenixKitWebAnalytics.track_pageview(%{conn: conn, path: "/export"})

      assert [view, event, export] = events()
      assert event.event_name == "order.placed"
      assert export.event_type == "pageview"
      assert event.visitor_id == view.visitor_id
      assert event.session_id == view.session_id
      assert export.session_id == view.session_id
      refute Map.has_key?(Map.from_struct(event), :conn)
    end

    test "with the conn, a browser asking not to be tracked is left alone even after a yes" do
      conn = request("/checkout", [{"x-test-consent", "yes"}, {"sec-gpc", "1"}])

      PhoenixKitWebAnalytics.track_event("order.placed", %{conn: conn})
      assert events() == []

      # Not even as a view counted without a visitor.
      enable_tracking(%{
        "web_analytics_consent_measurement" => "consent",
        "web_analytics_without_consent" => "anonymous"
      })

      PhoenixKitWebAnalytics.track_pageview(%{conn: conn, path: "/export"})
      assert events() == []

      # The blunt switch off: the yes stands.
      enable_tracking(%{
        "web_analytics_consent_measurement" => "consent",
        "web_analytics_respect_dnt" => "false"
      })

      PhoenixKitWebAnalytics.track_event("order.placed", %{conn: conn})
      assert [%Event{event_name: "order.placed"}] = events()
    end

    test "what the caller sets itself stands over the conn" do
      conn = request("/checkout", [])

      PhoenixKitWebAnalytics.track_event("order.placed", %{conn: conn, consent: Consent.all()})

      assert [%Event{event_name: "order.placed"}] = events()
    end

    # Documented: the module asks nothing for a hit that says nothing.
    test "without the conn or :consent, the hit is stored on the host's word" do
      PhoenixKitWebAnalytics.track_event("order.placed", %{
        ip: {203, 0, 113, 5},
        user_agent: @chrome
      })

      assert [%Event{event_name: "order.placed"}] = events()
      assert [%VisitorProfile{ip: "203.0.113.5"}] = Repo.all(VisitorProfile)
    end
  end
end
