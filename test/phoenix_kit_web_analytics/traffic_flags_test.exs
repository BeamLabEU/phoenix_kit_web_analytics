defmodule PhoenixKitWebAnalytics.TrafficFlagsTest do
  use ExUnit.Case, async: true

  import Bitwise

  doctest PhoenixKitWebAnalytics.TrafficFlags

  alias PhoenixKitWebAnalytics.TrafficFlags

  test "every flag is one bit of its own" do
    bits = Enum.map(TrafficFlags.flags(), &elem(&1, 1))

    assert Enum.all?(bits, &(&1 > 0 and (&1 &&& &1 - 1) == 0))
    assert Enum.uniq(bits) == bits
    assert Enum.reduce(bits, 0, &(&1 ||| &2)) == Enum.sum(bits)
  end

  test "the iteration-one bits keep their values; 8, 16 and 32 stay free" do
    assert TrafficFlags.bit(:internal_network) == 1
    assert TrafficFlags.bit(:admin) == 2
    assert TrafficFlags.bit(:admin_network) == 4
    assert TrafficFlags.all() == 7
    assert (TrafficFlags.all() &&& (8 ||| 16 ||| 32)) == 0
  end

  test "a smallint column holds every combination" do
    assert TrafficFlags.all() <= 32_767
  end

  test "excluded?/2 is any shared bit" do
    assert TrafficFlags.excluded?(3, 2)
    refute TrafficFlags.excluded?(1, 6)
    refute TrafficFlags.excluded?(0, TrafficFlags.all())
    refute TrafficFlags.excluded?(7, 0)
    refute TrafficFlags.excluded?(nil, 7)
  end

  test "names_in/1 and mask/1 are inverses" do
    for flags <- 0..TrafficFlags.all() do
      assert flags |> TrafficFlags.names_in() |> TrafficFlags.mask() == flags
    end
  end

  test "every flag has a label" do
    for name <- TrafficFlags.names(), do: assert(is_binary(TrafficFlags.label(name)))
  end
end
