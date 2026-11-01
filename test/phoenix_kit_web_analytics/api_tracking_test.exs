defmodule PhoenixKitWebAnalytics.ApiTrackingTest do
  @moduledoc """
  `web_analytics_track_api_paths`: requests to the listed paths are stored as
  `"api"` events, under the same rules as page views, and never counted as
  page views, visitors, visits, bounces, entries or exits.
  """

  use PhoenixKitWebAnalytics.DataCase, async: false

  import Plug.Test, only: [conn: 3]

  alias PhoenixKitWebAnalytics.BotSignals
  alias PhoenixKitWebAnalytics.Plug, as: TrackingPlug
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Retention
  alias PhoenixKitWebAnalytics.Schemas.DailyDim
  alias PhoenixKitWebAnalytics.Schemas.DailyStat
  alias PhoenixKitWebAnalytics.Schemas.Event

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  setup do
    enable_tracking(%{"web_analytics_track_api_paths" => "/api/*\n/bank/_api/*"})
    :ok
  end

  defp request(method, path, opts \\ []) do
    headers = [{"user-agent", Keyword.get(opts, :ua, @chrome)} | Keyword.get(opts, :headers, [])]

    Enum.reduce(headers, %{conn(method, path, "") | remote_ip: {203, 0, 113, 5}}, fn {k, v}, c ->
      Plug.Conn.put_req_header(c, k, v)
    end)
    |> TrackingPlug.call(TrackingPlug.init(Keyword.get(opts, :plug, [])))
    |> Plug.Conn.put_resp_content_type(Keyword.get(opts, :type, "application/json"))
    |> Plug.Conn.send_resp(Keyword.get(opts, :status, 200), "{}")
  end

  defp page(path), do: request(:get, path, type: "text/html")

  defp api_events, do: Repo.all(from(e in Event, where: e.event_type == "api"))

  defp filter, do: Reports.filter(period: "today")

  describe "what is stored" do
    test "any method and any 2xx–4xx status, with both" do
      request(:post, "/api/orders", status: 201)
      request(:get, "/api/search?q=secret")
      request(:delete, "/bank/_api/x", status: 404)
      request(:put, "/api/broken", status: 500)

      events = Enum.sort_by(api_events(), & &1.status)

      assert [
               {"GET", "/api/search", 200},
               {"POST", "/api/orders", 201},
               {"DELETE", "/bank/_api/x", 404}
             ] =
               Enum.map(events, &{&1.event_name, &1.path, &1.status})

      refute inspect(events) =~ "secret"
      assert Enum.all?(events, &(&1.session_start == false))
      assert Enum.all?(events, &(&1.browser == "Chrome"))
    end

    test "an HTML response on an API path is an API request, not a page view" do
      request(:get, "/api/widget", type: "text/html")

      assert [%Event{event_type: "api"}] = Repo.all(Event)
    end

    test "nothing while the setting is empty" do
      enable_tracking(%{"web_analytics_track_api_paths" => ""})
      request(:post, "/api/orders")
      request(:get, "/api/search")

      assert Repo.all(Event) == []
    end

    test "Do Not Track, exclusions, bots, consent and prefetches are honoured" do
      request(:post, "/api/a", headers: [{"dnt", "1"}])
      request(:post, "/api/b", plug: [exclude: ["/api/b"]])
      request(:post, "/api/c", ua: "Googlebot/2.1 (+http://www.google.com/bot.html)")
      request(:get, "/api/d", headers: [{"sec-purpose", "prefetch"}])
      assert Repo.all(Event) == []

      enable_tracking(%{"web_analytics_consent_measurement" => "consent"})
      request(:post, "/api/e")
      assert Repo.all(Event) == []
    end

    test "a visitor is held to the per-minute rate, per visitor and per network" do
      start_supervised!(BotSignals)
      Application.put_env(:phoenix_kit_web_analytics, :api_events_per_minute, 2)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_web_analytics, :api_events_per_minute)
      end)

      for _ <- 1..4, do: request(:get, "/api/search")
      assert length(api_events()) == 2

      # Fresh User-Agents are fresh visitors, but one network: 4 × 2 a
      # minute, and the four requests above already count against it.
      for n <- 1..10, do: request(:get, "/api/search", ua: "agent #{n}")
      assert length(api_events()) == 6
    end

    test "prefetches are skipped for every method" do
      for method <- [:get, :head, :post] do
        request(method, "/api/search", headers: [{"sec-purpose", "prefetch;prerender"}])
      end

      assert api_events() == []
    end
  end

  describe "never a page view or part of a visit" do
    test "API requests alone count no visitor, visit or page" do
      request(:get, "/api/search")
      request(:post, "/api/orders")

      overview = Reports.overview(filter())
      assert overview.pageviews == 0
      assert overview.visitors == 0
      assert overview.sessions == 0
      assert overview.events == 0
      assert Reports.sessions(filter()) == []
      assert Reports.top_paths(filter()) == []
      assert Reports.active_visitors() == 0
      assert {[], nil} = Reports.recent_sessions(30)
    end

    test "a visit around API requests stays one visit, its pages unchanged" do
      page("/catalog")
      request(:get, "/api/search")
      page("/item")
      request(:get, "/api/search")

      [first, second] =
        Repo.all(from(e in Event, where: e.event_type == "pageview", order_by: e.inserted_at))

      assert first.session_id == second.session_id
      assert first.session_start
      refute second.session_start

      assert Enum.all?(api_events(), &(&1.session_id != first.session_id))

      assert [visit] = Reports.sessions(filter())
      assert visit.pageviews == 2
      assert visit.entry_path == "/catalog"
      assert visit.exit_path == "/item"

      overview = Reports.overview(filter())
      assert overview.pageviews == 2
      assert overview.visitors == 1
      assert overview.sessions == 1
      assert overview.bounce_rate == 0.0
    end

    test "a page view after an API request starts its visit" do
      request(:get, "/api/search")
      page("/catalog")

      assert [%Event{session_start: true}] =
               Repo.all(from(e in Event, where: e.event_type == "pageview"))

      assert [%{pageviews: 1, entry_path: "/catalog"}] = Reports.sessions(filter())
    end

    test "the rollup of a day leaves API requests out" do
      date = Date.add(Date.utc_today(), -2)
      at = DateTime.new!(date, ~T[10:00:00], "Etc/UTC")
      session = UUIDv7.generate()

      insert_event(%{visitor_id: "a", session_id: session, path: "/", inserted_at: at})

      for n <- 1..3 do
        insert_event(%{
          event_type: "api",
          event_name: "GET",
          status: 200,
          visitor_id: "api-#{n}",
          path: "/api/search",
          inserted_at: DateTime.add(at, n, :second)
        })
      end

      assert :ok = Retention.rollup_day(date)
      assert [stat] = Repo.all(DailyStat)

      assert {stat.pageviews, stat.visitors, stat.sessions, stat.bounces, stat.events} ==
               {1, 1, 1, 1, 0}

      pages = Repo.all(from(d in DailyDim, where: d.dimension == "page"))
      assert Enum.map(pages, & &1.value) == ["/"]
    end
  end

  describe "Reports.api_requests/2" do
    test "counts, statuses and the busiest requests" do
      request(:get, "/api/search")
      request(:get, "/api/search")
      request(:post, "/api/orders", status: 422)
      page("/catalog")

      assert %{requests: 3, visitors: 1, statuses: statuses, paths: paths} =
               Reports.api_requests(filter())

      assert [%{label: "2xx", pageviews: 2}, %{label: "4xx", pageviews: 1}] = statuses
      assert [%{label: "GET /api/search", pageviews: 2}, %{label: "POST /api/orders"}] = paths

      assert [%Event{event_type: "api"}, %Event{event_type: "api"}, %Event{event_type: "api"}] =
               Reports.recent_hits(filter(), event_type: "api")
    end
  end
end

defmodule PhoenixKitWebAnalytics.ApiTrackingLiveTest do
  @moduledoc "The Events page's API panel and the Settings field."

  use PhoenixKitWebAnalytics.LiveCase, async: false

  test "Events shows API requests once the setting lists a path", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/web-analytics/events")
    refute html =~ "api-requests"

    enable_tracking(%{"web_analytics_track_api_paths" => "/api/*"})

    insert_event(%{
      event_type: "api",
      event_name: "POST",
      status: 201,
      path: "/api/orders"
    })

    {:ok, view, _html} = live(conn, "/admin/web-analytics/events")
    assert view |> element("#api-requests") |> render() =~ "POST /api/orders"
    assert view |> element("#api-requests") |> render() =~ "2xx"
    assert view |> element("#live-feed") |> render() =~ "API POST · 201"
  end

  test "Settings saves the API paths", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/web-analytics/settings")

    view
    |> form("#web-analytics-settings", %{"track_api_paths" => "/api/*\n/bank/_api/*"})
    |> render_submit()

    clear_settings_cache()

    assert PhoenixKitWebAnalytics.Config.collection_config().api_paths == [
             "/api/*",
             "/bank/_api/*"
           ]
  end
end
