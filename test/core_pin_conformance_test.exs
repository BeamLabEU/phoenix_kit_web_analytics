defmodule PhoenixKitWebAnalytics.CorePinConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the `:phoenix_kit` requirement against being re-narrowed to a
  single core MINOR.

  The trap is the three-segment form: `~> 3.5.x` expands to
  `>= 3.5.x and < 3.6.0`, so no 3.6 or later core satisfies it. The breakage
  lands on consumers, not here — a host depending on both this module and a
  newer core minor gets an unsolvable dependency set — and nothing in this
  repo's own test run would notice.

  The requirement is `>= 3.5.0 and < 4.0.0`: the floor is the minimum core
  every PhoenixKit module requires (this module calls `Scope.held_roles/1`,
  `PhoenixKit.Admin.Events.subscribe_to_sessions/0` and
  `subscribe_to_users/0` directly), and the ceiling is open through every
  core 3.x.
  """

  @floor "3.5.0"
  @must_admit ["3.5.0", "3.5.1", "3.6.0", "3.9.9"]
  @must_reject ["2.0.0", "2.38.0", "2.65.0", "3.0.0", "3.4.9", "4.0.0"]

  test "the phoenix_kit requirement admits every core 3.x at or above the floor" do
    requirement = core_requirement()

    assert match?({:ok, _parsed}, Version.parse_requirement(requirement)),
           "`:phoenix_kit` requirement #{inspect(requirement)} is not a valid version requirement"

    for version <- @must_admit do
      assert Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} rejects core #{version}. " <>
               "Keep the floor patch-precise and the ceiling open " <>
               "(`>= #{@floor} and < 4.0.0`), never a three-segment `~>`."
    end

    for version <- @must_reject do
      refute Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} admits core #{version}, " <>
               "outside the range this module is verified against (floor #{@floor}, " <>
               "next unreleased major excluded)."
    end
  end

  # `PHOENIX_KIT_PATH` points the dep at a checkout (`path:`), which carries
  # no requirement to check; that form is never committed, so fail with the
  # reason rather than skip.
  defp core_requirement do
    Mix.Project.config()
    |> Keyword.fetch!(:deps)
    |> Enum.find_value(fn
      {:phoenix_kit, requirement} when is_binary(requirement) -> requirement
      {:phoenix_kit, requirement, _opts} when is_binary(requirement) -> requirement
      _ -> nil
    end)
    |> case do
      nil ->
        raise """
        No binary version requirement found for `:phoenix_kit` in mix.exs deps.
        If PHOENIX_KIT_PATH is set, unset it for this test.
        """

      requirement ->
        requirement
    end
  end
end
