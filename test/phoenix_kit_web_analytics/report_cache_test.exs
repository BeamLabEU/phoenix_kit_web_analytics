defmodule PhoenixKitWebAnalytics.ReportCacheTest do
  use ExUnit.Case, async: false

  alias PhoenixKitWebAnalytics.ReportCache

  setup do
    unless Process.whereis(ReportCache), do: start_supervised!(ReportCache)
    ReportCache.clear()
    :ok
  end

  test "a ttl of 0 computes every time" do
    counter = :counters.new(1, [])
    for _ <- 1..3, do: ReportCache.fetch(:zero, fn -> :counters.add(counter, 1, 1) end, 0)
    assert :counters.get(counter, 1) == 3
  end

  test "concurrent misses on one key compute it once" do
    counter = :counters.new(1, [])

    slow = fn ->
      :counters.add(counter, 1, 1)
      Process.sleep(150)
      :result
    end

    results =
      1..20
      |> Enum.map(fn _ ->
        Task.async(fn -> ReportCache.fetch({:stampede, 1}, slow, 10_000) end)
      end)
      |> Task.await_many(5_000)

    assert Enum.all?(results, &(&1 == :result))
    assert :counters.get(counter, 1) == 1
  end

  test "an expired value is served to others while one caller recomputes" do
    assert ReportCache.fetch(:stale, fn -> :old end, 1) == :old
    Process.sleep(5)

    parent = self()

    recompute =
      Task.async(fn ->
        ReportCache.fetch(
          :stale,
          fn ->
            send(parent, :computing)
            Process.sleep(200)
            :new
          end,
          10_000
        )
      end)

    assert_receive :computing
    assert ReportCache.fetch(:stale, fn -> flunk("computed twice") end, 10_000) == :old
    assert Task.await(recompute) == :new
    assert ReportCache.fetch(:stale, fn -> flunk("computed again") end, 10_000) == :new
  end

  test "waiters take over when the computing process dies" do
    task =
      Task.async(fn ->
        ReportCache.fetch(:dies, fn -> Process.exit(self(), :kill) end, 10_000)
      end)

    Task.shutdown(task, :brutal_kill)
    assert ReportCache.fetch(:dies, fn -> :recovered end, 10_000) == :recovered
  end
end
