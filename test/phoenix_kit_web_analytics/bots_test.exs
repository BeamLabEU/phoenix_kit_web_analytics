defmodule PhoenixKitWebAnalytics.BotsTest do
  @moduledoc """
  A profile's bot score from the write path — the request, the device's
  measurements, BotSignals' verdicts — and the Bots page's queries over it.
  """

  use PhoenixKitWebAnalytics.DataCase, async: false

  alias PhoenixKitWebAnalytics.Bots
  alias PhoenixKitWebAnalytics.BotSignals
  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Profiles
  alias PhoenixKitWebAnalytics.Schemas.VisitorProfile

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

  @everything %{
    "web_analytics_store_ip" => "full",
    "web_analytics_store_user_agent" => "true",
    "web_analytics_store_headers" => "true",
    "web_analytics_store_network" => "true",
    "web_analytics_store_signals" => "true",
    "web_analytics_client_script" => "true",
    "web_analytics_track_bots" => "true"
  }

  @browser_headers %{
    "http" => "HTTP/2",
    "scheme" => "https",
    "names" => ~w(host accept accept-language sec-ch-ua sec-fetch-site user-agent),
    "values" => %{}
  }

  defp hit(attrs) do
    Map.merge(
      %{
        path: "/pricing",
        site: "myapp.com",
        ip: {203, 0, 113, 5},
        user_agent: @chrome,
        headers: @browser_headers
      },
      attrs
    )
  end

  defp profile(event), do: Repo.get_by!(VisitorProfile, visitor_id: event.visitor_id)

  defp profile!(attrs) do
    now = DateTime.utc_now()

    Repo.insert!(
      struct!(
        VisitorProfile,
        Map.merge(
          %{
            visitor_id: "visitor-#{System.unique_integer([:positive])}",
            last_seen_at: now,
            inserted_at: now
          },
          attrs
        )
      )
    )
  end

  describe "the request's reasons, when a visit starts" do
    setup do
      enable_tracking(@everything)
      :ok
    end

    test "an ordinary browser scores nothing" do
      {:ok, event} = Collector.track(hit(%{}))

      assert %{bot_score: 0, bot_reasons: []} = profile(event)
    end

    test "a phone's User-Agent from a hosting provider, sending a script's headers" do
      {:ok, event} =
        Collector.track(
          hit(%{
            user_agent: @iphone,
            network: %{asn: 132_203, network: "Tencent", hosting: true},
            headers: %{@browser_headers | "names" => ["host", "user-agent"]}
          })
        )

      assert %{bot_score: 135, bot_reasons: reasons} = profile(event)

      assert reasons ==
               ~w(hosting_network mobile_from_hosting no_accept_language no_fetch_metadata no_accept)
    end

    test "a declared bot" do
      {:ok, event} = Collector.track(hit(%{user_agent: "python-requests/2.31", headers: nil}))

      assert %{bot_score: 100, bot_reasons: ["declared_bot"]} = profile(event)
    end

    test "a later visit rescoring the request keeps what behaviour found" do
      {:ok, event} = Collector.track(hit(%{}))
      assert Profiles.add_reason([event.visitor_id], "rate") == 1

      Profiles.record(event.visitor_id, hit(%{}), Config.collection_config())

      assert %{bot_score: 70, bot_reasons: ["rate"]} = profile(event)
    end

    @script_headers %{@browser_headers | "names" => ["host", "user-agent"]}

    # A live navigation or a beacon hit starts a visit with no headers; the
    # ones the first visit sent are still on the profile.
    test "a later visit that carries no headers keeps what the stored ones showed" do
      {:ok, event} = Collector.track(hit(%{headers: @script_headers}))
      scored = profile(event)

      assert scored.bot_reasons ==
               ~w(no_accept_language no_fetch_metadata no_client_hints no_accept)

      Profiles.record(
        event.visitor_id,
        hit(%{headers: nil, metadata: %{"source" => "live_navigation"}}),
        Config.collection_config()
      )

      assert %{bot_reasons: reasons, bot_score: score, headers: headers} = profile(event)
      assert reasons == scored.bot_reasons
      assert score == scored.bot_score
      assert headers == @script_headers
    end

    test "a later visit with other headers is scored on those" do
      {:ok, event} = Collector.track(hit(%{headers: @script_headers}))

      Profiles.record(event.visitor_id, hit(%{}), Config.collection_config())

      assert %{bot_reasons: [], bot_score: 0} = profile(event)
    end

    test "the stored network counts for a later visit that resolves none" do
      {:ok, event} =
        Collector.track(hit(%{network: %{asn: 132_203, network: "Tencent", hosting: true}}))

      assert profile(event).bot_reasons == ["hosting_network"]

      Profiles.record(event.visitor_id, hit(%{network: %{}}), Config.collection_config())

      assert profile(event).bot_reasons == ["hosting_network"]
    end
  end

  describe "the request's and the device's reasons, arriving together" do
    setup do
      enable_tracking(@everything)
      :ok
    end

    @headless %{"cv" => "a1b2c3d4", "gr" => "Google SwiftShader", "plat" => "Win32", "sw" => 1920}
    @old_http %{@browser_headers | "http" => "HTTP/1.0"}
    @query_event [:phoenix_kit_web_analytics, :test, :repo, :query]

    test "each source's reasons survive the other's rescore, in both orders" do
      config = Config.collection_config()

      {:ok, first} = Collector.track(hit(%{}))
      Profiles.record_signals(first.visitor_id, @headless, @chrome, config)
      Profiles.record(first.visitor_id, hit(%{headers: @old_http}), config)
      assert profile(first).bot_reasons == ~w(software_renderer old_http)

      {:ok, second} = Collector.track(hit(%{ip: {203, 0, 113, 6}}))
      Profiles.record(second.visitor_id, hit(%{headers: @old_http}), config)
      Profiles.record_signals(second.visitor_id, @headless, @chrome, config)
      assert profile(second).bot_reasons == ~w(software_renderer old_http)
    end

    # The signals rescore is held right after it reads the profile's
    # reasons (Ecto runs query telemetry in the caller), and the request
    # rescore is started in that gap. Unlocked, the request's reasons land
    # in the gap and the held write then puts back the list it read before
    # them. Locked, the request waits for the held one to finish.
    test "REGRESSION: one rescore cannot overwrite another that ran between its read and its write" do
      config = Config.collection_config()
      {:ok, event} = Collector.track(hit(%{}))
      test = self()
      handler = "hold-rescore-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        @query_event,
        fn _event, _measurements, %{query: query}, _config ->
          if Process.get(:hold_after_read) && query =~ ~r/\ASELECT.*"bot_reasons"/s do
            Process.delete(:hold_after_read)
            send(test, {:read, self()})

            receive do
              :continue -> :ok
            after
              500 -> :ok
            end
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      signals =
        Task.async(fn ->
          Process.put(:hold_after_read, true)
          Profiles.record_signals(event.visitor_id, @headless, @chrome, config)
        end)

      assert_receive {:read, held}, 1_000

      request =
        Task.async(fn ->
          Profiles.record(event.visitor_id, hit(%{headers: @old_http}), config)
        end)

      # Unlocked, this returns at once; locked, when the hold runs out.
      early = Task.yield(request, 300)
      send(held, :continue)
      early || Task.await(request)
      Task.await(signals)

      assert %{bot_reasons: ~w(software_renderer old_http), bot_score: 70} = profile(event)
    end
  end

  describe "record_signals/5" do
    setup do
      enable_tracking(@everything)
      :ok
    end

    @device %{
      "cv" => "a1b2c3d4",
      "gr" => "ANGLE (Apple, M2)",
      "plat" => "Win32",
      "sw" => 1920,
      "langs" => ["en"],
      "wd" => false,
      "made-up" => "dropped"
    }

    test "stores the cleaned measurements and a device hash on the visitor's profile" do
      {:ok, event} = Collector.track(hit(%{}))

      assert :ok =
               Profiles.record_signals(
                 event.visitor_id,
                 @device,
                 @chrome,
                 Config.collection_config()
               )

      profile = profile(event)
      assert profile.signals == Map.delete(@device, "made-up")
      assert profile.device_hash =~ ~r/\A[0-9a-f]{32}\z/
      assert profile.bot_reasons == []
      # What the visit's start kept is still there.
      assert profile.ip == "203.0.113.5"
    end

    test "the same device from another address has the same hash" do
      config = Config.collection_config()
      Profiles.record_signals("visitor-a", @device, @chrome, config)
      Profiles.record_signals("visitor-b", @device, @chrome, config)
      Profiles.record_signals("visitor-c", %{@device | "cv" => "00000000"}, @chrome, config)

      assert [a, b, c] =
               VisitorProfile |> order_by(:visitor_id) |> Repo.all() |> Enum.map(& &1.device_hash)

      assert a == b
      refute a == c
    end

    test "an incomplete report retains measurements, hash material and their reasons" do
      config = Config.collection_config()
      first = Map.merge(@device, %{"gr" => "SwiftShader", "wd" => true})
      Profiles.record_signals("visitor-a", first, @chrome, config)
      before = Profiles.get("visitor-a")

      Profiles.record_signals("visitor-a", %{"iw" => 800, "wd" => false}, @chrome, config)
      after_report = Profiles.get("visitor-a")

      assert after_report.device_hash == before.device_hash
      assert after_report.signals == Map.merge(before.signals, %{"iw" => 800, "wd" => false})
      assert Enum.sort(after_report.bot_reasons) == ~w(software_renderer webdriver)

      # Explicit replacements still take back the device's reason.
      Profiles.record_signals("visitor-a", %{"gr" => "Apple M2"}, @chrome, config)
      assert Profiles.get("visitor-a").bot_reasons == ["webdriver"]
      refute Profiles.get("visitor-a").device_hash == before.device_hash
    end

    test "forgetting the only measurements keeps unrelated behaviour evidence" do
      enable_tracking(%{"web_analytics_store_signals" => "true"})

      Profiles.record_signals(
        "visitor-a",
        %{"gr" => "SwiftShader", "wd" => true},
        @chrome,
        Config.collection_config()
      )

      assert Profiles.forget(:signals) == 1

      assert %{signals: nil, device_hash: nil, bot_reasons: ["webdriver"], bot_score: 90} =
               Profiles.get("visitor-a")
    end

    test "scores what the device says, and replaces it when it reports again" do
      config = Config.collection_config()

      headless =
        Map.merge(@device, %{"plat" => "Linux x86_64", "gr" => "SwiftShader", "wd" => true})

      Profiles.record_signals("visitor-a", headless, @chrome, config)

      assert %{bot_reasons: reasons, bot_score: 180} =
               Repo.get_by!(VisitorProfile, visitor_id: "visitor-a")

      assert Enum.sort(reasons) == ~w(platform_mismatch software_renderer webdriver)

      Profiles.record_signals("visitor-a", @device, @chrome, config)

      # The device's own reasons are gone; the automation verdict stays.
      assert %{bot_reasons: ["webdriver"], bot_score: 90} =
               Repo.get_by!(VisitorProfile, visitor_id: "visitor-a")
    end

    test "with nothing else kept, the User-Agent's own reason is added" do
      enable_tracking(%{"web_analytics_store_signals" => "true"})

      Profiles.record_signals("visitor-a", @device, "curl/8.4.0", Config.collection_config())

      assert %{bot_reasons: ["declared_bot"], ip: nil, user_agent: nil} =
               Repo.get_by!(VisitorProfile, visitor_id: "visitor-a")
    end

    test "stores nothing while the setting is off, or from a payload with nothing usable" do
      Profiles.record_signals(
        "visitor-a",
        %{"nonsense" => 1},
        @chrome,
        Config.collection_config()
      )

      enable_tracking(%{"web_analytics_store_signals" => "false"})
      Profiles.record_signals("visitor-b", @device, @chrome, Config.collection_config())

      assert Repo.aggregate(VisitorProfile, :count) == 0
    end

    # Today such a profile would age off the Bots page and be pruned as if
    # the visitor had gone, while its device keeps reporting.
    test "a device reporting in is the visitor being seen" do
      config = Config.collection_config()
      long_ago = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
      now = DateTime.utc_now()

      Profiles.record_signals("visitor-a", @device, @chrome, config, now: long_ago)
      assert [_none] = Bots.visitors(%{days: 30})
      assert Bots.visitors(%{days: 7}) == []

      Profiles.record_signals("visitor-a", @device, @chrome, config, now: now)

      assert %{last_seen_at: seen, inserted_at: inserted} =
               Repo.get_by!(VisitorProfile, visitor_id: "visitor-a")

      assert DateTime.diff(now, seen, :second) == 0
      assert DateTime.diff(inserted, long_ago, :second) == 0
      assert [%{visitor_id: "visitor-a"}] = Bots.visitors(%{days: 7})

      # A report that arrives late never moves the time back.
      Profiles.record_signals("visitor-a", @device, @chrome, config, now: long_ago)
      assert Repo.get_by!(VisitorProfile, visitor_id: "visitor-a").last_seen_at == seen
    end

    test "forget(:signals) takes back the reasons the measurements gave" do
      {:ok, event} = Collector.track(hit(%{headers: %{@browser_headers | "http" => "HTTP/1.0"}}))
      config = Config.collection_config()

      headless =
        Map.merge(@device, %{"plat" => "Linux x86_64", "gr" => "SwiftShader", "wd" => true})

      Profiles.record_signals(event.visitor_id, headless, @chrome, config)

      assert Enum.sort(profile(event).bot_reasons) ==
               ~w(old_http platform_mismatch software_renderer webdriver)

      Profiles.forget(:signals)

      # The request's reason and the automation verdict are not the
      # measurements'.
      assert %{bot_reasons: ~w(old_http webdriver), bot_score: 120, signals: nil} =
               profile(event)
    end

    test "forget(:headers) and forget(:network) take back only their own reasons" do
      {:ok, event} =
        Collector.track(
          hit(%{
            network: %{asn: 132_203, network: "Tencent", hosting: true},
            headers: %{@browser_headers | "http" => "HTTP/1.0"}
          })
        )

      Profiles.add_reason([event.visitor_id], "rate")
      assert Enum.sort(profile(event).bot_reasons) == ~w(hosting_network old_http rate)

      Profiles.forget(:headers)
      assert %{bot_reasons: ~w(hosting_network rate), bot_score: 110} = profile(event)

      Profiles.forget(:network)
      assert %{bot_reasons: ["rate"], bot_score: 70} = profile(event)

      # The address and the User-Agent gave no reason of their own.
      Profiles.forget(:user_agent)
      assert %{bot_reasons: ["rate"], bot_score: 70} = profile(event)
    end

    test "forget(:signals) blanks them and drops rows left with nothing" do
      {:ok, event} = Collector.track(hit(%{}))
      config = Config.collection_config()
      Profiles.record_signals(event.visitor_id, @device, @chrome, config)
      Profiles.record_signals("only-signals", @device, @chrome, config)

      assert Profiles.forget(:signals) == 2

      assert [%{signals: nil, device_hash: nil, ip: "203.0.113.5"}] = Repo.all(VisitorProfile)
    end
  end

  describe "BotSignals' verdicts" do
    setup do
      start_supervised!(BotSignals)
      enable_tracking(@everything)
      :ok
    end

    test "going over the speed limit is added to the profile" do
      Application.put_env(:phoenix_kit_web_analytics, :bot_pageviews_per_minute, 3)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_web_analytics, :bot_pageviews_per_minute)
      end)

      await_fresh_minute()

      events = for n <- 1..5, do: Collector.track(hit(%{path: "/page-#{n}"}))
      {:ok, first} = hd(events)

      assert %{bot_reasons: ["rate"], bot_score: 70} = profile(first)
    end

    test "an automation report is added to the profile" do
      {:ok, event} = Collector.track(hit(%{}))

      BotSignals.flag_client(%{ip: {203, 0, 113, 5}, user_agent: @chrome}, "webdriver")

      assert %{bot_reasons: ["webdriver"]} = profile(event)
    end

    test "add_reason/2 and remove_reason/2 are idempotent and touch only kept profiles" do
      {:ok, event} = Collector.track(hit(%{}))
      ids = [event.visitor_id, "no-such-visitor"]

      assert Profiles.add_reason(ids, "no_js") == 1
      assert Profiles.add_reason(ids, "no_js") == 0
      assert %{bot_reasons: ["no_js"], bot_score: 50} = profile(event)

      assert Profiles.remove_reason(ids, "no_js") == 1
      assert Profiles.remove_reason(ids, "no_js") == 0
      assert %{bot_reasons: [], bot_score: 0} = profile(event)
    end
  end

  describe "the Bots page's queries" do
    setup do
      old = DateTime.add(DateTime.utc_now(), -20 * 86_400, :second)

      scraper = fn n ->
        profile!(%{
          ip: "43.156.37.#{n}",
          user_agent: @iphone,
          asn: 132_203,
          network: "Tencent",
          hosting: true,
          device_hash: String.duplicate("a", 32),
          bot_score: 70,
          bot_reasons: ~w(hosting_network mobile_from_hosting)
        })
      end

      %{
        scrapers: [scraper.(91), scraper.(92)],
        odd:
          profile!(%{
            ip: "198.51.100.7",
            user_agent: @chrome,
            bot_score: 40,
            bot_reasons: ["no_screen"]
          }),
        person:
          profile!(%{
            ip: "2001:db8:abcd:1::5",
            user_agent: @chrome,
            device_hash: String.duplicate("b", 32)
          }),
        old:
          profile!(%{
            ip: "192.0.2.1",
            bot_score: 100,
            bot_reasons: ["declared_bot"],
            last_seen_at: old
          })
      }
    end

    test "visitors/2 ranks the likeliest first, within the period and above the floor", ctx do
      filter = Bots.default_filter()

      assert [70, 70, 40, 0] = filter |> Bots.visitors() |> Enum.map(& &1.bot_score)
      assert [70, 70] = %{filter | level: :likely} |> Bots.visitors() |> Enum.map(& &1.bot_score)
      assert [_, _, _] = Bots.visitors(%{filter | level: :suspicious})

      assert hd(Bots.visitors(%{filter | days: 0})).uuid == ctx.old.uuid
      assert [_] = Bots.visitors(filter, limit: 1)
    end

    test "visitors/2 narrows to a network, a subnet, an address, a device, a User-Agent", ctx do
      filter = Bots.default_filter()
      scrapers = ctx.scrapers |> Enum.map(& &1.uuid) |> Enum.sort()
      uuids = fn filter -> filter |> Bots.visitors() |> Enum.map(& &1.uuid) |> Enum.sort() end

      assert uuids.(%{filter | asn: 132_203}) == scrapers
      assert uuids.(%{filter | subnet: "43.156.37.0/24"}) == scrapers
      assert uuids.(%{filter | subnet: "2001:db8:abcd::/48"}) == [ctx.person.uuid]
      assert uuids.(%{filter | ip: "198.51.100.7"}) == [ctx.odd.uuid]
      assert uuids.(%{filter | device: String.duplicate("a", 32)}) == scrapers
      assert uuids.(%{filter | agent: Bots.agent_key(@iphone)}) == scrapers
    end

    test "groups/3 counts what visitors share" do
      filter = Bots.default_filter()

      assert [%{key: "132203", label: "Tencent", visitors: 2, likely: 2, top_score: 70}] =
               Bots.groups(:network, filter)

      assert [
               %{key: "43.156.37.0/24", visitors: 2, likely: 2},
               %{key: "198.51.100.0/24", visitors: 1, likely: 0},
               %{key: "2001:db8:abcd::/48", visitors: 1, likely: 0}
             ] = Bots.groups(:subnet, filter)

      assert [_, _, _, _] = Bots.groups(:ip, filter)

      assert [%{visitors: 2, likely: 2}, %{visitors: 1, likely: 0}] = Bots.groups(:device, filter)

      iphone = Bots.agent_key(@iphone)

      assert [%{key: ^iphone, label: @iphone, visitors: 2}, %{label: @chrome, visitors: 2}] =
               Bots.groups(:agent, filter)

      assert [%{key: "43.156.37.0/24"}] = Bots.groups(:subnet, %{filter | level: :likely})
    end

    test "summary/1 counts the period whatever the floor" do
      assert %{visitors: 4, likely: 2, suspicious: 1, devices: 2} =
               Bots.summary(%{Bots.default_filter() | level: :likely})

      assert %{visitors: 5, likely: 3} = Bots.summary(%{Bots.default_filter() | days: 0})
    end

    # `%{filter | level: :all}` raised for a filter without the key, and
    # the rescue turned that into four zeros.
    test "summary/1 counts for a filter that names no floor" do
      assert %{visitors: 4, likely: 2, suspicious: 1, devices: 2} = Bots.summary(%{days: 7})
    end

    test "latest_sessions/1 finds each visitor's newest visit" do
      older = insert_event(%{visitor_id: "v1", inserted_at: hours_ago(5)})
      newer = insert_event(%{visitor_id: "v1", inserted_at: hours_ago(1)})
      other = insert_event(%{visitor_id: "v2"})

      assert Bots.latest_sessions(["v1", "v2", "gone"]) == %{
               "v1" => newer.session_id,
               "v2" => other.session_id
             }

      refute older.session_id == newer.session_id
      assert Bots.latest_sessions([]) == %{}
    end
  end
end
