defmodule PhoenixKitWebAnalytics.ProfilesTest do
  use PhoenixKitWebAnalytics.DataCase, async: false

  import Plug.Test, only: [conn: 2]

  doctest PhoenixKitWebAnalytics.Profiles

  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Plug, as: TrackingPlug
  alias PhoenixKitWebAnalytics.Profiles
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Schemas.VisitorProfile

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @curl "curl/8.4.0"

  defmodule NetworkResolver do
    @behaviour PhoenixKitWebAnalytics.Geo

    @impl true
    def resolve({43, _, _, _}),
      do: %{
        country_code: "SG",
        region: nil,
        city: "Singapore",
        asn: "AS132203",
        network: "Tencent",
        hosting: true
      }

    def resolve(_ip), do: %{country_code: "EE", region: nil, city: "Tallinn"}
  end

  defp hit(attrs \\ %{}) do
    Map.merge(
      %{path: "/pricing", site: "myapp.com", ip: {203, 0, 113, 5}, user_agent: @chrome},
      attrs
    )
  end

  defp with_resolver(context) do
    previous = Application.get_env(:phoenix_kit_web_analytics, :geo_resolver)
    Application.put_env(:phoenix_kit_web_analytics, :geo_resolver, NetworkResolver)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_web_analytics, :geo_resolver, previous),
        else: Application.delete_env(:phoenix_kit_web_analytics, :geo_resolver)
    end)

    context
  end

  describe "with every setting at its default" do
    setup do
      enable_tracking()
      :ok
    end

    test "nothing about the visitor is kept" do
      assert {:ok, _event} = Collector.track(hit(%{headers: %{"names" => [], "values" => %{}}}))

      assert Repo.aggregate(VisitorProfile, :count) == 0
      refute Profiles.wanted?(Config.collection_config())
    end

    test "the defaults are off, and a visitor ID lasts a day" do
      config = Config.collection_config()

      assert config.store_ip == :off
      refute config.store_user_agent?
      refute config.store_headers?
      refute config.store_network?
      assert config.visitor_rotation == :daily
    end

    test "a value the code doesn't know is the default" do
      enable_tracking(%{
        "web_analytics_store_ip" => "everything",
        "web_analytics_visitor_rotation" => "yearly"
      })

      config = Config.collection_config()
      assert config.store_ip == :off
      assert config.visitor_rotation == :daily
    end
  end

  describe "the address" do
    test "is kept whole when asked" do
      enable_tracking(%{"web_analytics_store_ip" => "full"})
      assert {:ok, event} = Collector.track(hit())

      assert %VisitorProfile{ip: "203.0.113.5", user_agent: nil, headers: nil} =
               Profiles.get(event.visitor_id)
    end

    test "is kept as its network when truncated" do
      enable_tracking(%{"web_analytics_store_ip" => "truncated"})
      assert {:ok, event} = Collector.track(hit())

      assert Profiles.get(event.visitor_id).ip == "203.0.113.0/24"
    end

    test "never reaches the event row" do
      enable_tracking(%{"web_analytics_store_ip" => "full"})
      assert {:ok, event} = Collector.track(hit())

      refute event |> Map.from_struct() |> inspect() =~ "203.0.113.5"
    end
  end

  describe "the User-Agent" do
    test "is kept raw when asked, and only then" do
      enable_tracking(%{"web_analytics_store_user_agent" => "true"})
      assert {:ok, event} = Collector.track(hit())

      assert %VisitorProfile{user_agent: @chrome, ip: nil} = Profiles.get(event.visitor_id)
    end

    test "names the bot a parsed row can't" do
      enable_tracking(%{
        "web_analytics_store_user_agent" => "true",
        "web_analytics_track_bots" => "true"
      })

      assert {:ok, event} = Collector.track(hit(%{user_agent: @curl}))

      assert event.is_bot
      assert Profiles.get(event.visitor_id).user_agent == @curl
    end

    test "an over-long or invalid one doesn't cost the event" do
      enable_tracking(%{"web_analytics_store_user_agent" => "true"})

      assert {:ok, long} = Collector.track(hit(%{user_agent: String.duplicate("é", 3_000)}))
      assert byte_size(Profiles.get(long.visitor_id).user_agent) <= 1_000
      assert String.valid?(Profiles.get(long.visitor_id).user_agent)

      assert {:ok, bad} = Collector.track(hit(%{ip: {203, 0, 113, 6}, user_agent: <<255, 254>>}))
      assert Profiles.get(bad.visitor_id) == nil
    end
  end

  describe "one row per visitor" do
    setup do
      enable_tracking(%{
        "web_analytics_store_ip" => "full",
        "web_analytics_store_user_agent" => "true"
      })

      :ok
    end

    test "a second hit of the visit writes nothing new" do
      assert {:ok, first} = Collector.track(hit())
      assert {:ok, second} = Collector.track(hit(%{path: "/about"}))

      assert first.visitor_id == second.visitor_id
      assert Repo.aggregate(VisitorProfile, :count) == 1
    end

    test "a later visit refreshes last_seen_at and never blanks what is stored" do
      start = DateTime.add(DateTime.utc_now(), -3, :hour)
      assert {:ok, event} = Collector.track(hit(%{inserted_at: start}))
      before = Profiles.get(event.visitor_id)

      # The same visitor, with the User-Agent no longer kept.
      enable_tracking(%{
        "web_analytics_store_ip" => "full",
        "web_analytics_store_user_agent" => "false"
      })

      assert {:ok, later} = Collector.track(hit())
      profile = Profiles.get(event.visitor_id)

      assert later.visitor_id == event.visitor_id
      assert later.session_id != event.session_id
      assert profile.user_agent == @chrome
      assert DateTime.compare(profile.last_seen_at, before.last_seen_at) == :gt
      assert profile.inserted_at == before.inserted_at
    end

    test "a server-side event that names no client has no profile" do
      assert {:ok, event} = Collector.track(%{path: "/", event_type: "event", event_name: "paid"})

      assert Profiles.get(event.visitor_id) == nil
    end
  end

  describe "the network" do
    setup :with_resolver

    test "is kept when asked and the resolver knows it" do
      enable_tracking(%{"web_analytics_store_network" => "true"})
      assert {:ok, event} = Collector.track(hit(%{ip: {43, 156, 37, 91}}))

      assert %VisitorProfile{asn: 132_203, network: "Tencent", hosting: true, ip: nil} =
               Profiles.get(event.visitor_id)

      # The location still lands on the event, as before.
      assert event.country_code == "SG"
    end

    test "leaves no row when the resolver doesn't know it" do
      enable_tracking(%{"web_analytics_store_network" => "true"})
      assert {:ok, event} = Collector.track(hit())

      assert event.country_code == "EE"
      assert Profiles.get(event.visitor_id) == nil
    end

    test "is not kept when not asked" do
      enable_tracking()
      assert {:ok, _event} = Collector.track(hit(%{ip: {43, 156, 37, 91}}))

      assert Repo.aggregate(VisitorProfile, :count) == 0
    end
  end

  describe "request headers" do
    defp request do
      conn(:get, "/pricing?utm_source=hn")
      |> Map.put(:remote_ip, {203, 0, 113, 5})
      |> Map.put(:req_headers, [
        {"host", "myapp.com"},
        {"user-agent", @chrome},
        {"accept", "text/html"},
        {"accept-language", "en-US,en;q=0.9"},
        {"cookie", "_session=SECRETCOOKIE"},
        {"authorization", "Bearer SECRETBEARER"},
        {"x-api-key", "SECRETKEY"},
        {"x-forwarded-for", "198.51.100.9"},
        {"referer", "https://example.com/reset?token=SECRETQUERY"},
        {"sec-fetch-mode", "navigate"}
      ])
    end

    defp respond(conn) do
      conn
      |> TrackingPlug.call(TrackingPlug.init([]))
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, "<html></html>")
    end

    defp stored_headers do
      [%Event{visitor_id: visitor_id}] = Repo.all(Event)
      profile = Profiles.get(visitor_id)
      profile && profile.headers
    end

    test "are not copied out of the request unless asked" do
      enable_tracking(%{"web_analytics_store_ip" => "full"})
      respond(request())

      assert stored_headers() == nil
    end

    test "keep their order and values, and never a credential" do
      enable_tracking(%{"web_analytics_store_headers" => "true"})
      respond(request())

      headers = stored_headers()

      assert headers["names"] == ~w(host user-agent accept accept-language cookie authorization
               x-api-key x-forwarded-for referer sec-fetch-mode)

      assert headers["values"]["accept-language"] == "en-US,en;q=0.9"
      assert headers["values"]["sec-fetch-mode"] == "navigate"
      assert headers["values"]["referer"] == "https://example.com/reset"
      assert is_binary(headers["http"])

      for name <- ~w(cookie authorization x-api-key x-forwarded-for),
          do: refute(Map.has_key?(headers["values"], name))

      stored = inspect(headers)

      for secret <- ~w(SECRETCOOKIE SECRETBEARER SECRETKEY SECRETQUERY 198.51.100.9),
          do: refute(stored =~ secret)
    end

    test "keep the address headers only with the whole address" do
      enable_tracking(%{
        "web_analytics_store_headers" => "true",
        "web_analytics_store_ip" => "full"
      })

      respond(request())

      assert stored_headers()["values"]["x-forwarded-for"] == "198.51.100.9"
    end
  end

  describe "how long a visitor ID lasts" do
    test "a day by default: tomorrow is another visitor" do
      enable_tracking()
      now = DateTime.utc_now()

      assert {:ok, today} = Collector.track(hit(%{inserted_at: DateTime.add(now, -1, :day)}))
      assert {:ok, tomorrow} = Collector.track(hit(%{inserted_at: now}))

      refute today.visitor_id == tomorrow.visitor_id
    end

    test "never: the same visitor on any day" do
      enable_tracking(%{"web_analytics_visitor_rotation" => "never"})
      now = DateTime.utc_now()

      assert {:ok, earlier} = Collector.track(hit(%{inserted_at: DateTime.add(now, -40, :day)}))
      assert {:ok, later} = Collector.track(hit(%{inserted_at: now}))

      assert earlier.visitor_id == later.visitor_id
      refute earlier.session_id == later.session_id
    end
  end

  describe "forget/1 and prune/0" do
    setup do
      enable_tracking(%{
        "web_analytics_store_ip" => "full",
        "web_analytics_store_user_agent" => "true"
      })

      {:ok, event} = Collector.track(hit())
      {:ok, visitor_id: event.visitor_id}
    end

    test "forget blanks one kind and keeps the rest", %{visitor_id: visitor_id} do
      assert Profiles.forget(:ip) == 1

      assert %VisitorProfile{ip: nil, user_agent: @chrome} = Profiles.get(visitor_id)
    end

    test "forget drops a row left with nothing", %{visitor_id: visitor_id} do
      Profiles.forget(:ip)
      Profiles.forget(:user_agent)

      assert Profiles.get(visitor_id) == nil
    end

    test "forget(:all) deletes every profile" do
      assert Profiles.forget(:all) == 1
      assert Profiles.count() == 0
    end

    test "prune removes visitors unseen for the retention period", %{visitor_id: visitor_id} do
      assert Profiles.prune() == 0

      Repo.update_all(VisitorProfile,
        set: [last_seen_at: DateTime.add(DateTime.utc_now(), -400, :day)]
      )

      assert Profiles.prune() == 1
      assert Profiles.get(visitor_id) == nil
    end
  end
end
