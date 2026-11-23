defmodule PhoenixKitWebAnalytics.Web.ComponentsDeltaTest do
  use ExUnit.Case, async: true

  alias PhoenixKitWebAnalytics.Web.Components

  describe "delta/2" do
    test "percentage change from the previous value" do
      assert Components.delta(150, 100) == 50.0
      assert Components.delta(25.0, 50.0) == -50.0
    end

    test "no comparison without a previous value" do
      assert Components.delta(10, nil) == nil
      assert Components.delta(nil, 10) == nil
    end

    test "no comparison when the previous count was zero" do
      assert Components.delta(10, 0) == nil
    end

    # bounce_rate is a float percentage: a previous period whose sessions all
    # went on to a second page reports 0.0, and the dashboard must still render.
    test "no comparison when the previous rate was 0.0" do
      assert Components.delta(42.5, 0.0) == nil
      assert Components.delta(0.0, 0.0) == nil
    end
  end

  describe "delta_pp/2" do
    test "percentage-point change between two rates" do
      assert Components.delta_pp(44.0, 40.0) == 4.0
      assert Components.delta_pp(40.0, 44.0) == -4.0
      assert Components.delta_pp(25.0, 50.0) == -25.0
    end

    test "a previous rate of zero is a real baseline, not a missing one" do
      assert Components.delta_pp(42.5, 0.0) == 42.5
      assert Components.delta_pp(0.0, 0.0) == 0.0
    end

    test "no comparison without either value" do
      assert Components.delta_pp(nil, 40.0) == nil
      assert Components.delta_pp(44.0, nil) == nil
      assert Components.delta_pp(nil, nil) == nil
    end
  end
end
