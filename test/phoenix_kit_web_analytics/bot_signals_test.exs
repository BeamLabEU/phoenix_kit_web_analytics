defmodule PhoenixKitWebAnalytics.BotSignalsTest do
  use PhoenixKitWebAnalytics.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKitWebAnalytics.BotSignals
  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Test.Repo

  @chrome "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  defp hit(attrs \\ %{}) do
    Map.merge(%{path: "/", site: "example.com", ip: {203, 0, 113, 9}, user_agent: @chrome}, attrs)
  end

  defp reasons,
    do: Repo.all(from(e in Event, order_by: e.inserted_at, select: {e.is_bot, e.metadata["bot"]}))

  setup do
    unless Process.whereis(BotSignals), do: start_supervised!(BotSignals)
    :ok
  end

  describe "speed" do
    setup do
      Application.put_env(:phoenix_kit_web_analytics, :bot_pageviews_per_minute, 3)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_web_analytics, :bot_pageviews_per_minute)
      end)

      :ok
    end

    test "going over the limit flags the visit, earlier hits included, and later hits are dropped" do
      enable_tracking()

      for _ <- 1..3, do: assert({:ok, _} = Collector.track(hit()))
      assert {:error, :bot} = Collector.track(hit())
      assert {:error, :bot} = Collector.track(hit())

      assert reasons() == List.duplicate({true, "rate"}, 3)
    end

    test "with bot traffic kept, the fast hits are stored flagged" do
      enable_tracking(%{"web_analytics_track_bots" => "true"})

      for _ <- 1..5, do: assert({:ok, _} = Collector.track(hit()))

      assert reasons() == List.duplicate({true, "rate"}, 5)
    end

    test "only page views count, and not with detection off" do
      enable_tracking(%{"web_analytics_detect_bots" => "false"})
      for _ <- 1..5, do: Collector.track(hit())
      assert Enum.all?(reasons(), &(&1 == {false, nil}))

      enable_tracking()
      Repo.delete_all(Event)

      for _ <- 1..6,
          do:
            Collector.track(
              hit(%{event_type: "interaction", event_name: "click", ip: {9, 9, 9, 9}})
            )

      assert Enum.all?(reasons(), &(&1 == {false, nil}))
    end
  end

  describe "automation (navigator.webdriver)" do
    test "the client script's report flags the visitor's day, and the visit stays flagged", %{
      conn: conn
    } do
      enable_tracking(%{
        "web_analytics_client_script" => "true",
        "web_analytics_track_bots" => "true"
      })

      {:ok, _} = Collector.track(hit(%{ip: {127, 0, 0, 1}}))

      conn
      |> put_req_header("user-agent", @chrome)
      |> put_req_header("content-type", "text/plain")
      |> post("/phoenix-kit/analytics/event", Jason.encode!(%{"e" => "automation"}))

      assert reasons() == [{true, "webdriver"}]

      # Later hits of the visit inherit the flag.
      {:ok, next} = Collector.track(hit(%{ip: {127, 0, 0, 1}, path: "/next"}))
      assert next.is_bot and next.metadata["bot"] == "webdriver"
    end

    test "ignored while the client script is off", %{conn: conn} do
      enable_tracking()
      {:ok, _} = Collector.track(hit(%{ip: {127, 0, 0, 1}}))

      conn
      |> put_req_header("user-agent", @chrome)
      |> put_req_header("content-type", "text/plain")
      |> post("/phoenix-kit/analytics/event", Jason.encode!(%{"e" => "automation"}))

      assert reasons() == [{false, nil}]
    end
  end

  describe "no JavaScript" do
    setup do
      enable_tracking()
      :ok
    end

    defp page(visitor, at, attrs \\ %{}) do
      insert_event(
        Map.merge(%{visitor_id: visitor, inserted_at: at, metadata: %{"lv" => true}}, attrs)
      )
    end

    test "a LiveView page that never connected flags its visit; one that did, doesn't" do
      at = hours_ago(2)
      scraper = page("scraper", at)
      person = page("person", at)

      insert_event(%{
        visitor_id: "person",
        session_id: person.session_id,
        event_type: "leave",
        engaged_ms: 5_000,
        metadata: %{"source" => "live_presence"},
        inserted_at: DateTime.add(at, 5, :second)
      })

      # A page without the hook proves nothing either way.
      plain = page("plain", at, %{metadata: %{}})

      assert BotSignals.judge_no_js() == 1

      flagged = Repo.all(from(e in Event, where: e.is_bot, select: e.session_id))
      assert flagged == [scraper.session_id]
      refute plain.session_id in flagged
    end

    test "a visit is judged only after it has had time to connect" do
      recent = page("recent", DateTime.add(DateTime.utc_now(), -60, :second))
      old = page("old", hours_ago(2))

      assert BotSignals.judge_no_js() == 1
      assert Repo.all(from(e in Event, where: e.is_bot, select: e.session_id)) == [old.session_id]

      # Judging again changes nothing: a flagged visit is skipped.
      assert BotSignals.judge_no_js() == 0

      # The recent visit is judged once it has had its time.
      assert BotSignals.judge_no_js(DateTime.add(DateTime.utc_now(), 3600, :second)) == 1

      assert recent.session_id in Repo.all(
               from(e in Event, where: e.is_bot, select: e.session_id)
             )
    end

    test "a busy window is judged whole, a batch at a time" do
      sessions = for i <- 1..5, do: page("scraper-#{i}", DateTime.add(hours_ago(2), i, :second))

      assert BotSignals.judge_no_js(DateTime.utc_now(), batch: 2) == 5

      assert Enum.sort(Repo.all(from(e in Event, where: e.is_bot, select: e.session_id))) ==
               Enum.sort(Enum.map(sessions, & &1.session_id))
    end

    test "writes no setting (each would be a permanent activity-log entry)" do
      page("scraper", hours_ago(2))
      changes = from(a in "phoenix_kit_activities", where: a.action == "setting.changed")
      before = Repo.aggregate(changes, :count)

      assert BotSignals.judge_no_js() == 1
      assert Repo.aggregate(changes, :count) == before
    end

    test "a flagged visit is cleared when its JavaScript shows up after all (a tab left open)" do
      opened = hours_ago(2)
      {:ok, view} = Collector.track(hit(%{inserted_at: opened, metadata: %{"lv" => true}}))
      assert BotSignals.judge_no_js() == 1
      assert reasons() == [{true, "no_js"}]

      # The tab closes hours later: its leave belongs to the page's visit.
      {:ok, leave} =
        Collector.track(
          hit(%{
            event_type: "leave",
            engaged_ms: 7_000_000,
            session_anchor: opened,
            metadata: %{"source" => "live_presence"}
          })
        )

      assert leave.session_id == view.session_id
      assert Enum.all?(reasons(), &(&1 == {false, nil}))
    end

    test "nothing is judged with detection off" do
      enable_tracking(%{"web_analytics_detect_bots" => "false"})
      page("scraper", hours_ago(2))

      assert BotSignals.judge_no_js() == 0
    end
  end
end
