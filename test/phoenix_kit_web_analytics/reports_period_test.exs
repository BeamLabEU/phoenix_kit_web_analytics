defmodule PhoenixKitWebAnalytics.ReportsPeriodTest do
  @moduledoc """
  The parts of `PhoenixKitWebAnalytics.Reports` that are pure date maths — no
  database needed, so these run everywhere.
  """

  use ExUnit.Case, async: true

  doctest PhoenixKitWebAnalytics.Reports

  alias PhoenixKitWebAnalytics.Reports

  describe "period_range/2" do
    test "today covers exactly one day, ending at tomorrow's start" do
      {from, to} = Reports.period_range("today", ~U[2026-03-04 15:30:00Z])

      assert DateTime.to_date(from) == ~D[2026-03-04]
      assert from.hour == 0
      assert DateTime.to_date(to) == ~D[2026-03-05]
    end

    test "yesterday ends where today begins" do
      {from, to} = Reports.period_range("yesterday", ~U[2026-03-04 15:30:00Z])

      assert DateTime.to_date(from) == ~D[2026-03-03]
      assert DateTime.to_date(to) == ~D[2026-03-04]
    end

    test "7d includes today, so it spans seven days" do
      {from, to} = Reports.period_range("7d", ~U[2026-03-10 09:00:00Z])

      assert DateTime.to_date(from) == ~D[2026-03-04]
      assert DateTime.to_date(to) == ~D[2026-03-11]
      assert DateTime.diff(to, from, :day) == 7
    end

    test "30d and 90d span their nominal number of days" do
      now = ~U[2026-03-10 09:00:00Z]

      {from_30, to_30} = Reports.period_range("30d", now)
      {from_90, to_90} = Reports.period_range("90d", now)

      assert DateTime.diff(to_30, from_30, :day) == 30
      assert DateTime.diff(to_90, from_90, :day) == 90
    end

    test "every window ends in the future, so today's hits are included" do
      now = DateTime.utc_now()

      for {period, _label} <- Reports.periods() do
        {_from, to} = Reports.period_range(period, now)

        if period != "yesterday" do
          assert DateTime.compare(to, now) == :gt,
                 "#{period} window ends before now, so today's traffic would be missing"
        end
      end
    end

    test "an unknown period falls back to the default rather than raising" do
      now = ~U[2026-03-10 09:00:00Z]

      assert Reports.period_range("nonsense", now) ==
               Reports.period_range(Reports.default_period(), now)

      assert Reports.period_range("", now) == Reports.period_range("7d", now)
    end
  end

  describe "bucket_for/1" do
    test "short windows chart hourly, long windows monthly" do
      assert Reports.bucket_for("today") == :hour
      assert Reports.bucket_for("yesterday") == :hour
      assert Reports.bucket_for("7d") == :day
      assert Reports.bucket_for("30d") == :day
      assert Reports.bucket_for("90d") == :day
      assert Reports.bucket_for("12m") == :month
      assert Reports.bucket_for("all") == :month
    end
  end

  describe "filter/1" do
    test "carries the period label and normalizes blank restrictions" do
      filter = Reports.filter(period: "30d", site: "  ", path: "")

      assert filter.period == "30d"
      assert filter.site == nil
      assert filter.path == nil
    end

    test "defaults to the default period when none is given" do
      assert Reports.filter().period == Reports.default_period()
    end
  end

  describe "periods/0 and period_label/1" do
    test "every period has a label, and labels round-trip" do
      for {value, label} <- Reports.periods() do
        assert Reports.period_label(value) == label
      end
    end

    test "an unknown value labels as itself rather than raising" do
      assert Reports.period_label("nonsense") == "nonsense"
    end
  end
end
