defmodule PhoenixKitWebAnalytics.ConsentTest do
  @moduledoc "The rules themselves: which answer lets which mode collect."

  use ExUnit.Case, async: true

  alias PhoenixKitWebAnalytics.Consent

  defp config(modes \\ %{}) do
    %{
      consent:
        Map.merge(
          %{measurement: :always, profile: :always, device: :always, recording: :always},
          modes
        ),
      consent_category: "analytics"
    }
  end

  describe "allows?/3" do
    test "always collects whatever the visitor said" do
      for status <- [:granted, :denied, :unknown], objected? <- [true, false] do
        assert Consent.allows?(:always, status, objected?)
      end
    end

    test "consent collects only after a yes" do
      assert Consent.allows?(:consent, :granted, false)
      assert Consent.allows?(:consent, :granted, true)
      refute Consent.allows?(:consent, :unknown, false)
      refute Consent.allows?(:consent, :denied, false)
    end

    test "unless_objected collects until a no, and a browser objection is a no" do
      assert Consent.allows?(:unless_objected, :unknown, false)
      refute Consent.allows?(:unless_objected, :unknown, true)
      refute Consent.allows?(:unless_objected, :denied, false)
    end

    test "an explicit yes outweighs the browser's default objection" do
      assert Consent.allows?(:unless_objected, :granted, true)
    end
  end

  describe "needed?/1" do
    test "is false for the default configuration" do
      refute Consent.needed?(config())
      refute Consent.needed?(%{})
    end

    test "is true as soon as one kind of collection waits for an answer" do
      assert Consent.needed?(config(%{recording: :consent}))
      assert Consent.needed?(config(%{measurement: :unless_objected}))
    end
  end

  describe "permissions/2" do
    test "each kind follows its own mode" do
      modes = config(%{profile: :consent, device: :unless_objected})

      assert Consent.permissions(modes, {:unknown, false}) ==
               %{measurement: true, profile: false, device: true, recording: true}

      assert Consent.permissions(modes, {:granted, false}) == Consent.all()

      assert Consent.permissions(modes, {:denied, false}) ==
               %{measurement: true, profile: false, device: false, recording: true}
    end

    test "nothing describing a visitor is kept for one whose visits are not counted" do
      modes = config(%{measurement: :consent})
      assert Consent.permissions(modes, {:unknown, false}) == Consent.none()
      assert Consent.permissions(modes, {:granted, false}) == Consent.all()
    end

    # Every rule for every kind, against every answer: 81 × 6 combinations.
    test "each kind is its own rule and the counting rule, for every combination" do
      modes = [:always, :consent, :unless_objected]

      for measurement <- modes,
          profile <- modes,
          device <- modes,
          recording <- modes,
          status <- [:granted, :denied, :unknown],
          objected? <- [true, false] do
        rules = %{
          measurement: measurement,
          profile: profile,
          device: device,
          recording: recording
        }

        permissions = Consent.permissions(config(rules), {status, objected?})
        counted? = Consent.allows?(measurement, status, objected?)

        assert permissions.measurement == counted?,
               "measurement under #{inspect(rules)} for #{inspect({status, objected?})}"

        for purpose <- [:profile, :device, :recording] do
          assert permissions[purpose] ==
                   (counted? and Consent.allows?(rules[purpose], status, objected?)),
                 "#{purpose} under #{inspect(rules)} for #{inspect({status, objected?})}"
        end
      end
    end

    test "with every rule at always, everything is allowed whatever the answer" do
      for status <- [:granted, :denied, :unknown], objected? <- [true, false] do
        assert Consent.permissions(config(), {status, objected?}) == Consent.all()
      end
    end
  end

  describe "the session note" do
    test "round-trips every answer" do
      for status <- [:granted, :denied, :unknown], objected? <- [true, false] do
        conn =
          Plug.Test.conn(:get, "/")
          |> Plug.Test.init_test_session(%{})
          |> Consent.remember({status, objected?})

        session = Plug.Conn.get_session(conn)
        assert Consent.noted(session) == {status, objected?}
      end
    end

    test "is not written when no session was fetched" do
      conn = Plug.Test.conn(:get, "/")
      assert Consent.remember(conn, {:granted, false}) == conn
    end

    # The plug ran before :fetch_session, or never served the page: the
    # visitor may have refused, and a LiveView has no other way to know.
    test "a session without a note is a visitor who objected and has not answered" do
      assert Consent.noted(%{}) == {:unknown, true}
      assert Consent.noted(nil) == {:unknown, true}
    end

    test "a note is read whole: a prefix of an answer is not one" do
      for note <- ["garbage", "grantedX", "granted:", "granted:objectedX", "deniedX", "", 1] do
        assert Consent.noted(%{Consent.session_key() => note}) == {:unknown, true},
               "#{inspect(note)} was read as an answer"
      end
    end

    test "for_session/2 allows everything when nothing waits for an answer" do
      assert Consent.for_session(%{}, config()) == Consent.all()
      assert Consent.for_session(%{}, config(%{measurement: :consent})) == Consent.none()

      assert Consent.for_session(
               %{Consent.session_key() => "granted"},
               config(%{measurement: :consent})
             ) == Consent.all()
    end

    test "for_session/2 without a note collects nothing until a no, either" do
      rules = config(%{measurement: :unless_objected})

      assert Consent.for_session(%{}, rules) == Consent.none()
      assert Consent.for_session(%{Consent.session_key() => "unknown"}, rules) == Consent.all()
      assert Consent.for_session(%{Consent.session_key() => "grantedX"}, rules) == Consent.none()
    end
  end

  describe "objected?/1" do
    test "reads Global Privacy Control and Do Not Track" do
      conn = Plug.Test.conn(:get, "/")

      refute Consent.objected?(conn)
      assert Consent.objected?(Plug.Conn.put_req_header(conn, "sec-gpc", "1"))
      assert Consent.objected?(Plug.Conn.put_req_header(conn, "dnt", "1"))
      refute Consent.objected?(Plug.Conn.put_req_header(conn, "dnt", "0"))
    end
  end
