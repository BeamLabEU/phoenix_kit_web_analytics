defmodule PhoenixKitWebAnalytics.CollectorTest do
  use PhoenixKitWebAnalytics.DataCase, async: false

  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Schemas.Event

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  defp hit(attrs \\ %{}) do
    Map.merge(
      %{
        path: "/pricing",
        site: "myapp.com",
        ip: {203, 0, 113, 5},
        user_agent: @chrome
      },
      attrs
    )
  end

  describe "track/1 when tracking is off" do
    test "records nothing" do
      assert {:error, :disabled} = Collector.track(hit())
      assert Repo.aggregate(Event, :count) == 0
    end
  end

  describe "track/1" do
    setup do
      enable_tracking()
      :ok
    end

    test "stores a page view with a derived client, visitor, and session" do
      assert {:ok, event} = Collector.track(hit())

      assert event.event_type == "pageview"
      assert event.path == "/pricing"
      assert event.site == "myapp.com"
      assert event.browser == "Chrome"
      assert event.os == "Windows"
      assert event.device_type == "desktop"
      assert String.length(event.visitor_id) == 32
      assert event.session_id
    end

    test "never stores the IP address" do
      assert {:ok, event} = Collector.track(hit())

      # The whole address, never a fragment: a hex hash can contain "203".
      refute event |> Map.from_struct() |> inspect() =~ "203.0.113.5"
      refute Map.has_key?(event, :ip_address)
      refute event.metadata |> inspect() =~ "203.0.113"
    end

    test "requires a path" do
      assert {:error, :invalid} = Collector.track(%{site: "myapp.com"})
    end

    test "drops bot traffic by default" do
      assert {:error, :bot} = Collector.track(hit(%{user_agent: "Googlebot/2.1"}))
      assert Repo.aggregate(Event, :count) == 0
    end

    test "records bots when the setting is on" do
      enable_tracking(%{"web_analytics_track_bots" => "true"})

      assert {:ok, event} = Collector.track(hit(%{user_agent: "Googlebot/2.1"}))
      assert event.is_bot
      assert event.device_type == "bot"
    end
  end

  describe "path and query normalization" do
    setup do
      enable_tracking()
      :ok
    end

    test "strips the query string and fragment, and normalizes trailing slashes" do
      assert {:ok, event} = Collector.track(hit(%{path: "/blog/post?token=secret#section"}))

      assert event.path == "/blog/post"

      assert {:ok, root} = Collector.track(hit(%{path: "/"}))
      assert root.path == "/"

      assert {:ok, trailing} = Collector.track(hit(%{path: "/docs/"}))
      assert trailing.path == "/docs"
    end

    test "a one-time token in the path of core's own routes is never stored" do
      for {given, stored} <- [
            {"/users/reset-password/SeCrEt123", "/users/reset-password/:token"},
            {"/users/confirm/SeCrEt123", "/users/confirm/:token"},
            {"/users/confirm/change-email/SeCrEt123", "/users/confirm/change-email/:token"},
            {"/users/magic-link/SeCrEt123", "/users/magic-link/:token"},
            {"/et/users/register/verify/SeCrEt123", "/et/users/register/verify/:token"},
            {"/phoenix_kit/users/qr-login/scan/SeCrEt123",
             "/phoenix_kit/users/qr-login/scan/:token"},
            {"/profile/settings/confirm-email/SeCrEt123",
             "/profile/settings/confirm-email/:token"},
            {"/access/link/SeCrEt123", "/access/link/:token"}
          ] do
        assert {:ok, event} = Collector.track(hit(%{path: given}))
        assert event.path == stored
      end

      # An ordinary page under a similar name is left alone.
      assert {:ok, event} = Collector.track(hit(%{path: "/users/confirm"}))
      assert event.path == "/users/confirm"
      assert {:ok, event} = Collector.track(hit(%{path: "/blog/confirm/order"}))
      assert event.path == "/blog/confirm/order"
    end

    test "a NUL byte in a field costs nothing — the hit is still stored, without it" do
      assert {:ok, event} =
               Collector.track(
                 hit(%{
                   path: "/pri\0cing",
                   query_params: %{"utm_source" => "a\0b"},
                   metadata: %{"params" => %{"tab" => "x\0y"}}
                 })
               )

      assert event.path == "/pricing"
      assert event.utm_source == "ab"
      assert event.metadata == %{"params" => %{"tab" => "xy"}}
    end

    test "campaign parameters are stored in their own columns" do
      assert {:ok, event} =
               Collector.track(
                 hit(%{
                   query_params: %{
                     "utm_source" => "newsletter",
                     "utm_medium" => "email",
                     "utm_campaign" => "spring"
                   }
                 })
               )

      assert event.utm_source == "newsletter"
      assert event.utm_campaign == "spring"
      assert event.referrer_medium == "email"
      assert event.referrer_source == "newsletter"
    end

    test "an auto-tagged ad click is recorded as paid, with its identifier" do
      assert {:ok, event} =
               Collector.track(hit(%{query_params: %{"gclid" => "EAIaIQobChMI"}}))

      assert event.click_id == "EAIaIQobChMI"
      assert event.click_param == "gclid"
      # Without this the visit would land in the table as "direct": an
      # auto-tagged ad URL carries no utm_medium and no referrer.
      assert event.referrer_medium == "paid"
      assert event.referrer_source == "Google"
    end

    test "each ad-only identifier names its own platform and parameter" do
      for {param, source} <- [
            {"gbraid", "Google"},
            {"wbraid", "Google"},
            {"msclkid", "Bing"},
            {"ttclid", "TikTok"},
            {"li_fat_id", "LinkedIn"}
          ] do
        assert {:ok, event} = Collector.track(hit(%{query_params: %{param => "xyz"}}))
        assert event.click_param == param
        assert event.referrer_source == source
        assert event.referrer_medium == "paid"
      end
    end

    test "an ad-only identifier names its platform over another site's Referer" do
      assert {:ok, event} =
               Collector.track(
                 hit(%{referrer: "https://duckduckgo.com/", query_params: %{"msclkid" => "m1"}})
               )

      assert event.referrer_source == "Bing"
      assert event.referrer_medium == "paid"
    end

    test "gclid wins over fbclid when a URL carries both" do
      assert {:ok, event} =
               Collector.track(hit(%{query_params: %{"fbclid" => "f1", "gclid" => "g1"}}))

      assert event.click_param == "gclid"
      assert event.referrer_medium == "paid"
    end

    test "a search ad click with Google's Referer is paid, not organic" do
      assert {:ok, event} =
               Collector.track(
                 hit(%{referrer: "https://www.google.com/", query_params: %{"gclid" => "g1"}})
               )

      assert event.referrer_source == "Google"
      assert event.referrer_medium == "paid"
    end

    test "an ad-only identifier wins over a non-paid utm_medium" do
      assert {:ok, event} =
               Collector.track(hit(%{query_params: %{"gclid" => "g1", "utm_medium" => "email"}}))

      assert event.referrer_medium == "paid"
    end

    test "explicit utm_source keeps its own source, the click id is still stored" do
      assert {:ok, event} =
               Collector.track(
                 hit(%{
                   query_params: %{
                     "gclid" => "abc123",
                     "utm_source" => "spring-newsletter",
                     "utm_campaign" => "spring-sale"
                   }
                 })
               )

      assert event.click_id == "abc123"
      assert event.utm_campaign == "spring-sale"
      assert event.referrer_source == "spring-newsletter"
      assert event.referrer_medium == "paid"
    end

    test "fbclid is stored but counts as social, not paid" do
      # Meta appends fbclid to organic link clicks too, so on its own it
      # proves the visitor came from Facebook, not that they clicked an ad.
      assert {:ok, event} = Collector.track(hit(%{query_params: %{"fbclid" => "IwAR0abc"}}))

      assert event.click_id == "IwAR0abc"
      assert event.click_param == "fbclid"
      assert event.referrer_source == "Facebook"
      assert event.referrer_medium == "social"

      assert {:ok, tagged} =
               Collector.track(
                 hit(%{query_params: %{"fbclid" => "IwAR0abc", "utm_medium" => "cpc"}})
               )

      assert tagged.referrer_medium == "paid"
    end

    test "fbclid does not override the Referer it arrived with" do
      # Instagram clicks carry fbclid too.
      assert {:ok, event} =
               Collector.track(
                 hit(%{
                   referrer: "https://l.instagram.com/",
                   query_params: %{"fbclid" => "IwAR0abc"}
                 })
               )

      assert event.referrer_source == "Instagram"
      assert event.referrer_medium == "social"
      assert event.click_param == "fbclid"
    end

    test "an internal hit stays internal when the click id rides along" do
      # Google's url_passthrough appends gclid to every internal link of an
      # ad visit; those page views must not count as fresh paid arrivals.
      for param <- ["gclid", "fbclid"] do
        assert {:ok, event} =
                 Collector.track(
                   hit(%{
                     referrer: "https://myapp.com/catalogue",
                     query_params: %{param => "c1"}
                   })
                 )

        assert event.referrer_medium == "internal"
        assert event.referrer_source == nil
        assert event.click_id == "c1"
      end
    end

    test "the first click identifier in click_param_names/0 order wins" do
      # Alphabetical (map) order would pick msclkid; the list puts wbraid first.
      assert {:ok, event} =
               Collector.track(hit(%{query_params: %{"msclkid" => "m1", "wbraid" => "w1"}}))

      assert event.click_id == "w1"
      assert event.click_param == "wbraid"
    end

    test "a hit with no click identifier leaves both columns empty" do
      assert {:ok, event} = Collector.track(hit(%{query_params: %{"utm_source" => "hn"}}))

      assert is_nil(event.click_id)
      assert is_nil(event.click_param)
    end

    test "an over-long click identifier is truncated, not rejected" do
      assert {:ok, event} =
               Collector.track(hit(%{query_params: %{"gclid" => String.duplicate("a", 300)}}))

      assert byte_size(event.click_id) == 255
    end

    test "a campaign value that isn't valid UTF-8 is dropped, the hit is kept" do
      assert {:ok, event} =
               Collector.track(
                 hit(%{query_params: %{"gclid" => <<0xFF>>, "utm_source" => <<0xFE, 0x41>>}})
               )

      assert is_nil(event.click_id)
      assert is_nil(event.utm_source)
      assert event.referrer_medium == "none"
    end

    test "a click identifier that is only NULs is no identifier" do
      assert {:ok, event} = Collector.track(hit(%{query_params: %{"gclid" => <<0, 0>>}}))

      assert is_nil(event.click_id)
      assert is_nil(event.click_param)
      assert event.referrer_medium == "none"
    end

    test "the Referer header classifies the source when there is no campaign" do
      assert {:ok, event} =
               Collector.track(hit(%{referrer: "https://news.ycombinator.com/item?id=1"}))

      assert event.referrer_source == "Hacker News"
      assert event.referrer_medium == "social"
    end

    test "same-site referrers are internal, not referrals" do
      assert {:ok, event} = Collector.track(hit(%{referrer: "https://myapp.com/blog"}))

      assert event.referrer_medium == "internal"
      assert event.referrer_source == nil
    end
  end

  describe "session stitching" do
    setup do
      enable_tracking()
      :ok
    end

    test "consecutive hits from one visitor share a session" do
      assert {:ok, first} = Collector.track(hit())
      assert {:ok, second} = Collector.track(hit(%{path: "/docs"}))

      assert first.visitor_id == second.visitor_id
      assert first.session_id == second.session_id
    end

    test "a different visitor gets a different session" do
      assert {:ok, first} = Collector.track(hit())
      assert {:ok, other} = Collector.track(hit(%{ip: {203, 0, 113, 99}}))

      refute first.visitor_id == other.visitor_id
      refute first.session_id == other.session_id
    end

    test "a gap longer than the timeout starts a new session" do
      assert {:ok, first} = Collector.track(hit(%{inserted_at: hours_ago(2)}))
      assert {:ok, second} = Collector.track(hit())

      assert first.visitor_id == second.visitor_id
      refute first.session_id == second.session_id
    end

    test "resolve_session/3 reuses a session inside the window and mints one outside it" do
      assert {:ok, event} = Collector.track(hit())

      assert Collector.resolve_session(event.visitor_id, 30, DateTime.utc_now()) ==
               event.session_id

      later = DateTime.add(DateTime.utc_now(), 3600, :second)
      refute Collector.resolve_session(event.visitor_id, 30, later) == event.session_id
    end
  end

  describe "custom events" do
    setup do
      enable_tracking()
      :ok
    end

    test "track_event/2 stores a named event with its properties" do
      assert {:ok, event} =
               Collector.track(
                 hit(%{
                   event_type: "event",
                   event_name: "signup",
                   metadata: %{"plan" => "pro"}
                 })
               )

      assert event.event_type == "event"
      assert event.event_name == "signup"
      assert event.metadata == %{"plan" => "pro"}
    end

    test "a custom event without a name is rejected" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Collector.track(hit(%{event_type: "event"}))

      assert %{event_name: _} = errors_on(changeset)
    end
  end

  describe "referrer storage" do
    setup do
      enable_tracking()
      :ok
    end

    test "drops the query string, fragment and userinfo of an absolute referrer" do
      assert {:ok, event} =
               Collector.track(hit(%{referrer: "https://bob:hunter2@app.com/reset?token=abc#x"}))

      assert event.referrer == "https://app.com/reset"

      stored = Repo.get!(Event, event.uuid)
      assert stored.referrer == "https://app.com/reset"
      refute stored.referrer =~ "token"
      refute stored.referrer =~ "hunter2"
    end

    test "a relative referrer keeps only the part before ? or #" do
      assert {:ok, event} = Collector.track(hit(%{referrer: "/account/reset?token=abc#frag"}))

      assert event.referrer == "/account/reset"
      assert event.referrer_medium == "none"
    end

    test "a garbage referrer is stored without its query and classified as none" do
      assert {:ok, event} = Collector.track(hit(%{referrer: "not a url?email=a@b.c"}))

      assert event.referrer == "not a url"
      assert event.referrer_medium == "none"
      assert event.referrer_source == nil
    end

    test "a referrer that is only a query string becomes nil" do
      assert {:ok, event} = Collector.track(hit(%{referrer: "?token=abc"}))
      assert event.referrer == nil

      assert {:ok, blank} = Collector.track(hit(%{referrer: "   "}))
      assert blank.referrer == nil
    end
  end

  describe "session stitching per site" do
    setup do
      enable_tracking()
      :ok
    end

    test "the same visitor on two sites gets two sessions" do
      assert {:ok, on_a} = Collector.track(hit(%{site: "a.example"}))
      assert {:ok, on_b} = Collector.track(hit(%{site: "b.example"}))

      assert on_a.visitor_id == on_b.visitor_id
      refute on_a.session_id == on_b.session_id

      # And going back to the first site rejoins its session.
      assert {:ok, back_on_a} = Collector.track(hit(%{site: "a.example", path: "/docs"}))
      assert back_on_a.session_id == on_a.session_id
    end

    test "site comparison is normalized (www. and case)" do
      assert {:ok, first} = Collector.track(hit(%{site: "MyApp.com"}))
      assert {:ok, second} = Collector.track(hit(%{site: "www.myapp.com"}))

      assert first.site == "myapp.com"
      assert first.session_id == second.session_id
    end

    test "hits with no site stitch only with other site-less hits" do
      assert {:ok, no_site} = Collector.track(hit(%{site: nil}))
      assert {:ok, with_site} = Collector.track(hit(%{site: "a.example"}))
      assert {:ok, no_site_again} = Collector.track(hit(%{site: nil, path: "/x"}))

      refute no_site.session_id == with_site.session_id
      assert no_site_again.session_id == no_site.session_id
    end

    test "resolve_session/4 filters by site, and the default :any ignores it" do
      assert {:ok, on_a} =
               Collector.track(
                 hit(%{
                   site: "a.example",
                   inserted_at: DateTime.add(DateTime.utc_now(), -60, :second)
                 })
               )

      assert {:ok, on_b} = Collector.track(hit(%{site: "b.example"}))

      now = DateTime.utc_now()

      assert Collector.resolve_session(on_a.visitor_id, 30, now, "a.example") == on_a.session_id
      assert Collector.resolve_session(on_a.visitor_id, 30, now, "b.example") == on_b.session_id
      # :any → the visitor's latest hit, whatever site it was on.
      assert Collector.resolve_session(on_a.visitor_id, 30, now) == on_b.session_id
      assert Collector.resolve_session(on_a.visitor_id, 30, now, :any) == on_b.session_id

      minted = Collector.resolve_session(on_a.visitor_id, 30, now, "c.example")
      refute minted in [on_a.session_id, on_b.session_id]
    end
  end

  describe "session_anchor" do
    setup do
      enable_tracking()
      :ok
    end

    # Found in review: the stitch looked back from the anchor but not only up
    # to it, so the leave of a page opened at t0 joined a newer session the
    # visitor had started since — the latest hit in the window won.
    test "a late leave joins its own page's session, not a newer one" do
      now = DateTime.utc_now()
      t0 = DateTime.add(now, -60 * 60, :second)

      assert {:ok, first} =
               Collector.track(hit(%{inserted_at: t0}))

      # 40 minutes later, past the 30-minute window: a new session.
      assert {:ok, second} =
               Collector.track(
                 hit(%{path: "/blog", inserted_at: DateTime.add(t0, 40 * 60, :second)})
               )

      refute second.session_id == first.session_id

      assert {:ok, leave} =
               Collector.track(
                 hit(%{
                   event_type: "leave",
                   engaged_ms: 3_600_000,
                   session_anchor: t0,
                   inserted_at: now
                 })
               )

      assert leave.session_id == first.session_id
    end
  end

  describe "session_anchor (continued)" do
    setup do
      enable_tracking()
      :ok
    end

    test "a late hit anchored at its page view joins that page view's session" do
      opened = hours_ago(2)
      assert {:ok, page} = Collector.track(hit(%{inserted_at: opened}))

      assert {:ok, leave} =
               Collector.track(
                 hit(%{
                   event_type: "leave",
                   engaged_ms: 2 * 60 * 60 * 1000,
                   session_anchor: DateTime.add(opened, 1, :second)
                 })
               )

      assert leave.session_id == page.session_id
      assert leave.visitor_id == page.visitor_id
      # Stored at its own time, not the anchor.
      assert DateTime.diff(leave.inserted_at, opened, :second) >= 7_100
    end

    test "without the anchor the same late hit starts a new session" do
      assert {:ok, page} = Collector.track(hit(%{inserted_at: hours_ago(2)}))
      assert {:ok, leave} = Collector.track(hit(%{event_type: "leave"}))

      refute leave.session_id == page.session_id
    end

    test "an anchor in the future is clamped to now" do
      assert {:ok, page} = Collector.track(hit())

      future = DateTime.add(DateTime.utc_now(), 2 * 3600, :second)

      assert {:ok, later} =
               Collector.track(hit(%{event_type: "leave", session_anchor: future}))

      # Unclamped, the lookup window would start 1.5h from now and miss the
      # page view entirely.
      assert later.session_id == page.session_id
      assert later.visitor_id == page.visitor_id
    end

    test "a non-DateTime anchor is ignored" do
      assert {:ok, page} = Collector.track(hit())
      assert {:ok, other} = Collector.track(hit(%{session_anchor: "yesterday"}))

      assert other.session_id == page.session_id
    end
  end

  describe "language" do
    setup do
      enable_tracking()
      :ok
    end

    test "stores the primary tag of an Accept-Language header" do
      assert {:ok, event} = Collector.track(hit(%{language: "et-EE,et;q=0.9,en;q=0.8"}))
      assert event.language == "et-EE"
    end

    test "a hit with no language inherits the session's previous hit's language" do
      assert {:ok, first} = Collector.track(hit(%{language: "de-DE,de;q=0.9"}))
      assert {:ok, live_nav} = Collector.track(hit(%{path: "/next"}))

      assert live_nav.session_id == first.session_id
      assert live_nav.language == "de-DE"
    end

    test "an explicit language is not overwritten by the session's" do
      assert {:ok, _first} = Collector.track(hit(%{language: "de-DE"}))
      assert {:ok, second} = Collector.track(hit(%{language: "fr-FR"}))

      assert second.language == "fr-FR"
    end

    test "a new session has nothing to inherit" do
      assert {:ok, event} = Collector.track(hit(%{language: nil}))
      assert event.language == nil

      assert {:ok, blank} = Collector.track(hit(%{language: "  ", ip: {198, 51, 100, 1}}))
      assert blank.language == nil
    end
  end

  describe "server-side hits without client identity" do
    setup do
      enable_tracking()
      :ok
    end

    test "each hit with neither ip nor user agent is its own visitor" do
      assert {:ok, one} =
               Collector.track(%{path: "/webhook", event_type: "event", event_name: "paid"})

      assert {:ok, two} =
               Collector.track(%{path: "/webhook", event_type: "event", event_name: "paid"})

      assert "anon:" <> rest = one.visitor_id
      assert byte_size(rest) == 32
      assert String.starts_with?(two.visitor_id, "anon:")
      refute one.visitor_id == two.visitor_id
      refute one.session_id == two.session_id
    end

    test "with a user_uuid the visitor is that user, and sessions stitch" do
      user_uuid = UUIDv7.generate()

      assert {:ok, one} =
               Collector.track(%{
                 path: "/x",
                 event_type: "event",
                 event_name: "a",
                 user_uuid: user_uuid
               })

      assert {:ok, two} =
               Collector.track(%{
                 path: "/x",
                 event_type: "event",
                 event_name: "b",
                 user_uuid: user_uuid
               })

      assert one.visitor_id == "user:" <> user_uuid
      assert one.user_uuid == user_uuid
      assert two.session_id == one.session_id
    end

    test "an ip or user agent alone still hashes to a daily visitor" do
      assert {:ok, ua_only} = Collector.track(%{path: "/", user_agent: @chrome})
      assert {:ok, ua_only_again} = Collector.track(%{path: "/", user_agent: @chrome})

      refute String.starts_with?(ua_only.visitor_id, "anon:")
      assert ua_only.visitor_id == ua_only_again.visitor_id
    end
  end

  describe "interaction and leave fields" do
    setup do
      enable_tracking()
      :ok
    end

    test "engaged_ms, scroll_depth and target are stored" do
      assert {:ok, leave} =
               Collector.track(hit(%{event_type: "leave", engaged_ms: 45_000, scroll_depth: 80}))

      stored = Repo.get!(Event, leave.uuid)
      assert stored.event_type == "leave"
      assert stored.engaged_ms == 45_000
      assert stored.scroll_depth == 80

      assert {:ok, click} =
               Collector.track(
                 hit(%{
                   event_type: "interaction",
                   event_name: "outbound",
                   target: "  example.org/x  "
                 })
               )

      assert Repo.get!(Event, click.uuid).target == "example.org/x"
    end

    test "an interaction requires an event name" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Collector.track(hit(%{event_type: "interaction"}))

      assert %{event_name: _} = errors_on(changeset)
      assert Repo.aggregate(Event, :count) == 0
    end

    test "a leave needs no event name" do
      assert {:ok, event} = Collector.track(hit(%{event_type: "leave"}))
      assert event.event_name == nil
    end

    test "an unknown event type is rejected" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Collector.track(hit(%{event_type: "purchase", event_name: "x"}))

      assert %{event_type: _} = errors_on(changeset)
      assert Repo.aggregate(Event, :count) == 0
    end

    test "scroll_depth is clamped to 0..100" do
      assert {:ok, high} = Collector.track(hit(%{event_type: "leave", scroll_depth: 150}))
      assert {:ok, low} = Collector.track(hit(%{event_type: "leave", scroll_depth: -20}))

      assert Repo.get!(Event, high.uuid).scroll_depth == 100
      assert Repo.get!(Event, low.uuid).scroll_depth == 0
    end

    test "engaged_ms is clamped to 0..24h" do
      day_ms = 24 * 60 * 60 * 1000

      assert {:ok, huge} =
               Collector.track(hit(%{event_type: "leave", engaged_ms: 10 * day_ms}))

      assert {:ok, negative} = Collector.track(hit(%{event_type: "leave", engaged_ms: -5}))

      assert Repo.get!(Event, huge.uuid).engaged_ms == day_ms
      assert Repo.get!(Event, negative.uuid).engaged_ms == 0
    end
  end

  describe "UTF-8 truncation" do
    setup do
      enable_tracking()
      :ok
    end

    # Two-byte chars at an even offset land exactly on 512 — fine either way.
    test "a 600-char two-byte title is truncated to valid UTF-8" do
      assert {:ok, event} = Collector.track(hit(%{page_title: String.duplicate("ä", 600)}))

      stored = Repo.get!(Event, event.uuid)
      assert byte_size(stored.page_title) <= 512
      assert String.valid?(stored.page_title)
      assert String.starts_with?(stored.page_title, "ää")
    end

    test "a 600-emoji title is truncated to valid UTF-8" do
      assert {:ok, event} = Collector.track(hit(%{page_title: String.duplicate("😀", 600)}))

      stored = Repo.get!(Event, event.uuid)
      assert byte_size(stored.page_title) <= 512
      assert String.valid?(stored.page_title)
    end

    # Regression: Event.changeset/2 used to truncate with binary_part/3, which
    # cut a multibyte character in half; Postgres rejected the invalid UTF-8
    # and the hit was lost.
    test "a title whose 512-byte boundary falls inside a character still inserts" do
      for title <- [
            String.duplicate("€", 600),
            "a" <> String.duplicate("ä", 600),
            "ab" <> String.duplicate("😀", 600)
          ] do
        assert {:ok, event} = Collector.track(hit(%{page_title: title}))

        stored = Repo.get!(Event, event.uuid)
        assert byte_size(stored.page_title) <= 512
        assert String.valid?(stored.page_title)
      end
    end
  end

  describe "track_async/1 and run_async/1 with async_tracking off" do
    setup do
      enable_tracking()
      :ok
    end

    test "track_async/1 writes inline before returning" do
      assert Application.get_env(:phoenix_kit_web_analytics, :async_tracking) == false

      assert :ok = Collector.track_async(hit(%{path: "/inline"}))

      assert [%Event{path: "/inline"}] = Repo.all(Event)
    end

    test "track_async/1 returns :ok and stores nothing for an invalid hit" do
      assert :ok = Collector.track_async(%{site: "myapp.com"})
      assert :ok = Collector.track_async(hit(%{event_type: "event"}))

      assert Repo.aggregate(Event, :count) == 0
    end

    test "run_async/1 runs the function inline in the caller" do
      parent = self()
      assert :ok = Collector.run_async(fn -> send(parent, {:ran_in, self()}) end)

      assert_received {:ran_in, ^parent}
    end

    test "run_async/1 swallows a raise and an exit" do
      assert :ok = Collector.run_async(fn -> raise "boom" end)
      assert :ok = Collector.run_async(fn -> exit(:bye) end)
    end
  end

  describe "the per-visitor gate" do
    setup do
      enable_tracking()

      unless Process.whereis(PhoenixKitWebAnalytics.Collector.Gate),
        do: start_supervised!(Collector.gate_spec())

      :ok
    end

    test "drops a hit while that visitor already has the maximum in flight" do
      assert {:ok, first} = Collector.track(hit())

      parent = self()

      holders =
        for _ <- 1..3 do
          spawn_link(fn ->
            Registry.register(PhoenixKitWebAnalytics.Collector.Gate, first.visitor_id, nil)
            send(parent, :holding)
            Process.sleep(:infinity)
          end)
        end

      for _ <- holders, do: assert_receive(:holding)

      assert {:error, :visitor_busy} = Collector.track(hit())

      # Another visitor is unaffected.
      assert {:ok, _} = Collector.track(hit(%{ip: {198, 51, 100, 7}}))

      Enum.each(holders, &Process.unlink/1)
      Enum.each(holders, &Process.exit(&1, :kill))
      Process.sleep(20)

      assert {:ok, _} = Collector.track(hit())
      assert Repo.aggregate(Event, :count) == 3
    end
  end

  describe "session_start" do
    setup do
      enable_tracking()
      :ok
    end

    # The visits list pages through these marks instead of grouping every
    # event in the period — so exactly the first hit of each visit has one.
    test "marks the first hit of a visit and no other" do
      assert {:ok, first} = Collector.track(hit())
      assert {:ok, second} = Collector.track(hit(%{path: "/blog"}))
      assert first.session_id == second.session_id
      assert first.session_start
      refute second.session_start

      later = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert {:ok, next_visit} = Collector.track(hit(%{inserted_at: later}))
      refute next_visit.session_id == first.session_id
      assert next_visit.session_start
    end
  end

  # Chrome sends `Sec-Purpose: prefetch;prerender` for its own prerenders
  # from the visitor's real IP and User-Agent — the human's own address.
  describe "a hit with a forced bot verdict (:bot)" do
    setup do
      enable_tracking()
      :ok
    end

    test "REGRESSION: is its own visitor, so the human's visit after it starts clean" do
      assert {:ok, prefetch} = Collector.track(hit(%{bot: "prefetch"}))
      assert {:ok, human} = Collector.track(hit())

      assert prefetch.is_bot and prefetch.metadata["bot"] == "prefetch"
      assert String.length(prefetch.visitor_id) == String.length(human.visitor_id)
      refute human.visitor_id == prefetch.visitor_id
      refute human.session_id == prefetch.session_id
      assert human.session_start
      refute human.is_bot
      refute Map.has_key?(human.metadata, "bot")

      # The visit is counted and listed, and not as a bot's.
      filter = Reports.filter(period: "7d")
      assert Reports.overview(filter).visitors == 1
      assert [%{session_id: session_id}] = Reports.sessions(filter)
      assert session_id == human.session_id
    end

    test "REGRESSION: a prefetch in the middle of a visit leaves the visit alone" do
      assert {:ok, first} = Collector.track(hit())
      assert {:ok, prefetch} = Collector.track(hit(%{path: "/next", bot: "prefetch"}))
      assert {:ok, next} = Collector.track(hit(%{path: "/blog"}))

      refute prefetch.session_id == first.session_id
      assert next.session_id == first.session_id
      refute next.session_start
      refute next.is_bot

      visit = Repo.all(from(e in Event, where: e.session_id == ^first.session_id))
      assert length(visit) == 2
      refute Enum.any?(visit, & &1.is_bot)
    end
  end
end
