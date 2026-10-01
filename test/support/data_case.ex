defmodule PhoenixKitWebAnalytics.DataCase do
  @moduledoc """
  Test case for tests requiring database access.

  Uses `PhoenixKitWebAnalytics.Test.Repo` with SQL Sandbox for isolation.
  Tests using this case are tagged `:integration` and are automatically
  excluded when the database is unavailable.

  The settings cache is cleared before every test: it lives outside the sandbox
  transaction, so a value written by one test would otherwise be visible to the
  next one even though its database row was rolled back.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitWebAnalytics.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitWebAnalytics.DataCase
      import PhoenixKitWebAnalytics.ActivityLogAssertions
    end
  end

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    clear_settings_cache()

    :ok
  end

  @doc """
  Empties the PhoenixKit settings cache and waits for the clear to land.

  `clear/1` is a cast, so the following `stats/1` call — a synchronous
  `GenServer.call` on the same process — is what makes it ordered.
  """
  def clear_settings_cache do
    PhoenixKit.Cache.clear(:settings)
    PhoenixKit.Cache.stats(:settings)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Turns tracking on for the current test, with any extra settings applied.

      enable_tracking(%{"web_analytics_track_bots" => "true"})
  """
  def enable_tracking(extra \\ %{}) do
    PhoenixKit.Settings.update_boolean_setting_with_module(
      "web_analytics_enabled",
      true,
      "web_analytics"
    )

    Enum.each(extra, fn {key, value} ->
      PhoenixKit.Settings.update_setting_with_module(key, value, "web_analytics")
    end)

    clear_settings_cache()

    # Prime the cache with what we just wrote, so the first read in the test
    # doesn't depend on the cache's miss-fill timing. `Cache.put/3` is a cast
    # to the same GenServer that serves reads, so it is ordered ahead of them.
    PhoenixKit.Cache.put(:settings, "web_analytics_enabled", "true")

    Enum.each(extra, fn {key, value} ->
      PhoenixKit.Cache.put(:settings, key, to_string(value))
    end)

    :ok
  end

  @doc """
  Inserts one event with sensible defaults, bypassing
  `PhoenixKitWebAnalytics.Collector` so a test can control `inserted_at`,
  `visitor_id`, and `session_id` exactly.

      insert_event(%{path: "/pricing", inserted_at: hours_ago(3)})
  """
  def insert_event(attrs \\ %{}) do
    defaults = %{
      event_type: "pageview",
      path: "/",
      site: "example.com",
      visitor_id: "visitor-#{System.unique_integer([:positive])}",
      session_id: UUIDv7.generate(),
      inserted_at: DateTime.utc_now()
    }

    event =
      %Event{}
      |> Event.changeset(Map.merge(defaults, attrs))
      |> TestRepo.insert!()

    mark_session_start(event.session_id)
    TestRepo.get!(Event, event.uuid)
  end

  # The collector marks the first hit of each visit as it stores it; a test
  # inserting rows directly (in any order) gets the same marking here.
  defp mark_session_start(session_id) do
    SQL.query!(
      TestRepo,
      """
      UPDATE phoenix_kit_web_analytics_events AS e
      SET session_start = (e.uuid = first.uuid)
      FROM (
        SELECT f.uuid FROM phoenix_kit_web_analytics_events AS f
        WHERE f.session_id = $1
        ORDER BY f.inserted_at, f.uuid LIMIT 1
      ) AS first
      -- The first hit is found once, and only rows whose flag changes are
      -- touched: a test inserting hundreds of hits into one visit stays linear.
      WHERE e.session_id = $1 AND e.session_start IS DISTINCT FROM (e.uuid = first.uuid)
      """,
      [Ecto.UUID.dump!(session_id)]
    )
  end

  @doc "A `DateTime` the given number of hours in the past."
  def hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

  @doc "A `DateTime` at midday, the given number of days in the past."
  def days_ago(days) do
    Date.utc_today()
    |> Date.add(-days)
    |> DateTime.new!(~T[12:00:00], "Etc/UTC")
  end

  @doc """
  Translates changeset errors into a `%{field => [message]}` map.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
