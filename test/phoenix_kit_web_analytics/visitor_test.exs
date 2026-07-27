defmodule PhoenixKitWebAnalytics.VisitorTest do
  use ExUnit.Case, async: true

  doctest PhoenixKitWebAnalytics.Visitor

  alias PhoenixKitWebAnalytics.Visitor

  @ua "Mozilla/5.0 (X11; Linux x86_64) Chrome/120.0.0.0"
  @salt "test-salt"
  @date ~D[2026-03-04]

  describe "visitor_id/4" do
    test "is stable for the same inputs on the same day" do
      first = Visitor.visitor_id({1, 2, 3, 4}, @ua, @salt, @date)
      second = Visitor.visitor_id({1, 2, 3, 4}, @ua, @salt, @date)

      assert first == second
      assert String.length(first) == 32
    end

    test "rotates daily — the same person is a different id tomorrow" do
      today = Visitor.visitor_id({1, 2, 3, 4}, @ua, @salt, @date)
      tomorrow = Visitor.visitor_id({1, 2, 3, 4}, @ua, @salt, Date.add(@date, 1))

      refute today == tomorrow
    end

    test "differs per IP, per User-Agent, and per salt" do
      base = Visitor.visitor_id({1, 2, 3, 4}, @ua, @salt, @date)

      refute base == Visitor.visitor_id({1, 2, 3, 5}, @ua, @salt, @date)
      refute base == Visitor.visitor_id({1, 2, 3, 4}, @ua <> " Mobile", @salt, @date)
      refute base == Visitor.visitor_id({1, 2, 3, 4}, @ua, "other-salt", @date)
    end

    test "the IP is not recoverable from the id" do
      id = Visitor.visitor_id({192, 168, 1, 55}, @ua, @salt, @date)

      refute id =~ "192"
      refute id =~ "168"
      assert id =~ ~r/\A[0-9a-f]{32}\z/
    end

    test "handles IPv6, string addresses, and missing addresses" do
      for ip <- [{0, 0, 0, 0, 0, 0, 0, 1}, "203.0.113.9", nil] do
        assert String.length(Visitor.visitor_id(ip, @ua, @salt, @date)) == 32
      end
    end

    test "a missing User-Agent still yields an id" do
      assert String.length(Visitor.visitor_id({1, 2, 3, 4}, nil, @salt, @date)) == 32
    end
  end

  describe "format_ip/1" do
    test "formats tuples and passes strings through" do
      assert Visitor.format_ip({192, 168, 1, 1}) == "192.168.1.1"
      assert Visitor.format_ip({0, 0, 0, 0, 0, 0, 0, 1}) == "::1"
      assert Visitor.format_ip("203.0.113.9") == "203.0.113.9"
    end

    test "unusable values become \"unknown\" rather than raising" do
      assert Visitor.format_ip(nil) == "unknown"
      assert Visitor.format_ip("") == "unknown"
      assert Visitor.format_ip({999, 999}) == "unknown"
    end
  end
end
