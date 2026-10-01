defmodule PhoenixKitWebAnalytics.RollupReaderTest do
  @moduledoc """
  Reports read finished days from the daily rollups and only the rest from raw
  events — so a period reads a few rows per day instead of every event. That
  is only worth anything if the numbers are the same: every report here is
  computed three ways over one mixed data set — all raw, rolled up + raw, and
  rolled up with the raw rows of those days deleted (as retention does) — and
  must come out identical.
  """

  use PhoenixKitWebAnalytics.DataCase, async: false

  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Retention
  alias PhoenixKitWebAnalytics.RollupReader
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Test.Repo

  setup do
    enable_tracking()
    seed()
    :ok
  end

  # Four days ago through today: several visitors and visits per day, two
  # sites, pages, referrers, campaigns, devices, exits, interactions, custom
  # events and a bot.
  defp seed do
    for day <- 0..4, visitor <- 1..3 do
      date = Date.add(Date.utc_today(), -day)
      start = DateTime.new!(date, ~T[08:00:00], "Etc/UTC") |> DateTime.add(visitor * 600, :second)
      session = UUIDv7.generate()
      vid = "d#{day}-v#{visitor}"
      site = if visitor == 3, do: "other.example", else: "example.com"

      base = %{
        visitor_id: vid,
        session_id: session,
        site: site,
        browser: Enum.at(["Chrome", "Safari", "Firefox"], visitor - 1),
        os: Enum.at(["macOS", "iOS", "Windows"], visitor - 1),
        device_type: Enum.at(["desktop", "mobile", "desktop"], visitor - 1),
        language: "et-EE",
        country_code: if(visitor == 2, do: "EE")
      }

      insert_event(
        Map.merge(base, %{
          path: "/",
          inserted_at: start,
          duration_ms: 20 + visitor,
          referrer_source: Enum.at(["Google", "Hacker News", nil], visitor - 1),
          referrer_medium: Enum.at(["organic", "social", "none"], visitor - 1),
          utm_campaign: if(visitor == 1, do: "autumn"),
          utm_source: if(visitor == 1, do: "newsletter")
        })
      )

      insert_event(
        Map.merge(base, %{
          path: "/pricing",
          inserted_at: DateTime.add(start, 30, :second),
          duration_ms: 90,
          referrer_medium: "internal"
        })
      )

      insert_event(
        Map.merge(base, %{
          event_type: "interaction",
          event_name: "add_to_cart",
          target: if(visitor == 2, do: "github.com/x"),
          path: "/pricing",
          inserted_at: DateTime.add(start, 45, :second)
        })
      )

      insert_event(
        Map.merge(base, %{
          event_type: "leave",
          path: "/pricing",
          engaged_ms: 15_000 * visitor,
          scroll_depth: 25 * visitor,
          inserted_at: DateTime.add(start, 60, :second)
        })
      )

      if visitor == 1 do
        insert_event(
          Map.merge(base, %{
            event_type: "event",
            event_name: "signup",
            path: "/pricing",
            inserted_at: DateTime.add(start, 70, :second)
          })
        )
      end
    end

    insert_event(%{visitor_id: "bot", is_bot: true, path: "/", inserted_at: days_ago(2)})
  end

  # Names the reports that differ, rather than dumping two whole maps.
  defp assert_same(expected, actual, context) do
    differing = for {key, value} <- expected, actual[key] != value, do: {key, value, actual[key]}
    assert differing == [], "#{context}: #{inspect(differing, pretty: true)}"
  end

  defp everything(filter) do
    %{
      overview: Reports.overview(filter),
      timeseries: Reports.timeseries(filter, :day),
      top_paths: Reports.top_paths(filter),
      top_paths_page2: Reports.top_paths(filter, limit: 1, offset: 1),
      referrers: Reports.top_referrers(filter),
      channels: Reports.channels(filter),
      campaigns: Reports.top_campaigns(filter),
      utm_sources: Reports.top_utm_sources(filter),
      browsers: Reports.browsers(filter),
      systems: Reports.operating_systems(filter),
      devices: Reports.devices(filter),
      languages: Reports.languages(filter),
      countries: Reports.countries(filter),
      events: Reports.top_events(filter),
      interactions: Reports.top_interactions(filter),
      exits: Reports.exit_pages(filter),
      engagement: Reports.page_engagement(filter, ["/", "/pricing"]),
      slowest: Reports.slowest_paths(filter),
      sites: Enum.sort(Reports.sites(filter))
    }
  end

  test "rolled-up days + today report exactly what raw events do — and still after the raw days are pruned" do
    for period <- ["7d", "30d"], site <- [nil, "example.com"] do
      filter = Reports.filter(period: period, site: site)

      raw = everything(filter)
      assert RollupReader.plan(filter).dates == nil

      assert Retention.rollup_pending_days() > 0
      plan = RollupReader.plan(filter)
      assert {_first, last} = plan.dates
      assert last == Date.add(Date.utc_today(), -1)
      assert %{} = plan.raw

      assert_same(raw, everything(filter), "rolled + raw, #{period} / #{inspect(site)}")

      # Retention's prune: the rolled-up days' raw rows are gone.
      today = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      {deleted, _} = Repo.delete_all(from(e in Event, where: e.inserted_at < ^today))
      assert deleted > 0

      assert_same(raw, everything(filter), "rollups alone, #{period} / #{inspect(site)}")

      # Next round starts from the same data.
      Repo.delete_all(Event)
      Repo.delete_all(PhoenixKitWebAnalytics.Schemas.DailyStat)
      Repo.delete_all(PhoenixKitWebAnalytics.Schemas.DailyDim)
      Repo.query!("DELETE FROM phoenix_kit_settings WHERE key = 'web_analytics_rolled_through'")
      clear_settings_cache()
      seed()
    end
  end

  test "hourly periods, a page filter and bot traffic read raw events" do
    Retention.rollup_pending_days()

    assert RollupReader.plan(Reports.filter(period: "today")).dates == nil
    assert RollupReader.plan(Reports.filter(period: "7d", path: "/pricing")).dates == nil
    assert RollupReader.plan(Reports.filter(period: "7d", bots: true)).dates == nil
    assert RollupReader.plan(Reports.filter(period: "7d")).dates != nil
  end

  test "bot traffic stays out of the rollups" do
    Retention.rollup_pending_days()
    filter = Reports.filter(period: "7d")

    assert Reports.overview(filter).pageviews ==
             Reports.overview(%{filter | bots: true}).pageviews - 1
  end
end
