defmodule PhoenixKitWebAnalytics.Web.NewPagesTest do
  @moduledoc """
  The admin pages added or reworked alongside the LiveView hook: Right now,
  Sessions, one Session's timeline, the Pages → Overview path filter, the
  Events feed by type, and the Settings form's new sections and guards.
  """

  use PhoenixKitWebAnalytics.LiveCase, async: false

  alias PhoenixKitWebAnalytics.LivePresence
  alias PhoenixKitWebAnalytics.Schemas.Recording
  alias PhoenixKitWebAnalytics.Test.Repo

  @base "/en/admin/web-analytics"
  @ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36"

  # ── /live ─────────────────────────────────────────────────────────────────

  describe "paging on a busy site" do
    test "/live switches between each visitor and by page, and ticks the clock", %{conn: conn} do
      server = start_supervised!(LivePresence)
      page = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(page, :kill) end)

      LivePresence.watch(page, %{ip: {1, 2, 3, 4}, user_agent: @ua}, %{
        path: "/tabbed",
        site: "example.com"
      })

      _ = :sys.get_state(server)

      {:ok, view, html} = live(conn, "#{@base}/live")
      assert html =~ "Each visitor"
      assert html =~ "1 page open"

      html = view |> element("button[phx-value-tab='pages']") |> render_click()
      assert html =~ "/tabbed"
      refute html =~ "1 page open"

      # The one-second tick re-renders the clock without a reload.
      send(view.pid, :tick)
      assert render(view) =~ "/tabbed"
    end

    test "/pages pages past the first hundred paths", %{conn: conn} do
      for i <- 1..101, do: insert_event(%{path: "/p#{String.pad_leading(to_string(i), 3, "0")}"})

      {:ok, _view, html} = live(conn, "#{@base}/pages")
      assert html =~ "/p001"
      refute html =~ "/p101"
      assert html =~ "Older"

      {:ok, _view, html} = live(conn, "#{@base}/pages?page=2")
      assert html =~ "/p101"
      refute html =~ "/p001"
      assert html =~ "Newer"
    end

    test "a visit's timeline shows 500 events and then 'Show more'", %{conn: conn} do
      session = UUIDv7.generate()
      start = DateTime.add(DateTime.utc_now(), -3600, :second)

      for i <- 0..501 do
        insert_event(%{
          session_id: session,
          visitor_id: "long",
          path: "/step#{i}",
          inserted_at: DateTime.add(start, i, :second)
        })
      end

      {:ok, view, html} = live(conn, "#{@base}/sessions/#{session}")
      assert html =~ "/step499"
      refute html =~ "/step500"
      assert html =~ "Show more"

      html = view |> element("a", "Show more") |> render_click()
      assert html =~ "/step501"
      refute html =~ "Show more"
    end
  end

  describe "/live" do
    test "lists a watched page when presence is running", %{conn: conn} do
      server = start_supervised!(LivePresence)
      page = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(page, :kill) end)

      LivePresence.watch(page, %{ip: {1, 2, 3, 4}, user_agent: @ua}, %{
        path: "/watched-page",
        site: "example.com"
      })

      _ = :sys.get_state(server)

      {:ok, _view, html} = live(conn, "#{@base}/live")

      assert html =~ "/watched-page"
      assert html =~ "1 online"
      refute html =~ "Live presence isn"
    end

    test "leaves out the site's own open pages and visits", %{conn: conn} do
      enable_tracking()
      server = start_supervised!(LivePresence)

      for {path, flags} <- [{"/visitor-page", 0}, {"/staff-page", 2}] do
        page = spawn(fn -> Process.sleep(:infinity) end)
        on_exit(fn -> Process.exit(page, :kill) end)

        LivePresence.watch(page, %{ip: {1, 2, 3, 4}, user_agent: @ua}, %{
          path: path,
          site: "example.com",
          flags: flags
        })
      end

      insert_event(%{path: "/recent-visitor", inserted_at: DateTime.utc_now()})
      insert_event(%{path: "/recent-staff", traffic_flags: 4, inserted_at: DateTime.utc_now()})
      _ = :sys.get_state(server)

      {:ok, view, html} = live(conn, "#{@base}/live")

      assert html =~ "/visitor-page"
      refute html =~ "/staff-page"
      assert html =~ "/recent-visitor"
      refute html =~ "/recent-staff"
      assert html =~ "1 page open"

      html = view |> element("button[phx-value-tab='pages']") |> render_click()
      assert html =~ "/visitor-page"
      refute html =~ "/staff-page"
    end

    test "warns when presence isn't running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "#{@base}/live")

      assert html =~ "Live presence isn"
      assert html =~ "Nobody has a page open right now."
    end
  end

  # ── /sessions ─────────────────────────────────────────────────────────────

  describe "/sessions" do
    test "lists each visit, linking to its timeline", %{conn: conn} do
      a = UUIDv7.generate()
      b = UUIDv7.generate()

      insert_event(%{session_id: a, visitor_id: "v-a", path: "/landing-a"})
      insert_event(%{session_id: a, visitor_id: "v-a", event_type: "leave", engaged_ms: 5_000})
      insert_event(%{session_id: b, visitor_id: "v-b", path: "/landing-b"})

      {:ok, _view, html} = live(conn, "#{@base}/sessions")

      assert html =~ ~s(href="#{@base}/sessions/#{a}")
      assert html =~ ~s(href="#{@base}/sessions/#{b}")
      assert html =~ "/landing-a"
      assert html =~ "/landing-b"
    end

    test "?user= narrows to that user's visits", %{conn: conn} do
      user = Ecto.UUID.generate()
      mine = UUIDv7.generate()
      other = UUIDv7.generate()

      insert_event(%{session_id: mine, user_uuid: user, path: "/mine"})
      insert_event(%{session_id: other, path: "/other"})

      {:ok, _view, html} = live(conn, "#{@base}/sessions?user=#{user}")

      assert html =~ "/sessions/#{mine}"
      refute html =~ "/sessions/#{other}"
      assert html =~ "Show everyone"
    end

    test "pages 50 at a time with an 'Older' link and ?before=", %{conn: conn} do
      now = DateTime.utc_now()

      # Session 0 is the newest, session 50 the oldest.
      sessions =
        for i <- 0..50 do
          id = UUIDv7.generate()

          insert_event(%{
            session_id: id,
            visitor_id: "v#{i}",
            inserted_at: DateTime.add(now, -i * 60, :second)
          })

          id
        end

      newest = List.first(sessions)
      oldest = List.last(sessions)

      {:ok, view, html} = live(conn, "#{@base}/sessions")

      assert html =~ "Older"
      assert html =~ "/sessions/#{newest}"
      refute html =~ "/sessions/#{oldest}"

      html = view |> element("a", "Older") |> render_click()

      assert html =~ "/sessions/#{oldest}"
      refute html =~ "/sessions/#{newest}"
      refute html =~ "Older"
      assert html =~ "Newer"
    end

    test "the paging links keep the own-traffic and bot switches and the page filter",
         %{conn: conn} do
      now = DateTime.utc_now()

      # 51 visits of the site's own people (flag 2) on /landing: with the
      # switch ticked there is a second page, and its links must keep the switch.
      for i <- 0..50 do
        insert_event(%{
          session_id: UUIDv7.generate(),
          visitor_id: "own#{i}",
          path: "/landing",
          traffic_flags: 2,
          inserted_at: DateTime.add(now, -i * 60, :second)
        })
      end

      {:ok, view, html} = live(conn, "#{@base}/sessions?flagged=1&bots=1&path=/landing")

      [older] = Regex.run(~r/href="([^"]*before=[^"]*)"/, html, capture: :all_but_first)
      older = String.replace(older, "&amp;", "&")
      assert older =~ "flagged=1"
      assert older =~ "bots=1"
      assert older =~ "path=%2Flanding"

      view |> element("a", "Older") |> render_click()
      assert has_element?(view, "input[name='flagged'][checked]")
      assert has_element?(view, "input[name='bots'][checked]")
      assert has_element?(view, "a", "Newer")

      [newer] =
        Regex.run(~r/href="([^"]*)"[^>]*>\s*(?:<[^>]+>\s*)*Newer/s, render(view),
          capture: :all_but_first
        )

      newer = String.replace(newer, "&amp;", "&")
      assert newer =~ "flagged=1"
      assert newer =~ "bots=1"
    end

    test "fewer than 50 visits shows no paging link", %{conn: conn} do
      insert_event(%{})
      {:ok, _view, html} = live(conn, "#{@base}/sessions")
      refute html =~ "Older"
    end
  end

  # ── /sessions/:id ─────────────────────────────────────────────────────────

  describe "/sessions/:id" do
    test "replays the visit in order with a summary", %{conn: conn} do
      id = UUIDv7.generate()
      start = DateTime.add(DateTime.utc_now(), -120, :second)

      insert_event(%{
        session_id: id,
        visitor_id: "v",
        path: "/start",
        referrer_source: "Hacker News",
        inserted_at: start
      })

      insert_event(%{
        session_id: id,
        visitor_id: "v",
        event_type: "interaction",
        event_name: "add_to_cart",
        path: "/start",
        inserted_at: DateTime.add(start, 5, :second)
      })

      insert_event(%{
        session_id: id,
        visitor_id: "v",
        event_type: "leave",
        engaged_ms: 30_000,
        path: "/start",
        inserted_at: DateTime.add(start, 30, :second)
      })

      {:ok, _view, html} = live(conn, "#{@base}/sessions/#{id}")

      viewed = index_of(html, "Viewed page")
      did = index_of(html, "add_to_cart")
      left = index_of(html, "Left after")

      assert viewed < did and did < left
      assert html =~ "Anonymous visitor"
      assert html =~ "Hacker News"
      refute html =~ "This visit isn"
    end

    test "a recorded visit shows the player, which gets the recording on request", %{conn: conn} do
      id = UUIDv7.generate()
      insert_event(%{session_id: id, visitor_id: "v", path: "/start"})

      {:ok, _view, html} = live(conn, "#{@base}/sessions/#{id}")
      refute html =~ "replay-card"

      Repo.insert!(%Recording{
        session_id: id,
        page_key: "pageKey1234567",
        seq: 0,
        path: "/start",
        viewport_w: 1024,
        viewport_h: 700,
        frames: %{"v" => 1, "f" => [[0, "m", 5, 5], [900, "c", 6, 6, "button"]]},
        frame_count: 2
      })

      {:ok, view, html} = live(conn, "#{@base}/sessions/#{id}")
      assert html =~ "replay-card"
      assert html =~ "PhoenixKitWebAnalyticsReplay"

      render_hook(view, "replay_data", %{})

      assert_reply(view, %{pages: [page]})
      # A page this visit viewed: loaded behind the replay, never tracked.
      assert page.url == "/start?pk_replay=1"
      assert {page.w, page.h} == {1024, 700}
      assert page.frames == [[0, "m", 5, 5], [900, "c", 6, 6, "button"]]
    end

    test "a visit flagged by behaviour says why it counts as a bot", %{conn: conn} do
      id = UUIDv7.generate()

      insert_event(%{
        session_id: id,
        visitor_id: "fast",
        path: "/a",
        is_bot: true,
        metadata: %{"bot" => "rate"}
      })

      {:ok, _view, html} = live(conn, "#{@base}/sessions/#{id}")
      assert html =~ "pages faster than a person reads"

      plain = UUIDv7.generate()
      insert_event(%{session_id: plain, visitor_id: "person", path: "/a"})

      {:ok, _view, html} = live(conn, "#{@base}/sessions/#{plain}")
      refute html =~ "faster than a person"
    end

    test "an unknown or malformed id says the visit isn't here", %{conn: conn} do
      {:ok, _view, html} = live(conn, "#{@base}/sessions/#{UUIDv7.generate()}")
      assert html =~ "This visit isn"

      {:ok, _view, html} = live(conn, "#{@base}/sessions/not-a-uuid")
      assert html =~ "This visit isn"
    end
  end

  # ── /pages and the path filter ────────────────────────────────────────────

  describe "/pages → overview path filter" do
    test "a path row links to the overview filtered to that path", %{conn: conn} do
      insert_event(%{path: "/pricing"})

      {:ok, _view, html} = live(conn, "#{@base}/pages")

      assert html =~ ~r{href="#{@base}\?[^"]*path=%2Fpricing}
    end

    test "the overview with ?path= shows the chip and only that path's numbers",
         %{conn: conn} do
      for i <- 1..3, do: insert_event(%{path: "/pricing", visitor_id: "p#{i}"})
      for i <- 1..5, do: insert_event(%{path: "/about", visitor_id: "a#{i}"})

      {:ok, _view, all_html} = live(conn, @base)
      assert page_views(all_html) == "8"

      {:ok, _view, html} = live(conn, "#{@base}?path=/pricing")

      assert page_views(html) == "3"
      assert html =~ ~r{<a[^>]*badge-primary[^>]*>\s*/pricing}
    end
  end

  # ── /events ───────────────────────────────────────────────────────────────

  describe "/events feed" do
    setup do
      session = UUIDv7.generate()
      insert_event(%{session_id: session, path: "/viewed"})

      insert_event(%{
        session_id: session,
        event_type: "interaction",
        event_name: "add_to_cart",
        path: "/clicked"
      })

      insert_event(%{
        session_id: session,
        event_type: "leave",
        engaged_ms: 1_000,
        path: "/exited"
      })

      {:ok, session: session}
    end

    test "all hits by default, each linking to its session", %{conn: conn, session: session} do
      {:ok, _view, html} = live(conn, "#{@base}/events")

      assert html =~ "/viewed"
      assert html =~ "/clicked"
      assert html =~ "/exited"
      assert html =~ ~s(href="#{@base}/sessions/#{session}")
    end

    test "feed type interaction shows only interactions", %{conn: conn} do
      {:ok, view, _html} = live(conn, "#{@base}/events")

      html =
        view |> form("#web-analytics-feed-type", %{feed_type: "interaction"}) |> render_change()

      assert html =~ "/clicked"
      refute html =~ "/viewed"
      refute html =~ "/exited"
    end

    test "feed type leave shows only exits", %{conn: conn} do
      {:ok, view, _html} = live(conn, "#{@base}/events")

      html = view |> form("#web-analytics-feed-type", %{feed_type: "leave"}) |> render_change()

      assert html =~ "/exited"
      assert html =~ "Left after"
      refute html =~ "/viewed"
      refute html =~ "/clicked"
    end
  end

  # ── /settings ─────────────────────────────────────────────────────────────

  describe "/settings" do
    test "renders the alerts and interactions sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, "#{@base}/settings")

      assert html =~ "What visitors do"
      assert html =~ "Alerts"
      assert html =~ ~s(name="alert_channels[])
      assert html =~ ~s(name="alert_max_per_hour")
      assert html =~ ~s(name="ignore_events")
    end

    test "an invalid number saves nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "#{@base}/settings")

      html =
        view
        |> form("#web-analytics-settings", %{
          session_timeout: "0",
          ignore_events: "should-not-be-saved"
        })
        |> render_submit()

      assert html =~ "Nothing was saved"
      assert html =~ "Visit timeout"
      refute html =~ "Settings saved."

      assert PhoenixKit.Settings.get_setting("web_analytics_ignore_events", nil) !=
               "should-not-be-saved"
    end

    test "saving logs settings.updated with the admin as actor and the changed keys",
         %{conn: conn} do
      scope = fake_scope()
      {:ok, view, _html} = conn |> put_test_scope(scope) |> live("#{@base}/settings")

      html =
        view
        |> element("form[phx-submit='save']")
        |> render_submit(%{"_form" => "settings", "retention_days" => "77"})

      assert html =~ "Settings saved."

      row = assert_activity_logged("settings.updated", actor_uuid: scope.user.uuid)
      assert "web_analytics_retention_days" in row.metadata["changed"]
    end

    test "rotating the salt and running retention carry the admin as actor", %{conn: conn} do
      enable_tracking()
      scope = fake_scope()
      {:ok, view, _html} = conn |> put_test_scope(scope) |> live("#{@base}/settings")

      view |> element("button[phx-click='rotate_salt']") |> render_click()
      assert_activity_logged("salt.rotated", actor_uuid: scope.user.uuid)

      view |> element("button[phx-click='run_retention']") |> render_click()
      # The pass runs in start_async; its result comes back as a flash.
      assert render_async(view) =~ "Rolled up"
      assert_activity_logged("retention.run", actor_uuid: scope.user.uuid)
    end

    test "turning tracking on logs tracking.enabled with the admin as actor", %{conn: conn} do
      scope = fake_scope()
      {:ok, view, _html} = conn |> put_test_scope(scope) |> live("#{@base}/settings")

      html = view |> element("button[phx-click=toggle_tracking]") |> render_click()

      assert html =~ "Tracking is on"
      assert_activity_logged("tracking.enabled", actor_uuid: scope.user.uuid)
    end

    test "every submit and action button carries phx-disable-with", %{conn: conn} do
      enable_tracking()
      {:ok, _view, html} = live(conn, "#{@base}/settings")

      buttons =
        ~r{<button[^>]*>}
        |> Regex.scan(html)
        |> List.flatten()
        |> Enum.filter(&(&1 =~ ~s(type="submit") or &1 =~ "phx-click"))

      assert length(buttons) >= 4

      for button <- buttons do
        assert button =~ "phx-disable-with", "missing phx-disable-with: #{button}"
      end
    end
  end

  # ── resilience ────────────────────────────────────────────────────────────

  describe "every page" do
    test "survives an unexpected message", %{conn: conn} do
      session = UUIDv7.generate()
      insert_event(%{session_id: session})

      paths = [
        @base,
        "#{@base}/pages",
        "#{@base}/sources",
        "#{@base}/technology",
        "#{@base}/events",
        "#{@base}/settings",
        "#{@base}/live",
        "#{@base}/sessions",
        "#{@base}/sessions/#{session}"
      ]

      for path <- paths do
        {:ok, view, _html} = live(conn, path)
        send(view.pid, :garbage)
        assert is_binary(render(view)), "#{path} did not render after :garbage"
        assert Process.alive?(view.pid), "#{path} died on :garbage"
      end
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp index_of(html, needle) do
    case :binary.match(html, needle) do
      {index, _} -> index
      :nomatch -> flunk("#{inspect(needle)} not found")
    end
  end

  defp page_views(html) do
    case Regex.run(~r{id="stat-pageviews".*?text-2xl[^>]*>\s*([\d,]+)\s*<}s, html) do
      [_, value] -> value
      nil -> flunk("no Page views tile")
    end
  end
end
