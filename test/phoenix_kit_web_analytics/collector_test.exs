defmodule PhoenixKitWebAnalytics.CollectorTest do
  use PhoenixKitWebAnalytics.DataCase, async: false

  alias PhoenixKitWebAnalytics.Collector
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

      refute event.visitor_id =~ "203"
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
end
