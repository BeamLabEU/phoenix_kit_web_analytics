defmodule PhoenixKitWebAnalytics.Alerts do
  @moduledoc """
  Tells the site's staff when something happens on the site — a visitor
  arriving, someone signing up, an event you care about — through PhoenixKit's
  notification system, so it reaches the in-app inbox, email, or Telegram
  with no per-project code.

  ## What can alert

  Three notification sub-types under **Website activity**
  (`notification_types/0`), each switchable per person on the Notifications
  settings page, per channel, with core's aggregation (immediate / hourly /
  daily digest):

    * **New visitors** — the first page view of a new session. Off by default
      (`web_analytics_alert_visitors`), and narrowed by the filters below.
    * **New sign-ups** — an account was created, by any registration path
      (password, magic link, OAuth, admin). On by default
      (`web_analytics_alert_signups`).
    * **Tracked events** — a custom event or LiveView interaction whose name is
      listed in `web_analytics_alert_events` (e.g. `order.placed, contact`).

  ## Keeping visitor alerts useful

  A notification per visitor is a flood on any site with real traffic, so the
  visitor alert has filters, all in the module's Settings page:

    * **channels** — only visitors arriving from these channels (`organic`,
      `social`, `referral`, `email`, `paid`, `none` for direct);
    * **landing pages** — only sessions that start on a matching path
      (same `*` prefix patterns as path exclusions);
    * **skip signed-in users** — on by default; your own users browsing are
      not news;
    * **hourly cap** — at most N visitor alerts per hour (default 20); the
      next alert after a quiet spell says how many were held back.

  Beyond that, a person can pick an hourly or daily digest for the type in
  their own notification settings, which turns the stream into one summary.

  ## Who receives them

  Everyone who can open Web Analytics: Owners, and every active user whose
  role grants the `web_analytics` permission (or the `*` wildcard). The list is
  cached for five minutes.

  ## Delivery

  Each alert is one `PhoenixKit.Activity` entry per recipient (the recipient as
  `target_uuid`), which is what makes core route it and count it in digests.
  Alert text never includes an email address or anything a visitor typed.
  """

  use GenServer
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  require Logger

  import Ecto.Query

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Schemas.Event

  @module_key "web_analytics"
  @type_key "web_analytics"

  @visitor_action "web_analytics.visitor_arrived"
  @signup_action "web_analytics.user_registered"
  @event_action "web_analytics.event_alert"

  @visitors_key "web_analytics_alert_visitors"
  @signups_key "web_analytics_alert_signups"
  @channels_key "web_analytics_alert_channels"
  @paths_key "web_analytics_alert_paths"
  @skip_users_key "web_analytics_alert_skip_users"
  @max_per_hour_key "web_analytics_alert_max_per_hour"
  @events_key "web_analytics_alert_events"

  @keys [
    @visitors_key,
    @signups_key,
    @channels_key,
    @paths_key,
    @skip_users_key,
    @max_per_hour_key,
    @events_key
  ]

  @default_max_per_hour 20
  @channels ~w(none organic social referral email paid)
  @recipients_ttl_ms :timer.minutes(5)
  @table :phoenix_kit_web_analytics_alerts

  @type config :: %{
          visitors?: boolean(),
          signups?: boolean(),
          channels: [String.t()],
          paths: [String.t()],
          skip_users?: boolean(),
          max_per_hour: non_neg_integer(),
          events: [String.t()]
        }

  # ── notification type ─────────────────────────────────────────────────────

  @doc """
  The notification type this module registers with core — returned from
  `PhoenixKitWebAnalytics.notification_types/0`.
  """
  @spec notification_types() :: [map()]
  def notification_types do
    [
      %{
        key: @type_key,
        label: gettext("Website activity"),
        description: gettext("Visitors, sign-ups and tracked events on the site"),
        default: true,
        sub_types: [
          %{
            key: "visitors",
            label: gettext("New visitors"),
            description: gettext("Someone started a visit (filters in Web Analytics settings)"),
            actions: [@visitor_action],
            default: true
          },
          %{
            key: "signups",
            label: gettext("New sign-ups"),
            description: gettext("An account was created"),
            actions: [@signup_action],
            default: true
          },
          %{
            key: "events",
            label: gettext("Tracked events"),
            description: gettext("An event listed in Web Analytics settings happened"),
            actions: [@event_action],
            default: true
          }
        ]
      }
    ]
  end

  @doc "The channel values the visitor filter understands."
  @spec channels() :: [String.t()]
  def channels, do: @channels

  @doc "Settings keys owned by the alerts, for the settings form."
  @spec setting_keys() :: %{atom() => String.t()}
  def setting_keys do
    %{
      visitors: @visitors_key,
      signups: @signups_key,
      channels: @channels_key,
      paths: @paths_key,
      skip_users: @skip_users_key,
      max_per_hour: @max_per_hour_key,
      events: @events_key
    }
  end

  @doc "The current alert settings, with defaults."
  @spec config() :: config()
  def config do
    values = Settings.get_settings_cached(@keys, %{})

    %{
      visitors?: values[@visitors_key] in ["true", true],
      signups?: values[@signups_key] not in ["false", false],
      channels: parse_channels(values[@channels_key]),
      paths: parse_list(values[@paths_key]),
      skip_users?: values[@skip_users_key] not in ["false", false],
      max_per_hour: non_negative(values[@max_per_hour_key], @default_max_per_hour),
      events: parse_list(values[@events_key])
    }
  rescue
    error ->
      Logger.debug("[WebAnalytics] alert settings unreadable: #{inspect(error)}")
      default_config()
  catch
    :exit, _ -> default_config()
  end

  # ── entry points ──────────────────────────────────────────────────────────

  @doc """
  Called by the collector after every stored hit, in the collector's own
  (background) process. Decides whether the hit is alert-worthy and sends.
  Never raises.
  """
  @spec event_recorded(Event.t(), boolean()) :: :ok
  def event_recorded(%Event{} = event, new_session?) do
    if Config.enabled?(), do: maybe_alert(event, new_session?, config())
    :ok
  rescue
    error ->
      Logger.warning("[WebAnalytics] alert failed: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[WebAnalytics] alert exited: #{inspect(reason)}")
      :ok
  end

  @doc """
  Whether a visitor's first page view passes the visitor-alert filters.
  Public so the settings page and tests can explain a decision.
  """
  @spec visitor_alert?(Event.t(), config()) :: boolean()
  def visitor_alert?(%Event{} = event, config) do
    config.visitors? and
      (config.skip_users? == false or is_nil(event.user_uuid)) and
      (event.referrer_medium || "none") in config.channels and
      (config.paths == [] or Config.excluded?(event.path, config.paths))
  end

  @doc "Sends the sign-up alert for a newly created user. Never raises."
  @spec user_registered(map()) :: :ok
  def user_registered(%{uuid: uuid} = user) when is_binary(uuid) do
    if Config.enabled?() and config().signups? and first_signup_alert?(uuid) do
      name = display_name(user)

      deliver(@signup_action,
        resource_type: "user",
        resource_uuid: uuid,
        actor_uuid: uuid,
        text: gettext("New sign-up: %{name}", name: name),
        icon: "hero-user-plus",
        link: Routes.path("/admin/users/view/#{uuid}"),
        metadata: %{"user_uuid" => uuid}
      )
    end

    :ok
  rescue
    error ->
      Logger.warning("[WebAnalytics] sign-up alert failed: #{Exception.message(error)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  def user_registered(_user), do: :ok

  @doc """
  Everyone who receives the alerts: Owners plus active holders of the
  `web_analytics` (or `*`) permission. Cached for five minutes.
  """
  @spec recipients() :: [String.t()]
  def recipients do
    now = System.monotonic_time(:millisecond)

    case lookup(:recipients) do
      {uuids, at} when now - at < @recipients_ttl_ms ->
        uuids

      _ ->
        uuids = load_recipients()
        store(:recipients, {uuids, now})
        uuids
    end
  end

  # ── GenServer: owns the counters, listens for new users ───────────────────

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    subscribe_to_users()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:user_created, user}, state) do
    # Off the GenServer: the alert does DB work and must not delay the next
    # message.
    PhoenixKitWebAnalytics.Collector.run_async(fn -> user_registered(user) end)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("[WebAnalytics] Alerts ignored #{inspect(message)}")
    {:noreply, state}
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp maybe_alert(%Event{event_type: "pageview"} = event, true, config) do
    if visitor_alert?(event, config) do
      case take_hourly_slot(config.max_per_hour) do
        {:ok, held_back} -> send_visitor_alert(event, held_back)
        :full -> :ok
      end
    end
  end

  defp maybe_alert(%Event{event_type: type, event_name: name} = event, _new?, config)
       when type in ["event", "interaction"] and is_binary(name) do
    if config.events != [] and Config.excluded?(name, config.events) do
      deliver(@event_action,
        resource_type: "web_analytics_session",
        resource_uuid: event.session_id,
        text: gettext("%{event} on %{path}", event: name, path: event.path),
        icon: "hero-bolt",
        link: Paths.session(event.session_id),
        metadata: %{"event" => name, "path" => event.path}
      )
    end
  end

  defp maybe_alert(_event, _new?, _config), do: :ok

  defp send_visitor_alert(event, held_back) do
    text =
      [
        gettext("New visitor from %{source} on %{path}",
          source: source_label(event),
          path: event.path
        ),
        client_label(event),
        held_back > 0 &&
          ngettext("(+%{count} more not shown)", "(+%{count} more not shown)", held_back)
      ]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join(" · ")

    deliver(@visitor_action,
      resource_type: "web_analytics_session",
      resource_uuid: event.session_id,
      text: text,
      icon: "hero-globe-alt",
      link: Paths.session(event.session_id),
      metadata: %{
        "path" => event.path,
        "channel" => event.referrer_medium,
        "source" => event.referrer_source
      }
    )
  end

  # One activity entry per recipient: core routes an activity to its
  # target_uuid, and digests count entries by target_uuid.
  defp deliver(action, opts) do
    actor = Keyword.get(opts, :actor_uuid)

    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Map.merge(%{
        "notification_text" => Keyword.fetch!(opts, :text),
        "notification_icon" => Keyword.get(opts, :icon, "hero-bell"),
        "notification_link" => Keyword.get(opts, :link)
      })

    recipients()
    |> Enum.reject(&(&1 == actor))
    |> Enum.each(fn recipient ->
      PhoenixKit.Activity.log(@module_key, action,
        mode: "auto",
        actor_uuid: actor,
        target_uuid: recipient,
        resource_type: Keyword.get(opts, :resource_type),
        resource_uuid: Keyword.get(opts, :resource_uuid),
        metadata: metadata
      )
    end)
  end

  # Fixed hourly window. Returns how many alerts were held back since the last
  # one that went out, so that one can say so.
  defp take_hourly_slot(0), do: {:ok, 0}

  defp take_hourly_slot(max) do
    hour = System.os_time(:second) |> div(3600)
    sent = :ets.update_counter(@table, {:sent, hour}, {2, 1}, {{:sent, hour}, 0})

    if sent <= max do
      held = :ets.update_counter(@table, :held_back, {2, 0}, {:held_back, 0})
      :ets.insert(@table, {:held_back, 0})
      {:ok, held}
    else
      :ets.update_counter(@table, :held_back, {2, 1}, {:held_back, 0})
      :full
    end
  rescue
    # No table (the GenServer isn't running): no cap to enforce.
    ArgumentError -> {:ok, 0}
  end

  defp source_label(%Event{referrer_source: source}) when is_binary(source), do: source

  defp source_label(%Event{referrer_medium: medium}) do
    case medium do
      "organic" -> gettext("search")
      "social" -> gettext("social media")
      "email" -> gettext("email")
      "paid" -> gettext("an ad")
      _ -> gettext("a direct visit")
    end
  end

  defp client_label(%Event{} = event) do
    [event.browser, event.os, event.country_code]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
  end

  defp display_name(user) do
    if Code.ensure_loaded?(User) and function_exported?(User, :display_name, 1) and
         is_struct(user, User) do
      User.display_name(user)
    else
      gettext("a new user")
    end
  end

  # PubSub reaches every node of a cluster, so each would alert. The first
  # node to take the lock and find no earlier entry sends it.
  defp first_signup_alert?(user_uuid) do
    repo = PhoenixKit.RepoHelper.repo()

    {:ok, first?} =
      repo.transaction(fn ->
        repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["wa_signup:" <> user_uuid],
          log: false
        )

        not repo.exists?(
          from(a in "phoenix_kit_activities",
            where:
              a.action == ^@signup_action and
                a.resource_uuid == type(^user_uuid, Ecto.UUID)
          )
        )
      end)

    first?
  end

  defp load_recipients do
    repo = PhoenixKit.RepoHelper.repo()

    owners =
      "Owner"
      |> Roles.users_with_role()
      |> Enum.map(& &1.uuid)

    granted =
      Permissions.users_with_permission(@module_key) ++ Permissions.users_with_permission("*")

    candidates = Enum.uniq(owners ++ granted)

    from(u in User,
      where: u.uuid in ^candidates and u.is_active == true,
      select: u.uuid
    )
    |> repo.all()
  rescue
    error ->
      Logger.warning("[WebAnalytics] could not load alert recipients: #{inspect(error)}")
      []
  end

  defp subscribe_to_users do
    if Code.ensure_loaded?(Events) and function_exported?(Events, :subscribe_to_users, 0) do
      Events.subscribe_to_users()
    end
  rescue
    error -> Logger.warning("[WebAnalytics] could not subscribe to new users: #{inspect(error)}")
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp store(key, value) do
    :ets.insert(@table, {key, value})
  rescue
    ArgumentError -> :ok
  end

  defp default_config do
    %{
      visitors?: false,
      signups?: true,
      channels: @channels,
      paths: [],
      skip_users?: true,
      max_per_hour: @default_max_per_hour,
      events: []
    }
  end

  # Unset means every channel; "-" is an explicit empty choice.
  defp parse_channels(nil), do: @channels
  defp parse_channels("-"), do: []
  defp parse_channels(value), do: value |> parse_list() |> Enum.filter(&(&1 in @channels))

  defp parse_list(value) when is_binary(value) do
    value
    |> String.split([",", "\n", "\r", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_list(_value), do: []

  defp non_negative(value, _default) when is_integer(value) and value >= 0, do: value

  defp non_negative(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} when int >= 0 -> int
      _ -> default
    end
  end

  defp non_negative(_value, default), do: default
end
