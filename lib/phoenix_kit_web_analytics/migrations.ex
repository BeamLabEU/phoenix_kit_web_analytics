defmodule PhoenixKitWebAnalytics.Migrations do
  @moduledoc """
  Versioned migration coordinator for `phoenix_kit_web_analytics` — the module
  returned from `PhoenixKitWebAnalytics.migration_module/0`.

  `mix phoenix_kit.update` discovers this, compares `migrated_version_runtime/1`
  (what's installed) with `current_version/0` (what the code needs), and — when
  behind — generates a host migration whose `up/0` calls `up/1` here. So the
  host installs/updates this module's tables with no hand-written migration,
  and it honors the host's `--prefix` (named-schema installs).

  Version is tracked via a `COMMENT ON TABLE` on
  `phoenix_kit_web_analytics_events` (mirroring core's own
  `PhoenixKit.Migrations.Postgres` and `PhoenixKitBoards.Migrations`) — not
  just a boolean "does the table exist", so a future V2 can tell "not
  installed" apart from "installed at V1".

  Versions:

    * `0` — tables absent (not installed)
    * `1` — `phoenix_kit_web_analytics_events` +
      `phoenix_kit_web_analytics_daily_stats`, UUIDv7 primary keys

  ## Prefix safety

  Every statement passes `prefix:` through, index names are bare (Postgres
  scopes an index to its table's schema), and existence checks are anchored to
  the target schema — so a `--prefix "analytics"` install lands entirely
  inside that schema.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @initial_version 1
  @current_version 1
  @default_prefix "public"
  @version_table "phoenix_kit_web_analytics_events"

  @typedoc """
  Migration options: `:prefix` and `:version`.

  Core passes a keyword list; the internal helpers normalize it to a map and
  pass that back through the same public functions, so both are accepted.
  """
  @type opts :: keyword() | map()

  @doc "The version this code expects the schema to be at."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "Run migrations up to (and including) the target version. Migration-context only."
  @spec up(opts()) :: :ok
  def up(opts \\ []) do
    opts = with_defaults(opts, @current_version)
    initial = migrated_version(opts)

    cond do
      initial == 0 -> change(@initial_version..opts.version, :up, opts)
      initial < opts.version -> change((initial + 1)..opts.version, :up, opts)
      true -> :ok
    end

    :ok
  end

  @doc "Roll back. Migration-context only."
  @spec down(opts()) :: :ok
  def down(opts \\ []) do
    opts = with_defaults(opts, 0)
    current = migrated_version(opts)
    target = Map.get(opts, :version, 0)

    if current > target, do: change(current..(target + 1)//-1, :down, opts)

    :ok
  end

  @doc """
  The version currently installed in the database (0 if the table is absent).
  Migration-context only — reads via `Ecto.Migration.repo/0`.
  """
  @spec migrated_version(opts()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(repo(), opts.escaped_prefix)
  end

  @doc """
  Runtime-safe version of `migrated_version/1` — uses PhoenixKit's configured
  repo instead of the `Ecto.Migration` `repo()` helper, so it can be called
  from Mix tasks and other non-migration contexts (`mix phoenix_kit.update`).
  """
  @spec migrated_version_runtime(opts()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(PhoenixKit.RepoHelper.repo(), opts.escaped_prefix)
  rescue
    _ -> 0
  end

  # ── v1 ────────────────────────────────────────────────────────────────────

  defp up_v1(prefix) do
    Helpers.ensure_uuid_v7_function(prefix)

    create_events_table(prefix)
    create_events_indexes(prefix)
    create_daily_stats_table(prefix)
  end

  defp create_events_table(prefix) do
    create_if_not_exists table(:phoenix_kit_web_analytics_events,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      # What happened, and where.
      add(:event_type, :string, size: 20, null: false, default: "pageview")
      add(:event_name, :string, size: 120)
      add(:site, :string, size: 255)
      add(:path, :text, null: false)
      add(:page_title, :text)

      # Who — cookieless, rotating daily hash. Never a raw identifier.
      add(:visitor_id, :string, size: 64, null: false)
      add(:session_id, :uuid, null: false)
      add(:user_uuid, :uuid)

      # Where they came from.
      add(:referrer, :text)
      add(:referrer_source, :string, size: 120)
      add(:referrer_medium, :string, size: 20)
      add(:utm_source, :string, size: 255)
      add(:utm_medium, :string, size: 255)
      add(:utm_campaign, :string, size: 255)
      add(:utm_term, :string, size: 255)
      add(:utm_content, :string, size: 255)

      # Client, derived from the User-Agent string only — no fingerprinting.
      add(:browser, :string, size: 60)
      add(:browser_version, :string, size: 30)
      add(:os, :string, size: 60)
      add(:os_version, :string, size: 30)
      add(:device_type, :string, size: 20)
      add(:language, :string, size: 20)
      add(:is_bot, :boolean, null: false, default: false)

      # Optional geo, only populated when a resolver is configured.
      add(:country_code, :string, size: 2)
      add(:region, :string, size: 120)
      add(:city, :string, size: 120)

      # Response facts — free to collect from the plug, useful as a
      # lightweight performance report.
      add(:status, :integer)
      add(:duration_ms, :integer)

      add(:metadata, :map, null: false, default: %{})

      # Events are immutable: inserted_at only, no updated_at.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  defp create_events_indexes(prefix) do
    # Every report is a time-range scan first, so `inserted_at` leads.
    create_if_not_exists(index(:phoenix_kit_web_analytics_events, [:inserted_at], prefix: prefix))

    create_if_not_exists(
      index(:phoenix_kit_web_analytics_events, [:event_type, :inserted_at], prefix: prefix)
    )

    create_if_not_exists(
      index(:phoenix_kit_web_analytics_events, [:site, :inserted_at], prefix: prefix)
    )

    # Session stitching reads the visitor's most recent event on every write.
    create_if_not_exists(
      index(:phoenix_kit_web_analytics_events, [:visitor_id, :inserted_at], prefix: prefix)
    )

    create_if_not_exists(index(:phoenix_kit_web_analytics_events, [:session_id], prefix: prefix))

    create_if_not_exists(
      index(:phoenix_kit_web_analytics_events, [:user_uuid],
        prefix: prefix,
        where: "user_uuid IS NOT NULL"
      )
    )
  end

  defp create_daily_stats_table(prefix) do
    create_if_not_exists table(:phoenix_kit_web_analytics_daily_stats,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      add(:date, :date, null: false)
      # Empty string rather than NULL so the unique index below actually
      # constrains rows with no site (NULLs never collide in Postgres).
      add(:site, :string, size: 255, null: false, default: "")

      add(:pageviews, :integer, null: false, default: 0)
      add(:visitors, :integer, null: false, default: 0)
      add(:sessions, :integer, null: false, default: 0)
      add(:bounces, :integer, null: false, default: 0)
      add(:events, :integer, null: false, default: 0)
      add(:total_session_seconds, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_web_analytics_daily_stats, [:date, :site], prefix: prefix)
    )
  end

  defp down_v1(prefix) do
    drop_if_exists(table(:phoenix_kit_web_analytics_daily_stats, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_web_analytics_events, prefix: prefix))
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp change(range, direction, opts) do
    Enum.each(range, &apply_step(direction, &1, opts.prefix))

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, max(Enum.min(range) - 1, 0))
    end
  end

  defp apply_step(:up, 1, prefix), do: up_v1(prefix)
  defp apply_step(:down, 1, prefix), do: down_v1(prefix)

  defp apply_step(direction, version, _prefix) do
    raise ArgumentError,
          "no #{direction} step defined for phoenix_kit_web_analytics schema version #{version}"
  end

  defp record_version(_opts, 0), do: :ok

  defp record_version(%{prefix: prefix}, version) do
    execute("COMMENT ON TABLE #{Helpers.qualify_table(@version_table, prefix)} IS '#{version}'")
  end

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{prefix: @default_prefix, version: version})

    opts
    |> Map.put(:quoted_prefix, inspect(opts.prefix))
    |> Map.put(:escaped_prefix, String.replace(opts.prefix, "'", "\\'"))
  end

  defp read_version(repo, escaped_prefix) do
    table_exists_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = '#{@version_table}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo.query(table_exists_query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> read_comment_version(repo, escaped_prefix)
      _ -> 0
    end
  end

  defp read_comment_version(repo, escaped_prefix) do
    version_query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = '#{@version_table}'
    AND pg_namespace.nspname = '#{escaped_prefix}'
    """

    case repo.query(version_query, [], log: false) do
      {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
      _ -> 1
    end
  end
end