end

defmodule PhoenixKitWebAnalytics.ConsentCollectionTest do
  @moduledoc """
  The rules end to end: what reaches the tables for a visitor who agreed,
  refused, or has not answered — through the plug, the beacon endpoint and
  the LiveView hook. Answers come from a host consent source reading a
  request header, so no consent tool needs to be installed.
  """

  use PhoenixKitWebAnalytics.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKitWebAnalytics.BotSignals
  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Consent
  alias PhoenixKitWebAnalytics.Plug, as: TrackingPlug
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Schemas.VisitorProfile
  alias PhoenixKitWebAnalytics.Test.Repo

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @peer %{address: {1, 2, 3, 4}, port: 1, ssl_cert: nil}
  @recording_path "/phoenix-kit/analytics/recording"
  @beacon_path "/phoenix-kit/analytics/event"

  defmodule Source do
    @moduledoc false
    def status(conn, "analytics") do
      case Plug.Conn.get_req_header(conn, "x-test-consent") do
        ["yes"] -> :granted
        ["no"] -> :denied
        ["boom"] -> raise "consent tool down for visitor-7@example.com"
        ["throw"] -> throw(:consent_tool_down)
        ["exit"] -> exit(:consent_tool_down)
        ["string"] -> "granted"
        ["tuple"] -> {:ok, :granted}
        _ -> :unknown
      end
    end

    def status(_conn, _category), do: :unknown
  end

  defmodule Resolver do
    @moduledoc false
    @behaviour PhoenixKitWebAnalytics.Geo

    @impl true
    def resolve(_ip), do: %{country_code: "EE", region: "Harjumaa", city: "Tallinn"}
  end

  @warned {PhoenixKitWebAnalytics.Consent, :source_failed_warned}

  setup do
    Application.put_env(:phoenix_kit_web_analytics, :consent_source, {Source, :status})
    on_exit(fn -> Application.delete_env(:phoenix_kit_web_analytics, :consent_source) end)
    :ok
  end

  defp page(path, headers \\ []) do
    [{"user-agent", @chrome} | headers]
    |> Enum.reduce(Plug.Test.conn(:get, path), fn {k, v}, conn ->
      Plug.Conn.put_req_header(conn, k, v)
    end)
    |> Plug.Test.init_test_session(%{})
    |> TrackingPlug.call(TrackingPlug.init([]))
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, "<html></html>")
  end

  defp events, do: Repo.all(from(e in Event, order_by: [asc: e.inserted_at]))
  defp consent(answer), do: [{"x-test-consent", answer}]

  describe "the source in effect" do
    test "is the host's when configured, and nothing otherwise" do
      assert Consent.source() == {:host, {Source, :status}}

      Application.delete_env(:phoenix_kit_web_analytics, :consent_source)
      assert Consent.source() == :none
    end

    test "a source that says it does not know is taken at its word" do
      assert Consent.status(Plug.Test.conn(:get, "/"), "analytics") == :unknown
    end
  end

  describe "a consent source that fails" do
    setup do
      :persistent_term.erase(@warned)
      on_exit(fn -> :persistent_term.erase(@warned) end)
      :ok
    end

    defp asked(answer),
      do: Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("x-test-consent", answer)

    # Whether the visitor refused could not be read, so it is read as a no.
    test "answers denied when it raises, throws, exits or returns something else" do
      ExUnit.CaptureLog.capture_log(fn ->
        for failure <- ~w(boom throw exit string tuple) do
          assert Consent.status(asked(failure), "analytics") == :denied, failure
        end
      end)
    end

    test "answers denied when the function does not exist" do
      Application.put_env(:phoenix_kit_web_analytics, :consent_source, {Source, :missing})

      ExUnit.CaptureLog.capture_log(fn ->
        assert Consent.status(asked("yes"), "analytics") == :denied
      end)
    end

    test "answers denied when consent_source is not a {module, function} pair" do
      for value <- [Source, {Source, :status, 2}, {"Source", :status}, "MyApp.Consent.status"] do
        Application.put_env(:phoenix_kit_web_analytics, :consent_source, value)

        ExUnit.CaptureLog.capture_log(fn ->
          assert Consent.status(asked("yes"), "analytics") == :denied, inspect(value)
        end)
      end
    end

    test "is logged once per node, naming the source and never the visitor" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..3, do: Consent.status(asked("boom"), "analytics")
          Consent.status(asked("throw"), "analytics")
        end)

      assert length(String.split(log, "the consent source")) == 2
      assert log =~ "ConsentCollectionTest.Source.status/2"
      assert log =~ "RuntimeError"
      refute log =~ "visitor-7@example.com"
    end

    test "does not take the page down, and is not collected from under unless_objected" do
      enable_tracking(%{
        "web_analytics_consent_measurement" => "unless_objected",
        "web_analytics_respect_dnt" => "false"
      })

      ExUnit.CaptureLog.capture_log(fn ->
        for failure <- ~w(boom throw exit string) do
          assert %Plug.Conn{status: 200} = page("/pricing", consent(failure))
        end
      end)

      assert events() == []
    end
  end

  describe "counting visits only after a yes" do
    setup do
      enable_tracking(%{"web_analytics_consent_measurement" => "consent"})
      :ok
    end

    test "a visitor who has not answered leaves nothing" do
      page("/pricing")
      assert events() == []
    end

    test "a visitor who refused leaves nothing" do
      page("/pricing", consent("no"))
      assert events() == []
    end

    test "a visitor who agreed is counted" do
      page("/pricing", consent("yes"))
      assert [%Event{path: "/pricing", event_type: "pageview"}] = events()
    end

    test "the answer is noted in the session for the LiveView hook" do
      conn = page("/pricing", consent("yes"))
      assert Consent.noted(Plug.Conn.get_session(conn)) == {:granted, false}
    end

    test "the note is left on an excluded page too" do
      conn = page("/admin/users", consent("yes"))

      assert events() == []
      assert Consent.noted(Plug.Conn.get_session(conn)) == {:granted, false}
    end
  end

  describe "the default configuration" do
    test "counts everyone and writes nothing to the session" do
      enable_tracking()
      conn = page("/pricing")

      assert [%Event{}] = events()
      refute Map.has_key?(Plug.Conn.get_session(conn), Consent.session_key())
    end
  end

  describe "counting visits until a no" do
    setup do
      # Off, so the browser's objection reaches the consent rule instead of
      # the blunt switch that drops such a visitor in every mode.
      enable_tracking(%{
        "web_analytics_consent_measurement" => "unless_objected",
        "web_analytics_respect_dnt" => "false"
      })

      :ok
    end

    test "a visitor who has not answered is counted" do
      page("/pricing")
      assert [%Event{}] = events()
    end

    test "a visitor who refused is not" do
      page("/pricing", consent("no"))
      assert events() == []
    end

    test "a browser sending Global Privacy Control is an objection on the first request" do
      conn = page("/pricing", [{"sec-gpc", "1"}])

      assert events() == []
      assert Consent.noted(Plug.Conn.get_session(conn)) == {:unknown, true}
    end

    test "a visitor who agreed is counted even with the browser's objection on" do
      page("/pricing", [{"sec-gpc", "1"} | consent("yes")])
      assert [%Event{}] = events()
    end
  end

  describe "a page view that may not be counted, counted without a visitor" do
    setup do
      enable_tracking(%{
        "web_analytics_consent_measurement" => "consent",
        "web_analytics_without_consent" => "anonymous",
        "web_analytics_store_ip" => "full",
        "web_analytics_store_user_agent" => "true"
      })

      :ok
    end

    test "each view is its own visitor and its own visit, with no profile" do
      page("/pricing")
      page("/pricing")

      assert [first, second] = events()
      assert String.starts_with?(first.visitor_id, "anon:")
      assert first.visitor_id != second.visitor_id
      assert first.session_id != second.session_id
      assert first.metadata["anon"] == true
      assert Repo.all(VisitorProfile) == []
    end

    test "the view carries nothing that says who it was" do
      user_uuid = Ecto.UUID.generate()
      opened = DateTime.add(DateTime.utc_now(), -60, :second)

      hit = %{
        event_type: "pageview",
        path: "/pricing",
        site: "myapp.com",
        consent: Consent.none(),
        ip: {203, 0, 113, 5},
        user_agent: @chrome,
        user_uuid: user_uuid,
        roles: ["Admin"],
        headers: %{"http" => "HTTP/2", "names" => ["host"], "values" => %{"host" => "myapp.com"}},
        network: %{asn: 13_335, network: "Example Net", hosting: true},
        query_params: %{"gclid" => "click-abc", "fbclid" => "fb-abc", "utm_source" => "spring"},
        location: %{country_code: "EE", region: "Harjumaa", city: "Tallinn"},
        session_anchor: opened,
        metadata: %{"lv" => true}
      }

      # The same hit from a visitor who agreed, a minute earlier: what the
      # refused one would join, were its anchor or its visitor kept.
      {:ok, agreed} =
        Collector.track(
          %{hit | consent: Consent.all(), user_uuid: nil, session_anchor: nil}
          |> Map.put(:inserted_at, opened)
        )

      assert {:ok, event} = Collector.track(hit)

      assert String.starts_with?(event.visitor_id, "anon:")
      assert event.session_id != agreed.session_id
      assert event.session_start
      assert event.user_uuid == nil
      assert event.traffic_flags == 0
      assert event.click_id == nil
      assert event.click_param == nil
      assert event.utm_source == "spring"
      assert event.country_code == "EE"
      assert event.region == nil
      assert event.city == nil
      assert event.metadata == %{"anon" => true}

      stored = inspect(Repo.get!(Event, event.uuid))
      refute stored =~ user_uuid
      refute stored =~ "click-abc"
      refute stored =~ "fb-abc"
      refute stored =~ "Tallinn"

      # One profile: the visitor's who agreed.
      assert [%VisitorProfile{visitor_id: kept}] = Repo.all(VisitorProfile)
      assert kept == agreed.visitor_id
    end

    test "a resolved location keeps only its country" do
      previous = Application.get_env(:phoenix_kit_web_analytics, :geo_resolver)
      Application.put_env(:phoenix_kit_web_analytics, :geo_resolver, __MODULE__.Resolver)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit_web_analytics, :geo_resolver, previous),
          else: Application.delete_env(:phoenix_kit_web_analytics, :geo_resolver)
      end)

      page("/pricing")
      page("/pricing", consent("yes"))

      assert [anonymous, agreed] = events()
      assert {anonymous.country_code, anonymous.region, anonymous.city} == {"EE", nil, nil}
      assert {agreed.country_code, agreed.region, agreed.city} == {"EE", "Harjumaa", "Tallinn"}
    end

    test "is not a new visitor to alert anyone about" do
      # In an empty sandbox the first user becomes the Owner, who receives
      # the alerts.
      {:ok, user} =
        %User{}
        |> User.registration_changeset(%{
          "email" => "owner#{System.unique_integer([:positive])}@example.com",
          "password" => "ValidPassword123!"
        })
        |> Repo.insert()

      {:ok, _role} = Roles.ensure_first_user_is_owner(user)

      enable_tracking(%{
        "web_analytics_consent_measurement" => "consent",
        "web_analytics_without_consent" => "anonymous",
        "web_analytics_alert_visitors" => "true"
      })

      page("/pricing")
      page("/pricing")
      refute_activity_logged("web_analytics.visitor_arrived")

      # The alert itself works: a visitor who agreed is one.
      page("/pricing", consent("yes"))
      assert_activity_logged("web_analytics.visitor_arrived")
    end

    # A view of its own can never be matched to the live connection that
    # follows it, so it must not be judged for lacking one.
    test "a view of a LiveView page is not judged a no-JavaScript bot" do
      start_supervised!({BotSignals, started_at: DateTime.add(DateTime.utc_now(), -86_400)})

      :sys.get_state(BotSignals)
      opened = hours_ago(2)

      hooked = %{
        event_type: "pageview",
        path: "/shop",
        site: "myapp.com",
        ip: {203, 0, 113, 5},
        user_agent: @chrome,
        metadata: %{"lv" => true},
        inserted_at: opened
      }

      {:ok, anonymous} = Collector.track(Map.put(hooked, :consent, Consent.none()))
      refute Map.has_key?(anonymous.metadata, "lv")

      # The judgement itself works: the same view from a counted visitor,
      # with no live connection after it, is flagged.
      {:ok, counted} = Collector.track(Map.put(hooked, :consent, Consent.all()))

      assert BotSignals.judge_no_js() == 1

      assert Repo.all(from(e in Event, where: e.is_bot, select: e.uuid)) == [counted.uuid]
    end

    test "a visitor who agreed is counted as themselves" do
      page("/pricing", consent("yes"))
      page("/about", consent("yes"))

      assert [first, second] = events()
      refute String.starts_with?(first.visitor_id, "anon:")
      assert first.visitor_id == second.visitor_id
      assert first.session_id == second.session_id
      assert [%VisitorProfile{}] = Repo.all(VisitorProfile)
    end

    test "only the page view survives: what a visitor does needs a visitor", %{conn: conn} do
      enable_tracking(%{
        "web_analytics_consent_measurement" => "consent",
        "web_analytics_without_consent" => "anonymous",
        "web_analytics_beacon_enabled" => "true"
      })

      conn
      |> put_req_header("user-agent", @chrome)
      |> post(@beacon_path, %{"n" => "signup"})

      assert events() == []
    end
  end

  describe "details about a visitor only after a yes" do
    setup do
      enable_tracking(%{
        "web_analytics_consent_profile" => "consent",
        "web_analytics_store_ip" => "full",
        "web_analytics_store_user_agent" => "true",
        "web_analytics_store_headers" => "true"
      })

      :ok
    end

    test "the visit is counted, and nothing says who it was" do
      page("/pricing")

      assert [%Event{}] = events()
      assert Repo.all(VisitorProfile) == []
    end

    test "with a yes the details are kept" do
      page("/pricing", consent("yes"))

      assert [%VisitorProfile{user_agent: @chrome, headers: %{}} = profile] =
               Repo.all(VisitorProfile)

      assert profile.ip != nil
    end
  end

  describe "device measurements only after a yes" do
    @device %{"cv" => "a1b2c3d4", "gr" => "ANGLE (Apple, M2)", "plat" => "Win32", "sw" => 1920}

    setup do
      enable_tracking(%{
        "web_analytics_consent_device" => "consent",
        "web_analytics_client_script" => "true",
        "web_analytics_store_signals" => "true"
      })

      :ok
    end

    defp browser(conn), do: put_req_header(conn, "user-agent", @chrome)

    defp report(conn) do
      conn
      |> put_req_header("content-type", "text/plain")
      |> post(@beacon_path, Jason.encode!(%{"e" => "signals", "s" => @device}))
    end

    test "the script is not told to measure until the visitor agrees", %{conn: conn} do
      assert %{"signals" => false} =
               conn |> browser() |> get(@recording_path, %{"p" => "/"}) |> json_response(200)

      assert %{"signals" => true} =
               conn
               |> browser()
               |> put_req_header("x-test-consent", "yes")
               |> get(@recording_path, %{"p" => "/"})
               |> json_response(200)
    end

    test "measurements sent anyway are not stored", %{conn: conn} do
      conn |> browser() |> report()
      assert Repo.all(VisitorProfile) == []

      build_conn() |> browser() |> put_req_header("x-test-consent", "yes") |> report()
      assert [%VisitorProfile{signals: @device}] = Repo.all(VisitorProfile)
    end
  end

  describe "session recordings only after a yes" do
    setup do
      enable_tracking(%{
        "web_analytics_consent_recording" => "consent",
        "web_analytics_recording" => "true"
      })

      :ok
    end

    test "a page is recorded only for a visitor who agreed", %{conn: conn} do
      assert %{"record" => false} =
               conn
               |> put_req_header("user-agent", @chrome)
               |> get(@recording_path, %{"p" => "/pricing"})
               |> json_response(200)

      assert %{"record" => true} =
               conn
               |> put_req_header("user-agent", @chrome)
               |> put_req_header("x-test-consent", "yes")
               |> get(@recording_path, %{"p" => "/pricing"})
               |> json_response(200)
    end
  end

  describe "the LiveView hook" do
    setup do
      enable_tracking(%{"web_analytics_consent_measurement" => "consent"})
      :ok
    end

    defp live_visit(conn, session) do
      conn
      |> Plug.Test.init_test_session(session)
      |> Plug.Conn.put_private(:live_view_connect_info, %{peer_data: @peer, user_agent: @chrome})
      |> put_connect_params(%{"_live_referer" => "http://www.example.com/"})
      |> live("/shop")
    end

    test "records nothing for a session with no answer noted", %{conn: conn} do
      {:ok, view, _html} = live_visit(conn, %{})
      view |> element("#add") |> render_click()

      assert events() == []
    end

    test "records nothing for a noted refusal", %{conn: conn} do
      {:ok, view, _html} = live_visit(conn, %{Consent.session_key() => "denied"})
      view |> element("#add") |> render_click()

      assert events() == []
    end

    test "records the navigation and the click for a noted yes", %{conn: conn} do
      {:ok, view, _html} = live_visit(conn, %{Consent.session_key() => "granted"})
      view |> element("#add") |> render_click()

      assert [%Event{event_type: "pageview"}, %Event{event_type: "interaction"}] = events()
    end
  end
end
