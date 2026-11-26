defmodule PhoenixKitWebAnalytics.BotTrafficTest do
  @moduledoc """
  Bot traffic that can be looked at: a declared bot's short name on its rows,
  the daily rollup of bot traffic per rule and name (so it outlives the raw
  events), and the "judged automated" numbers the Overview, Bots and
  Technology pages show.
  """

  use PhoenixKitWebAnalytics.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Retention
  alias PhoenixKitWebAnalytics.Schemas.DailyBot
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Test.Repo

  @base "/admin/web-analytics"
  @googlebot "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
  @gptbot "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)"
  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  defp hit(attrs) do
    Map.merge(
      %{path: "/pricing", site: "example.com", ip: {203, 0, 113, 5}, user_agent: @chrome},
      attrs
    )
  end

  defp day_at(days_back, time \\ ~T[10:00:00]),
    do: DateTime.new!(Date.add(Date.utc_today(), -days_back), time, "Etc/UTC")

  defp bot_event(attrs) do
    insert_event(Map.merge(%{is_bot: true, browser: "Bot", device_type: "bot"}, attrs))
  end

  describe "the collector names a declared bot" do
    test "keeps the short name in metadata, never the header" do
      enable_tracking(%{"web_analytics_track_bots" => "true"})

      assert {:ok, event} = Collector.track(hit(%{user_agent: @googlebot}))
      assert event.is_bot
      assert event.metadata["bot_name"] == "Googlebot"
      refute inspect(event.metadata) =~ "google.com"
    end

    test "a browser's hit carries no name, even one a custom event's props claim" do
      enable_tracking()

      assert {:ok, event} =
               Collector.track(
                 hit(%{
                   event_type: "event",
                   event_name: "signup",
                   metadata: %{"bot_name" => "Fake"}
                 })
               )

      refute event.is_bot
      refute Map.has_key?(event.metadata, "bot_name")
    end

    test "a declared bot's props can't choose the rule its row is counted under" do
      enable_tracking(%{"web_analytics_track_bots" => "true"})

      assert {:ok, event} =
               Collector.track(
                 hit(%{
                   user_agent: @googlebot,
                   event_type: "event",
                   event_name: "x",
                   metadata: %{"bot" => "no_js", "bot_name" => "Fake", "plan" => "pro"}
                 })
               )

      assert event.metadata == %{"bot_name" => "Googlebot", "plan" => "pro"}

      automated = Reports.automated(Reports.filter(period: "today"))
      assert Enum.map(automated.rules, & &1.reason) == ["user_agent"]
      assert Enum.map(automated.bots, & &1.bot_name) == ["Googlebot"]
    end
  end

  describe "the daily rollup keeps bots" do
    test "one row per day, site, rule and bot name" do
      date = Date.add(Date.utc_today(), -2)
      at = day_at(2)
      session = UUIDv7.generate()

      bot_event(%{
        visitor_id: "g",
        session_id: session,
        metadata: %{"bot_name" => "Googlebot"},
        inserted_at: at
      })

      bot_event(%{
        visitor_id: "g",
        session_id: session,
        path: "/b",
        metadata: %{"bot_name" => "Googlebot"},
        inserted_at: DateTime.add(at, 60, :second)
      })

      insert_event(%{is_bot: true, metadata: %{"bot" => "no_js"}, inserted_at: at})
      insert_event(%{inserted_at: at})
      # Own traffic and API requests stay out, as in every rollup.
      bot_event(%{traffic_flags: 1, metadata: %{"bot_name" => "curl"}, inserted_at: at})
      bot_event(%{event_type: "api", metadata: %{"bot_name" => "curl"}, inserted_at: at})

      assert :ok = Retention.rollup_day(date)

      rows =
        from(b in DailyBot, order_by: [b.reason, b.bot_name])
        |> Repo.all()
        |> Enum.map(&Map.take(&1, [:date, :site, :reason, :bot_name, :hits, :pageviews, :visits]))

      assert rows == [
               %{
                 date: date,
                 site: "example.com",
                 reason: "no_js",
                 bot_name: "",
                 hits: 1,
                 pageviews: 1,
                 visits: 1
               },
               %{
                 date: date,
                 site: "example.com",
                 reason: "user_agent",
                 bot_name: "Googlebot",
                 hits: 2,
                 pageviews: 2,
                 visits: 1
               }
             ]

      # Re-rolling replaces the day whole.
      assert :ok = Retention.rollup_day(date)
      assert Repo.aggregate(DailyBot, :count) == 2
    end

    test "bot history survives the raw events, and adds up with the raw remainder" do
      enable_tracking(%{"web_analytics_track_bots" => "true"})
      old = day_at(5)

      bot_event(%{metadata: %{"bot_name" => "GPTBot"}, inserted_at: old})

      bot_event(%{
        metadata: %{"bot_name" => "GPTBot"},
        inserted_at: DateTime.add(old, 1, :second)
      })

      insert_event(%{is_bot: true, metadata: %{"bot" => "rate"}, inserted_at: old})

      Retention.rollup_pending_days()
      assert Repo.aggregate(DailyBot, :count) == 2
      # The raw rows of the rolled-up day go, as retention would prune them.
      Repo.delete_all(from(e in Event, where: e.inserted_at < ^day_at(4, ~T[00:00:00])))

      # Today is read raw.
      bot_event(%{metadata: %{"bot_name" => "GPTBot"}, inserted_at: DateTime.utc_now()})

      result = Reports.automated(Reports.filter(period: "30d"))

      assert result.visits == 4
      assert [%{bot_name: "GPTBot", visits: 3, pageviews: 3}] = result.bots

      assert Enum.map(result.rules, &{&1.reason, &1.visits}) == [
               {"user_agent", 3},
               {"rate", 1}
             ]

      assert result.track_bots?
    end

    test "an hourly period reads raw, and the Bots switch doesn't change the answer" do
      bot_event(%{metadata: %{"bot_name" => "AhrefsBot"}, inserted_at: DateTime.utc_now()})

      for bots <- [false, true] do
        result = Reports.automated(Reports.filter(period: "today", bots: bots))
        assert [%{bot_name: "AhrefsBot", visits: 1}] = result.bots
      end
    end
  end

  describe "the pages" do
    setup do
      enable_tracking()
      :ok
    end

    test "Overview says how many visits were judged automated", %{conn: conn} do
      insert_event(%{inserted_at: DateTime.utc_now()})

      insert_event(%{
        is_bot: true,
        metadata: %{"bot" => "no_js"},
        inserted_at: DateTime.utc_now()
      })

      {:ok, view, _html} = live(conn, @base)
      assert has_element?(view, "#automated-note", "1 visit judged automated is left out")

      {:ok, view, _html} = live(conn, @base <> "?bots=1")
      assert has_element?(view, "#automated-note", "Including 1 visit judged automated")
    end

    test "Overview says nothing when no visit was judged automated", %{conn: conn} do
      insert_event(%{inserted_at: DateTime.utc_now()})

      {:ok, view, _html} = live(conn, @base)
      refute has_element?(view, "#automated-note")
    end

    test "the Bots page breaks the judgement down by rule and by bot", %{conn: conn} do
      bot_event(%{metadata: %{"bot_name" => "Googlebot"}, inserted_at: DateTime.utc_now()})

      insert_event(%{
        is_bot: true,
        metadata: %{"bot" => "no_js"},
        inserted_at: DateTime.utc_now()
      })

      {:ok, view, _html} = live(conn, @base <> "/bots")

      assert has_element?(view, "#bots-automated-visits", "2 visits")
      assert has_element?(view, "#bots-automated-rule-no_js", "Never ran JavaScript")
      assert has_element?(view, "#bots-automated-rule-user_agent", "Says it is a bot")
      assert has_element?(view, "#bots-automated-names", "Googlebot")
      # Declared bots aren't kept by default: the page says they aren't counted.
      assert has_element?(view, "#bots-automated-dropped")
    end

    test "Technology names the bots when the Bots switch is on", %{conn: conn} do
      bot_event(%{metadata: %{"bot_name" => "GPTBot"}, inserted_at: DateTime.utc_now()})

      {:ok, view, _html} = live(conn, @base <> "/technology")
      refute has_element?(view, "#card-bots-info")
      refute render(view) =~ "GPTBot"

      {:ok, view, _html} = live(conn, @base <> "/technology?bots=1")
      assert has_element?(view, "#card-bots-info")
      assert render(view) =~ "GPTBot"
    end
  end

  test "the GPTBot fixture is named GPTBot" do
    assert PhoenixKitWebAnalytics.UserAgent.bot_name(@gptbot) == "GPTBot"
  end
end
