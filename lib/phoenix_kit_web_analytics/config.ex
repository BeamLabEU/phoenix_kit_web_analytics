defmodule PhoenixKitWebAnalytics.Config do
  @moduledoc """
  Settings-backed configuration for the Web Analytics module.

  Everything an operator can change lives in the host's `phoenix_kit_settings`
  table under a `web_analytics_` prefix, so it is editable from the admin
  Settings tab with no redeploy. This module is the only place that knows the
  key names and their defaults.

  ## Hot path

  `collection_config/0` is called on **every tracked request**, so it reads
  through `PhoenixKit.Settings.get_settings_cached/2` — one ETS multi-get, not
  a query per key — and every accessor degrades to its default (tracking off)
  if the settings table isn't reachable. Nothing here may raise: a broken
  settings read must cost the host a missing analytics row, never a failed
  page render.

  ## Keys

  | Key | Default | What it does |
  |-----|---------|--------------|
  | `web_analytics_enabled` | `false` | Master switch (the module toggle) |
  | `web_analytics_track_bots` | `false` | Store hits whose User-Agent looks automated |
  | `web_analytics_detect_bots` | `true` | Also flag bots by behaviour — see `PhoenixKitWebAnalytics.BotSignals` |
  | `web_analytics_respect_dnt` | `true` | Skip requests sending `DNT: 1` |
  | `web_analytics_exclude_paths` | `/admin*` … | Newline/comma separated path patterns to ignore |
  | `web_analytics_session_timeout_minutes` | `30` | Inactivity gap that ends a session |
  | `web_analytics_retention_days` | `365` | Age at which raw events are rolled up and deleted |
  | `web_analytics_beacon_enabled` | `false` | Accept hits from the JS beacon / pixel endpoints |
  | `web_analytics_track_interactions` | `true` | Record LiveView events (clicks, submits) as interactions |
  | `web_analytics_ignore_events` | `validate` | LiveView event names never recorded as interactions |
  | `web_analytics_event_params` | `tab, view, …` | Event param names whose short values are kept |
  | `web_analytics_client_script` | `false` | Accept clicks / scroll / leave from the optional client script |
  | `web_analytics_recording` | `false` | Record pointer movement, clicks, hovers and scrolling (session recordings) |
  | `web_analytics_recording_sample` | `100` | Percent of visitors recorded while recording is on |
  | `web_analytics_recording_retention_days` | `30` | Age at which recordings are deleted |
  | `web_analytics_exclude_internal_network` | `true` | Leave internal-network traffic out of the statistics |
  | `web_analytics_exclude_admin` | `true` | Leave the site staff's own visits out of the statistics |
  | `web_analytics_exclude_admin_network` | `true` | Leave visits from the staff's networks out of the statistics |
  | `web_analytics_internal_roles` | `Owner, Admin` | Roles whose holders are site staff (comma-separated) |
  | `web_analytics_admin_network_hours` | `24` | How long a staff sign-in marks its network; `0` turns that off |
  | `web_analytics_hash_secret` | generated | Secret mixed into the daily visitor hash |

  The flags behind the three `exclude_*` keys are described in
  `PhoenixKitWebAnalytics.TrafficFlags`. The internal networks themselves are
  not a setting: every settings change is a permanent activity-log entry, and
  this one would be the operator's own addresses. They come from the host's
  runtime config instead:

      config :phoenix_kit_web_analytics,
        internal_networks: ["203.0.113.0/24", "2001:db8::/48"]
  """

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Role

  @enabled_key "web_analytics_enabled"
  @track_bots_key "web_analytics_track_bots"
  @detect_bots_key "web_analytics_detect_bots"
  @respect_dnt_key "web_analytics_respect_dnt"
  @exclude_paths_key "web_analytics_exclude_paths"
  @session_timeout_key "web_analytics_session_timeout_minutes"
  @retention_days_key "web_analytics_retention_days"
  @beacon_key "web_analytics_beacon_enabled"
  # The name must keep the word "secret": core withholds the value of any key
  # whose name marks it as one from its permanent `setting.changed` activity
  # entries and change broadcast. The old `…_hash_salt` key matched nothing, so
  # every salt (and every rotation) was written into the activity log in
  # plaintext — a salt anyone with feed access could recompute visitor IDs from.
  @salt_key "web_analytics_hash_secret"
  @track_interactions_key "web_analytics_track_interactions"
  @ignore_events_key "web_analytics_ignore_events"
  @event_params_key "web_analytics_event_params"
  @client_script_key "web_analytics_client_script"
  @recording_key "web_analytics_recording"
  @recording_sample_key "web_analytics_recording_sample"
  @recording_retention_key "web_analytics_recording_retention_days"
  @exclude_internal_network_key "web_analytics_exclude_internal_network"
  @exclude_admin_key "web_analytics_exclude_admin"
  @exclude_admin_network_key "web_analytics_exclude_admin_network"
  @internal_roles_key "web_analytics_internal_roles"
  @admin_network_hours_key "web_analytics_admin_network_hours"

  # One "leave this flag out of the statistics" switch per TrafficFlags bit.
  @exclude_flag_keys [
    internal_network: @exclude_internal_network_key,
    admin: @exclude_admin_key,
    admin_network: @exclude_admin_network_key
  ]

  @module_key "web_analytics"

  @default_exclusions "/admin*\n/dev*\n/phoenix*\n/live*"
  @default_session_timeout 30
  @default_retention_days 365
  @default_ignore_events "validate"
  @default_event_params "tab, view, section, step, sort, filter, period"
  @default_recording_retention_days 30
  @default_admin_network_hours 24
  @max_admin_network_hours 720

  @hot_keys [
    @enabled_key,
    @track_bots_key,
    @detect_bots_key,
    @respect_dnt_key,
    @exclude_paths_key,
    @session_timeout_key,
    @beacon_key,
    @track_interactions_key,
    @ignore_events_key,
    @event_params_key,
    @client_script_key,
    @recording_key,
    @recording_sample_key,
    @exclude_internal_network_key,
    @exclude_admin_key,
    @exclude_admin_network_key,
    @internal_roles_key,
    @admin_network_hours_key
  ]

  @type collection_config :: %{
          enabled?: boolean(),
          track_bots?: boolean(),
          detect_bots?: boolean(),
          respect_dnt?: boolean(),
          beacon_enabled?: boolean(),
          exclusions: [String.t()],
          session_timeout_minutes: pos_integer(),
          track_interactions?: boolean(),
          client_script?: boolean(),
          recording?: boolean(),
          recording_sample: 1..100,
          ignore_events: [String.t()],
          event_params: [String.t()],
          excluded_flags: non_neg_integer(),
          internal_roles: [String.t()],
          admin_network_hours: non_neg_integer()
        }

  @doc "Settings key for the module's master switch."
  @spec enabled_key() :: String.t()
  def enabled_key, do: @enabled_key

  @doc "The `module_key/0` these settings are attributed to."
  @spec module_key() :: String.t()
  def module_key, do: @module_key

  @doc """
  Every setting the collection path needs, in one cached read.

  Returns defaults (with `enabled?: false`) if settings are unavailable, so a
  caller can treat the result as authoritative without a rescue of its own.
  """
  @spec collection_config() :: collection_config()
  def collection_config do
    values = Settings.get_settings_cached(@hot_keys, %{})

    %{
      enabled?: truthy?(values[@enabled_key], false),
      track_bots?: truthy?(values[@track_bots_key], false),
      detect_bots?: truthy?(values[@detect_bots_key], true),
      respect_dnt?: truthy?(values[@respect_dnt_key], true),
      beacon_enabled?: truthy?(values[@beacon_key], false),
      exclusions: parse_exclusions(values[@exclude_paths_key]),
      session_timeout_minutes:
        positive_integer(values[@session_timeout_key], @default_session_timeout),
      track_interactions?: truthy?(values[@track_interactions_key], true),
      client_script?: truthy?(values[@client_script_key], false),
      recording?: truthy?(values[@recording_key], false),
      recording_sample: values[@recording_sample_key] |> positive_integer(100) |> min(100),
      ignore_events: parse_list(values[@ignore_events_key] || @default_ignore_events),
      event_params: parse_list(values[@event_params_key] || @default_event_params),
      excluded_flags: excluded_flags(values),
      internal_roles: parse_roles(values[@internal_roles_key]),
      admin_network_hours: admin_network_hours(values[@admin_network_hours_key])
    }
  rescue
    error ->
      Logger.debug("[WebAnalytics] settings read failed: #{inspect(error)}")
      disabled_config()
  catch
    :exit, _ -> disabled_config()
  end

  @doc "Whether tracking is switched on."
  @spec enabled?() :: boolean()
  def enabled?, do: collection_config().enabled?

  @doc """
  The `PhoenixKitWebAnalytics.TrafficFlags` bits the statistics leave out —
  every bit unless a setting counts that kind of traffic in.
  """
  @spec excluded_flags() :: non_neg_integer()
  def excluded_flags, do: collection_config().excluded_flags

  @doc """
  The networks whose traffic is the site's own, from the host's runtime
  config (`config :phoenix_kit_web_analytics, internal_networks: [...]`) —
  CIDR strings, IPv4 or IPv6. Read as configured; see
  `PhoenixKitWebAnalytics.InternalTraffic` for how they are matched.
  """
  @spec internal_networks() :: [String.t()]
  def internal_networks do
    case Application.get_env(:phoenix_kit_web_analytics, :internal_networks, []) do
      networks when is_list(networks) -> Enum.filter(networks, &is_binary/1)
      _ -> []
    end
  end

  @doc "The default staff roles: core's Owner and Admin."
  @spec default_internal_roles() :: String.t()
  def default_internal_roles, do: Enum.join(system_staff_roles(), ", ")

  @doc "Default hours a staff sign-in marks its network for."
  @spec default_admin_network_hours() :: pos_integer()
  def default_admin_network_hours, do: @default_admin_network_hours

  @doc "Whether the beacon / pixel endpoints accept hits."
  @spec beacon_enabled?() :: boolean()
  def beacon_enabled?, do: collection_config().beacon_enabled?

  @doc "Whether the optional client script's hits (clicks, scroll, leave) are accepted."
  @spec client_script?() :: boolean()
  def client_script?, do: collection_config().client_script?

  @doc """
  Whether a LiveView event is left out of the interaction record — either
  interaction tracking is off, or the name is in the ignore list. A trailing
  `*` in the list matches a prefix, as with path exclusions.
  """
  @spec ignored_event?(String.t()) :: boolean()
  def ignored_event?(event) when is_binary(event) do
    config = collection_config()
    not config.track_interactions? or excluded?(event, config.ignore_events)
  end

  @doc "LiveView event param names whose short values an interaction keeps."
  @spec event_params() :: [String.t()]
  def event_params, do: collection_config().event_params

  @doc "Inactivity gap, in minutes, after which a new session starts."
  @spec session_timeout_minutes() :: pos_integer()
  def session_timeout_minutes, do: collection_config().session_timeout_minutes

  @doc """
  Days of raw events to keep. `0` disables pruning entirely (rollups are still
  written).
  """
  @spec retention_days() :: non_neg_integer()
  def retention_days do
    Settings.get_integer_setting(@retention_days_key, @default_retention_days)
  rescue
    _ -> @default_retention_days
  catch
    :exit, _ -> @default_retention_days
  end

  @doc "Days of session recordings to keep (30 by default)."
  @spec recording_retention_days() :: pos_integer()
  def recording_retention_days do
    case Settings.get_integer_setting(@recording_retention_key, @default_recording_retention_days) do
      days when is_integer(days) and days > 0 -> days
      _ -> @default_recording_retention_days
    end
  rescue
    _ -> @default_recording_retention_days
  catch
    :exit, _ -> @default_recording_retention_days
  end

  @doc "Raw path-exclusion setting value, for the settings form."
  @spec exclude_paths_raw() :: String.t()
  def exclude_paths_raw do
    Settings.get_setting(@exclude_paths_key, @default_exclusions) || @default_exclusions
  rescue
    _ -> @default_exclusions
  catch
    :exit, _ -> @default_exclusions
  end

  @doc "Default LiveView event names that are never recorded."
  @spec default_ignore_events() :: String.t()
  def default_ignore_events, do: @default_ignore_events

  @doc "Default event param names whose values are kept."
  @spec default_event_params() :: String.t()
  def default_event_params, do: @default_event_params

  @doc "The default path exclusions, used when the setting was never written."
  @spec default_exclusions() :: String.t()
  def default_exclusions, do: @default_exclusions

  @doc """
  Whether `path` matches any exclusion pattern.

  A pattern is a literal path, optionally ending in `*` to match a prefix.
  Matching is case-sensitive and anchored at the start of the path.

      iex> PhoenixKitWebAnalytics.Config.excluded?("/admin/users", ["/admin*"])
      true

      iex> PhoenixKitWebAnalytics.Config.excluded?("/blog", ["/admin*"])
      false
  """
  @spec excluded?(String.t(), [String.t()]) :: boolean()
  def excluded?(path, exclusions) when is_binary(path) and is_list(exclusions) do
    Enum.any?(exclusions, &matches_pattern?(path, &1))
  end

  def excluded?(_path, _exclusions), do: false

  @doc """
  The secret mixed into the daily visitor hash, or `nil` when it can't be read
  or created — in which case the hit is dropped rather than hashed with a
  guessable fallback.

  Generated and persisted on first use. Losing it is harmless — it only means
  visitor IDs computed before and after the change don't line up — but it must
  never be exposed to clients, since the hash could then be recomputed from a
  guessed IP + User-Agent pair.
  """
  @spec hash_salt() :: String.t() | nil
  def hash_salt do
    case Settings.get_setting_cached(@salt_key, nil) do
      salt when is_binary(salt) and byte_size(salt) >= 16 -> salt
      _ -> create_salt()
    end
  rescue
    error ->
      Logger.warning(
        "[WebAnalytics] could not read the visitor salt: #{Exception.message(error)}"
      )

      nil
  catch
    :exit, _ -> nil
  end

  # The first salt, created once: concurrent first hits (the collector's
  # tasks, other nodes) wait on one lock and re-read inside it, so they all
  # end up with the same salt — two would give one visitor two IDs that day.
  # A session lock on one checked-out connection, not a transaction: core
  # announces a setting write (and drops it from the cache) as the write
  # returns, which inside a transaction would come before the commit.
  defp create_salt do
    repo = PhoenixKit.RepoHelper.repo()

    repo.checkout(fn ->
      repo.query!("SELECT pg_advisory_lock(hashtext($1))", [@salt_key])

      try do
        case Settings.get_setting(@salt_key, nil) do
          salt when is_binary(salt) and byte_size(salt) >= 16 -> salt
          _ -> generate_salt()
        end
      after
        repo.query!("SELECT pg_advisory_unlock(hashtext($1))", [@salt_key])
      end
    end)
  end

  @doc """
  Generates and persists a new visitor hash salt, returning the one that ended
  up stored (`nil` if it couldn't be written) — a rotation. The first salt is
  created through `hash_salt/0` instead, under a lock, so concurrent first
  hits agree on it.
  """
  @spec generate_salt() :: String.t() | nil
  def generate_salt do
    salt = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    case Settings.update_setting_with_module(@salt_key, salt, @module_key) do
      {:ok, _} -> Settings.get_setting(@salt_key, salt) || salt
      _ -> nil
    end
  rescue
    error ->
      # The message only: an inspected changeset would contain the salt.
      Logger.warning("[WebAnalytics] could not store a visitor salt: #{Exception.message(error)}")
      nil
  catch
    :exit, _ -> nil
  end

  @doc """
  The geo resolver module, or `nil` when none is configured.

  A resolver implements `PhoenixKitWebAnalytics.Geo` and turns an IP tuple
  into `%{country_code: _, region: _, city: _}`. There is no bundled
  implementation — no IP database ships with this package.

      config :phoenix_kit_web_analytics, geo_resolver: MyApp.GeoIP
  """
  @spec geo_resolver() :: module() | nil
  def geo_resolver, do: Application.get_env(:phoenix_kit_web_analytics, :geo_resolver)

  @doc """
  Settings keys owned by this module, for the admin settings form.
  """
  @spec setting_keys() :: %{atom() => String.t()}
  def setting_keys do
    %{
      enabled: @enabled_key,
      track_bots: @track_bots_key,
      detect_bots: @detect_bots_key,
      respect_dnt: @respect_dnt_key,
      exclude_paths: @exclude_paths_key,
      session_timeout: @session_timeout_key,
      retention_days: @retention_days_key,
      beacon: @beacon_key,
      track_interactions: @track_interactions_key,
      ignore_events: @ignore_events_key,
      event_params: @event_params_key,
      client_script: @client_script_key,
      recording: @recording_key,
      recording_sample: @recording_sample_key,
      recording_retention_days: @recording_retention_key,
      exclude_internal_network: @exclude_internal_network_key,
      exclude_admin: @exclude_admin_key,
      exclude_admin_network: @exclude_admin_network_key,
      internal_roles: @internal_roles_key,
      admin_network_hours: @admin_network_hours_key
    }
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp disabled_config do
    %{
      enabled?: false,
      track_bots?: false,
      detect_bots?: true,
      respect_dnt?: true,
      beacon_enabled?: false,
      exclusions: parse_exclusions(@default_exclusions),
      session_timeout_minutes: @default_session_timeout,
      track_interactions?: false,
      client_script?: false,
      recording?: false,
      recording_sample: 100,
      ignore_events: parse_list(@default_ignore_events),
      event_params: [],
      excluded_flags: PhoenixKitWebAnalytics.TrafficFlags.all(),
      internal_roles: system_staff_roles(),
      admin_network_hours: 0
    }
  end

  # A bit is left out unless its setting says to count it in.
  defp excluded_flags(values) do
    @exclude_flag_keys
    |> Enum.filter(fn {_name, key} -> truthy?(values[key], true) end)
    |> Enum.map(&elem(&1, 0))
    |> PhoenixKitWebAnalytics.TrafficFlags.mask()
  end

  # Role names can hold spaces ("Content Editor"), so only commas and line
  # breaks separate them. An emptied setting means "no one", not the default.
  defp parse_roles(nil), do: system_staff_roles()

  defp parse_roles(value) when is_binary(value) do
    value
    |> String.split([",", "\n", "\r"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_roles(_value), do: system_staff_roles()

  defp admin_network_hours(nil), do: @default_admin_network_hours

  defp admin_network_hours(value) when is_integer(value) and value >= 0,
    do: min(value, @max_admin_network_hours)

  defp admin_network_hours(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {hours, ""} when hours >= 0 -> min(hours, @max_admin_network_hours)
      _ -> @default_admin_network_hours
    end
  end

  defp admin_network_hours(_value), do: @default_admin_network_hours

  defp system_staff_roles do
    roles = Role.system_roles()
    [roles.owner, roles.admin]
  end

  # Settings values arrive as strings ("true"/"false"); a missing key is nil.
  defp truthy?(nil, default), do: default
  defp truthy?(true, _default), do: true
  defp truthy?(false, _default), do: false
  defp truthy?(value, _default) when is_binary(value), do: value in ~w(true 1 yes on)
  defp truthy?(_value, default), do: default

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} when int > 0 -> int
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp parse_exclusions(nil), do: parse_exclusions(@default_exclusions)

  defp parse_exclusions(value) when is_binary(value) do
    value
    |> String.split([",", "\n", "\r"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_exclusions(_value), do: []

  defp parse_list(value) when is_binary(value) do
    value
    |> String.split([",", "\n", "\r", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_list(_value), do: []

  defp matches_pattern?(path, pattern) do
    if String.ends_with?(pattern, "*") do
      String.starts_with?(path, String.trim_trailing(pattern, "*"))
    else
      path == pattern
    end
  end
end
