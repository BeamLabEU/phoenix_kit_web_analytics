defmodule PhoenixKitWebAnalytics.RecordingsTest do
  use PhoenixKitWebAnalytics.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Recordings
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Schemas.Recording
  alias PhoenixKitWebAnalytics.Test.Repo

  @path "/phoenix-kit/analytics/recording"
  @ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  defp browser(conn), do: put_req_header(conn, "user-agent", @ua)

  defp chunk(attrs \\ %{}) do
    Map.merge(
      %{
        "k" => "pageKeyAbc123",
        "s" => 0,
        "p" => "/pricing",
        "w" => 1280,
        "h" => 800,
        "f" => [[0, "s", 0, 0], [120, "m", 10, 20], [400, "c", 12, 22, "main > button.buy"]]
      },
      attrs
    )
  end

  defp post_chunk(conn, payload) do
    conn
    |> browser()
    |> put_req_header("content-type", "text/plain")
    |> post(@path, Jason.encode!(payload))
  end

  describe "with recording off (the default)" do
    setup do
      enable_tracking()
      :ok
    end

    test "the script is told not to record, and chunks are dropped", %{conn: conn} do
      assert %{"record" => false} =
               conn |> browser() |> get(@path, %{"p" => "/pricing"}) |> json_response(200)

      assert post_chunk(build_conn(), chunk()).status == 204
      assert Repo.aggregate(Recording, :count) == 0
    end
  end

  describe "with recording on" do
    setup do
      enable_tracking(%{"web_analytics_recording" => "true"})
      :ok
    end

    test "the script is told to record", %{conn: conn} do
      conn = conn |> browser() |> get(@path, %{"p" => "/pricing"})

      assert %{"record" => true} = json_response(conn, 200)
      assert get_resp_header(conn, "cache-control") == ["private, max-age=60"]
    end

    test "never for an excluded path, a bot, or a visitor asking not to be tracked", %{conn: conn} do
      assert %{"record" => false} =
               conn |> browser() |> get(@path, %{"p" => "/admin/users"}) |> json_response(200)

      assert %{"record" => false} =
               build_conn()
               |> put_req_header("user-agent", "Googlebot/2.1 (+http://www.google.com/bot.html)")
               |> get(@path, %{"p" => "/pricing"})
               |> json_response(200)

      assert %{"record" => false} =
               build_conn()
               |> browser()
               |> put_req_header("dnt", "1")
               |> get(@path, %{"p" => "/pricing"})
               |> json_response(200)
    end

    test "a chunk is stored in the visit its page view started", %{conn: conn} do
      {:ok, view} =
        Collector.track(%{
          path: "/pricing",
          site: "www.example.com",
          ip: {127, 0, 0, 1},
          user_agent: @ua
        })

      assert post_chunk(conn, chunk()).status == 204

      assert [recording] = Repo.all(Recording)
      assert recording.session_id == view.session_id
      assert recording.path == "/pricing"
      assert {recording.viewport_w, recording.viewport_h} == {1280, 800}
      assert recording.frame_count == 3

      assert recording.frames == %{
               "v" => 1,
               "f" => [
                 [0, "s", 0, 0],
                 [120, "m", 10, 20],
                 [400, "c", 12, 22, "main > button.buy"]
               ]
             }

      # Recording adds no events of its own.
      assert Repo.aggregate(Event, :count) == 1
    end

    test "a resent chunk is stored once", %{conn: conn} do
      post_chunk(conn, chunk())
      post_chunk(build_conn(), chunk())

      assert Repo.aggregate(Recording, :count) == 1
    end

    test "unknown or malformed frames are dropped, text is never kept beyond a selector", %{
      conn: conn
    } do
      post_chunk(
        conn,
        chunk(%{
          "f" => [
            [10, "m", 1, 2],
            [20, "k", "secret keystroke"],
            [30, "m", "x", 2],
            ["soon", "m", 1, 2],
            [40, "c", 5, 6, String.duplicate("a", 500)],
            [50, "v", 7]
          ]
        })
      )

      assert [%{frames: %{"f" => frames}}] = Repo.all(Recording)
      assert [[10, "m", 1, 2], [40, "c", 5, 6, selector]] = frames
      assert String.length(selector) == 200
    end

    test "a payload that isn't a recording chunk stores nothing", %{conn: conn} do
      post_chunk(conn, chunk(%{"k" => "bad key!"}))
      post_chunk(build_conn(), chunk(%{"s" => 10_000}))
      post_chunk(build_conn(), chunk(%{"f" => [["no", "frames"]]}))

      build_conn()
      |> browser()
      |> put_req_header("content-type", "text/plain")
      |> post(@path, "{not json")

      assert Repo.aggregate(Recording, :count) == 0
    end

    test "only the sampled share of visitors is recorded" do
      enable_tracking(%{
        "web_analytics_recording" => "true",
        "web_analytics_recording_sample" => "50"
      })

      answers =
        for i <- 1..200 do
          Recordings.record?(
            %{ip: {10, 0, div(i, 250), rem(i, 250)}, user_agent: @ua},
            "/pricing"
          )
        end

      recorded = Enum.count(answers, & &1)
      assert recorded > 60 and recorded < 140

      # The same visitor gets the same answer every time.
      client = %{ip: {10, 1, 2, 3}, user_agent: @ua}
      assert Recordings.record?(client, "/a") == Recordings.record?(client, "/b")
    end
  end

  describe "replaying a visit" do
    setup do
      enable_tracking(%{"web_analytics_recording" => "true"})
      :ok
    end

    test "for_session/1 joins each page view's chunks in order", %{conn: conn} do
      {:ok, view} =
        Collector.track(%{
          path: "/pricing",
          site: "www.example.com",
          ip: {127, 0, 0, 1},
          user_agent: @ua
        })

      post_chunk(conn, chunk(%{"s" => 1, "f" => [[6000, "m", 3, 3]]}))
      post_chunk(build_conn(), chunk(%{"s" => 0, "f" => [[100, "m", 1, 1], [5000, "m", 2, 2]]}))

      post_chunk(
        build_conn(),
        chunk(%{"k" => "otherPage12345", "p" => "/blog", "f" => [[50, "c", 9, 9, "a"]]})
      )

      assert Recordings.recorded?(view.session_id)
      pages = Recordings.for_session(view.session_id)

      assert [%{path: "/pricing", frames: frames}, %{path: "/blog"}] = pages
      assert frames == [[100, "m", 1, 1], [5000, "m", 2, 2], [6000, "m", 3, 3]]
      refute Recordings.recorded?(Ecto.UUID.generate())
      assert Recordings.for_session("not-a-uuid") == []
    end

    test "replay/1 loads only pages this visit really viewed", %{conn: conn} do
      {:ok, view} =
        Collector.track(%{
          path: "/pricing",
          site: "www.example.com",
          ip: {127, 0, 0, 1},
          user_agent: @ua
        })

      post_chunk(conn, chunk())

      # A path the visitor's browser claims, but never requested.
      post_chunk(build_conn(), chunk(%{"k" => "claimedPage123", "p" => "/users/log-out"}))

      assert [%{path: "/pricing", loadable: true}, %{path: "/users/log-out", loadable: false}] =
               Recordings.replay(view.session_id)
    end

    test "paths that a browser could read as another site are refused" do
      bad = [
        "https://evil.example/x",
        "//evil.example/x",
        "/\\evil.example",
        "/\t/evil.example",
        "x"
      ]

      for {path, i} <- Enum.with_index(bad) do
        post_chunk(build_conn(), chunk(%{"k" => "badPathKey#{i}xx", "p" => path}))
      end

      assert Repo.aggregate(Recording, :count) == 0
    end

    test "one visitor is held to 30 chunks a minute" do
      unless Process.whereis(PhoenixKitWebAnalytics.BotSignals),
        do: start_supervised!(PhoenixKitWebAnalytics.BotSignals)

      await_fresh_minute()
      for seq <- 0..39, do: post_chunk(build_conn(), chunk(%{"s" => seq}))

      assert Repo.aggregate(Recording, :count) == 30
    end

    test "a page view's later chunks stay in the visit its first chunk joined", %{conn: conn} do
      post_chunk(conn, chunk(%{"s" => 0}))
      [first] = Repo.all(Recording)

      # The visitor's next hit starts a new visit (the old one timed out)…
      Repo.update_all(Event, set: [inserted_at: hours_ago(2)])
      Repo.update_all(Recording, set: [inserted_at: hours_ago(2)])

      {:ok, _} =
        Collector.track(%{
          path: "/later",
          site: "www.example.com",
          ip: {127, 0, 0, 1},
          user_agent: @ua
        })

      # …but the open page's next chunk still belongs with its first.
      post_chunk(build_conn(), chunk(%{"s" => 1}))

      assert Repo.all(from(r in Recording, select: r.session_id)) |> Enum.uniq() == [
               first.session_id
             ]
    end

    test "an excluded path is never loaded behind a replay, even one the visit saw", %{conn: conn} do
      enable_tracking(%{
        "web_analytics_recording" => "true",
        "web_analytics_exclude_paths" => "/private*"
      })

      {:ok, view} =
        Collector.track(%{
          path: "/shop",
          site: "www.example.com",
          ip: {127, 0, 0, 1},
          user_agent: @ua
        })

      post_chunk(conn, chunk(%{"p" => "/shop"}))
      assert [%{loadable: true}] = Recordings.replay(view.session_id)

      # Excluded after the fact: the stored chunk stays, the page won't load.
      enable_tracking(%{
        "web_analytics_recording" => "true",
        "web_analytics_exclude_paths" => "/shop*"
      })

      assert [%{loadable: false}] = Recordings.replay(view.session_id)
    end

    test "dot segments, plain or %-encoded, are refused (the browser would resolve them)" do
      for {path, i} <-
            Enum.with_index(["/blog/../admin", "/blog/%2e%2e/admin", "/./x", "/a/%2E/b"]) do
        post_chunk(build_conn(), chunk(%{"k" => "dotSegment#{i}xx", "p" => path}))
      end

      assert Repo.aggregate(Recording, :count) == 0
    end

    test "a page with a trailing slash matches its page view, so it can be replayed", %{
      conn: conn
    } do
      {:ok, view} =
        Collector.track(%{
          path: "/docs/",
          site: "www.example.com",
          ip: {127, 0, 0, 1},
          user_agent: @ua
        })

      post_chunk(conn, chunk(%{"p" => "/docs/"}))

      assert [%{path: "/docs", loadable: true}] = Recordings.replay(view.session_id)
    end

    test "the query string and fragment never reach the stored path", %{conn: conn} do
      post_chunk(conn, chunk(%{"p" => "/reset?token=secret#top"}))

      assert [%{path: "/reset"}] = Repo.all(Recording)
    end

    test "a page view the visitor's browser reported (the beacon) is never loaded behind a replay",
         %{conn: conn} do
      {:ok, view} =
        Collector.track(%{
          path: "/pricing",
          site: "www.example.com",
          ip: {127, 0, 0, 1},
          user_agent: @ua
        })

      # The same visitor claims a page view through the beacon…
      {:ok, _} =
        Collector.track(%{
          path: "/users/log-out",
          site: "www.example.com",
          ip: {127, 0, 0, 1},
          user_agent: @ua,
          metadata: %{"source" => "beacon"}
        })

      post_chunk(conn, chunk(%{"k" => "claimedPage123", "p" => "/users/log-out"}))

      # …which doesn't make it loadable.
      assert [%{path: "/users/log-out", loadable: false}] = Recordings.replay(view.session_id)
    end

    test "prune/0 deletes recordings past their retention", %{conn: conn} do
      post_chunk(conn, chunk())
      post_chunk(build_conn(), chunk(%{"s" => 1}))

      old = DateTime.add(DateTime.utc_now(), -31, :day)
      Repo.update_all(from(r in Recording, where: r.seq == 0), set: [inserted_at: old])

      assert Recordings.prune() == 1
      assert [%{seq: 1}] = Repo.all(Recording)
    end
  end
end
