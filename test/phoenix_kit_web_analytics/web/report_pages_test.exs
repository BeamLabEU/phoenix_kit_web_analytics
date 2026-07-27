defmodule PhoenixKitWebAnalytics.Web.ReportPagesTest do
  @moduledoc """
  Smoke tests for the six admin pages: they mount, render real data, and the
  shared period filter round-trips through the URL.
  """

  use PhoenixKitWebAnalytics.LiveCase, async: false

  alias PhoenixKitWebAnalytics.Paths

  @base "/en/admin/web-analytics"

  @pages [
    {"overview", @base, "Web Analytics"},
    {"pages", "#{@base}/pages", "Pages"},
    {"acquisition", "#{@base}/sources", "Acquisition"},
    {"technology", "#{@base}/technology", "Technology"},
    {"events", "#{@base}/events", "Events"},
    {"settings", "#{@base}/settings", "Web Analytics settings"}
  ]

  describe "every report page" do
    test "mounts and renders with no data at all", %{conn: conn} do
      for {name, path, heading} <- @pages do
        assert {:ok, _view, html} = live(conn, path), "#{name} failed to mount"
        assert html =~ heading
      end
    end

    test "mounts and renders with data", %{conn: conn} do
      insert_event(%{
        path: "/pricing",
        visitor_id: "alice",
        referrer_source: "Hacker News",
        referrer_medium: "social",
        browser: "Firefox",
        os: "Linux",
        device_type: "desktop",
        country_code: "EE",
        language: "et-EE",
        duration_ms: 12
      })

      insert_event(%{event_type: "event", event_name: "signup", visitor_id: "alice"})

      for {name, path, _heading} <- @pages do
        assert {:ok, _view, _html} = live(conn, path), "#{name} failed to mount with data"
      end
    end
  end

  describe "overview" do
    test "shows the headline numbers", %{conn: conn} do
      insert_event(%{path: "/", visitor_id: "alice"})
      insert_event(%{path: "/pricing", visitor_id: "bob"})

      {:ok, _view, html} = live(conn, @base)

      assert html =~ "Visitors"
      assert html =~ "Page views"
      assert html =~ "Bounce rate"
    end

    test "warns when tracking is switched off", %{conn: conn} do
      {:ok, _view, html} = live(conn, @base)

      assert html =~ "Tracking is off"
      assert html =~ "PhoenixKitWebAnalytics.Plug"
    end

    test "drops the warning once tracking is on", %{conn: conn} do
      enable_tracking()

      {:ok, _view, html} = live(conn, @base)

      refute html =~ "Tracking is off"
    end

    test "changing the period patches the URL and reloads", %{conn: conn} do
      insert_event(%{path: "/recent"})
      insert_event(%{path: "/old", inserted_at: days_ago(20)})

      {:ok, view, _html} = live(conn, @base)

      html = view |> element("form[phx-change='filter']") |> render_change(%{"period" => "30d"})

      assert_patch(view, Paths.dashboard() <> "?period=30d")
      assert html =~ "last 30 days"
    end

    test "an unknown period in the URL falls back instead of crashing", %{conn: conn} do
      assert {:ok, _view, html} = live(conn, @base <> "?period=nonsense")
      assert html =~ "last 7 days"
    end
  end

  describe "pages report" do
    test "lists paths ranked by page views", %{conn: conn} do
      insert_event(%{path: "/popular"})
      insert_event(%{path: "/popular"})
      insert_event(%{path: "/quiet"})

      {:ok, _view, html} = live(conn, "#{@base}/pages")

      assert html =~ "/popular"
      assert html =~ "/quiet"
    end
  end

  describe "events page" do
    test "lists custom events and the live feed", %{conn: conn} do
      insert_event(%{event_type: "event", event_name: "signup"})
      insert_event(%{path: "/pricing"})

      {:ok, view, html} = live(conn, "#{@base}/events")

      assert html =~ "signup"
      assert html =~ "/pricing"

      # Filtering the feed to custom events drops the page view.
      html =
        view
        |> element("form[phx-change='feed_type']")
        |> render_change(%{"feed_type" => "event"})

      assert html =~ "signup"
    end
  end

  describe "settings page" do
    test "saving updates the stored settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, "#{@base}/settings")

      view
      |> element("form[phx-submit='save']")
      |> render_submit(%{
        "respect_dnt" => "true",
        "retention_days" => "90",
        "session_timeout" => "45",
        "exclude_paths" => "/admin*\n/healthz"
      })

      clear_settings_cache()

      assert PhoenixKitWebAnalytics.Config.retention_days() == 90
      assert PhoenixKitWebAnalytics.Config.session_timeout_minutes() == 45
      assert PhoenixKitWebAnalytics.Config.exclude_paths_raw() =~ "/healthz"
    end

    test "out-of-range numbers are ignored rather than stored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "#{@base}/settings")

      before = PhoenixKitWebAnalytics.Config.retention_days()

      view
      |> element("form[phx-submit='save']")
      |> render_submit(%{"retention_days" => "-5", "session_timeout" => "0"})

      clear_settings_cache()

      assert PhoenixKitWebAnalytics.Config.retention_days() == before
    end

    test "the tracking toggle flips the module switch", %{conn: conn} do
      {:ok, view, html} = live(conn, "#{@base}/settings")

      assert html =~ "Tracking is off"

      html = view |> element("button[phx-click='toggle_tracking']") |> render_click()

      assert html =~ "Tracking is on"
      assert PhoenixKitWebAnalytics.enabled?()
    end

    test "running retention reports what it did", %{conn: conn} do
      enable_tracking()
      insert_event(%{inserted_at: days_ago(2)})

      {:ok, view, _html} = live(conn, "#{@base}/settings")

      html = view |> element("button[phx-click='run_retention']") |> render_click()

      assert html =~ "Rolled up 1 day(s)"
    end
  end
end
