defmodule PhoenixKitWebAnalytics.Admin do
  @moduledoc """
  Every change an operator can make to the module — settings, the tracking
  switch, a manual retention pass, a salt rotation — in one place, each logged
  to `PhoenixKit.Activity` with the acting user.

  All functions take `opts` with `:actor_uuid` (LiveViews pass
  `PhoenixKitWeb.Actor.opts(socket)`). Activity metadata carries setting
  *names* and counts, never the salt.
  """

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKitWebAnalytics.Alerts
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Retention

  @module_key "web_analytics"

  @type opts :: [actor_uuid: String.t() | nil]

  @booleans [
    :respect_dnt,
    :track_bots,
    :detect_bots,
    :beacon,
    :track_interactions,
    :client_script,
    :recording
  ]
  @alert_booleans [:visitors, :signups, :skip_users]
  @lists [:exclude_paths, :ignore_events, :event_params]
  @max_setting_length 1000
  @alert_lists [:paths, :events]
  @integers %{
    session_timeout: {1, 1440},
    retention_days: {0, 3650},
    recording_sample: {1, 100},
    recording_retention_days: {1, 3650}
  }

  @doc """
  Saves the settings form. Every field present in `params` is validated;
  fields that fail keep their previous value and are returned by name.

  Returns `{:ok, changed_keys}`, `{:error, invalid_fields}` (nothing saved
  when any field is invalid), or `{:error, :not_saved}` when a write failed —
  the writes are one transaction, so then nothing is saved either.
  """
  @spec save_settings(map(), opts()) :: {:ok, [String.t()]} | {:error, [atom()] | :not_saved}
  def save_settings(params, opts \\ []) when is_map(params) do
    with {:ok, writes} <- validate(params) do
      changes = Enum.reject(writes, fn {key, value} -> unchanged?(key, value) end)

      changes |> write_all(opts) |> after_save(opts)
    end
  end

  defp after_save({:ok, []}, _opts), do: {:ok, []}

  defp after_save({:ok, changed}, opts) do
    log("settings.updated", opts, %{"changed" => changed})
    # Reports computed under the old settings go.
    PhoenixKitWebAnalytics.ReportCache.clear()
    {:ok, changed}
  end

  defp after_save({:error, key}, opts) do
    log("settings.update_failed", opts, %{"key" => key, "db_pending" => true})
    {:error, :not_saved}
  end

  defp write_all([], _opts), do: {:ok, []}

  defp write_all(changes, opts) do
    PhoenixKit.RepoHelper.repo().transaction(fn ->
      Enum.map(changes, &write_or_roll_back(&1, opts))
    end)
  end

  defp write_or_roll_back({key, value}, opts) do
    if write(key, value, opts), do: key, else: PhoenixKit.RepoHelper.repo().rollback(key)
  end

  @doc "Switches tracking on or off (the module toggle)."
  @spec set_tracking(boolean(), opts()) :: :ok | {:error, term()}
  def set_tracking(enabled?, opts \\ []) when is_boolean(enabled?) do
    result =
      if enabled?,
        do: PhoenixKitWebAnalytics.enable_system(),
        else: PhoenixKitWebAnalytics.disable_system()

    case result do
      {:ok, _} ->
        log(if(enabled?, do: "tracking.enabled", else: "tracking.disabled"), opts, %{})
        :ok

      {:error, reason} = error ->
        Logger.warning("[WebAnalytics] tracking switch failed: #{inspect(reason)}")

        log_failure(
          if(enabled?, do: "tracking.enable_failed", else: "tracking.disable_failed"),
          opts
        )

        error
    end
  end

  @doc "Runs a rollup + prune pass now and logs what it did."
  @spec run_retention(opts()) :: %{rolled_up: non_neg_integer(), pruned: non_neg_integer()}
  def run_retention(opts \\ []) do
    result = Retention.run()

    log("retention.run", opts, %{
      "rolled_up" => result.rolled_up,
      "pruned" => result.pruned
    })

    result
  rescue
    error ->
      # The settings page reports it; the audit trail records who asked.
      log_failure("retention.failed", opts)
      reraise error, __STACKTRACE__
  end

  @doc """
  Replaces the visitor salt. Visitor IDs computed after this don't match the
  ones before, so today's visitors are counted again and open sessions split.
  """
  @spec rotate_salt(opts()) :: :ok | :error
  def rotate_salt(opts \\ []) do
    case Config.generate_salt() do
      salt when is_binary(salt) ->
        log("salt.rotated", opts, %{})
        :ok

      nil ->
        log_failure("salt.rotate_failed", opts)
        :error
    end
  end

  # ── validation ────────────────────────────────────────────────────────────

  defp validate(params) do
    keys = Config.setting_keys()
    alert_keys = Alerts.setting_keys()

    {writes, errors} =
      Enum.reduce(
        field_specs(keys, alert_keys),
        {[], []},
        fn {field, key, kind}, {writes, errors} ->
          case cast(kind, Map.get(params, Atom.to_string(field)), params) do
            :skip -> {writes, errors}
            {:ok, value} -> {[{key, value} | writes], errors}
            :error -> {writes, [field | errors]}
          end
        end
      )

    if errors == [], do: {:ok, Enum.reverse(writes)}, else: {:error, Enum.reverse(errors)}
  end

  defp field_specs(keys, alert_keys) do
    Enum.map(@booleans, &{&1, Map.fetch!(keys, &1), :boolean}) ++
      Enum.map(@lists, &{&1, Map.fetch!(keys, &1), :text}) ++
      Enum.map(@integers, fn {field, range} ->
        {field, Map.fetch!(keys, field), {:integer, range}}
      end) ++
      Enum.map(@alert_booleans, &{:"alert_#{&1}", Map.fetch!(alert_keys, &1), :boolean}) ++
      Enum.map(@alert_lists, &{:"alert_#{&1}", Map.fetch!(alert_keys, &1), :text}) ++
      [
        {:alert_max_per_hour, alert_keys.max_per_hour, {:integer, {0, 10_000}}},
        {:alert_channels, alert_keys.channels, :channels}
      ]
  end

  # The form marks which sections it rendered, so an unchecked box (which
  # submits nothing) reads as "false" rather than "not on this form".
  defp cast(:boolean, value, %{"_form" => _}), do: {:ok, bool_string(value)}
  defp cast(:boolean, nil, _params), do: :skip
  defp cast(:boolean, value, _params), do: {:ok, bool_string(value)}

  defp cast(:text, nil, _params), do: :skip
  # Core stores a setting value of at most 1000 characters; a longer one
  # would fail at the write.
  defp cast(:text, value, _params) when is_binary(value) do
    value = String.trim(value)
    if String.length(value) <= @max_setting_length, do: {:ok, value}, else: :error
  end

  defp cast(:text, _value, _params), do: :error

  defp cast({:integer, _range}, nil, _params), do: :skip

  defp cast({:integer, {min, max}}, value, _params) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int >= min and int <= max -> {:ok, Integer.to_string(int)}
      _ -> :error
    end
  end

  defp cast({:integer, _range}, _value, _params), do: :error

  # "-" is "no channel chosen" — distinct from "none", which is the direct
  # channel, and from an unset key, which means every channel.
  defp cast(:channels, nil, %{"_form" => _}), do: {:ok, "-"}
  defp cast(:channels, nil, _params), do: :skip

  defp cast(:channels, values, _params) when is_list(values) do
    case Enum.filter(values, &(&1 in Alerts.channels())) do
      [] -> {:ok, "-"}
      chosen -> {:ok, Enum.join(chosen, ", ")}
    end
  end

  defp cast(:channels, _values, _params), do: :error

  # A blank text field over an unset key is not a change either.
  defp unchanged?(key, value) do
    case Settings.get_setting(key, nil) do
      nil -> value == ""
      current -> current == value
    end
  rescue
    _ -> false
  end

  defp bool_string(value), do: to_string(value in ["true", "on", true])

  # The setting's own history (core's `setting.changed`) names the admin too.
  defp write(key, value, opts) do
    history = [actor_uuid: Keyword.get(opts, :actor_uuid), source: "settings"]

    case Settings.update_setting_with_module(key, value, @module_key, history) do
      {:ok, _} ->
        true

      other ->
        Logger.warning("[WebAnalytics] could not save #{key}: #{inspect(other)}")
        false
    end
  end

  # ── activity ──────────────────────────────────────────────────────────────

  defp log(action, opts, metadata) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(@module_key, action,
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: "web_analytics_settings",
        metadata: metadata
      )
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "[WebAnalytics] activity log failed for #{action}: #{Exception.message(error)}"
      )

      :ok
  end

  defp log_failure(action, opts) do
    log(action, opts, %{"db_pending" => true})
  end
end
