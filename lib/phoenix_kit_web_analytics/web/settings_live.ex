defmodule PhoenixKitWebAnalytics.Web.SettingsLive do
  @moduledoc """
  Settings — what is collected, how long it's kept, which alerts go out, and
  the installation checklist.

  Every value here is a row in the host's `phoenix_kit_settings` table, so
  changes take effect on the next request with no redeploy. Every change goes
  through `PhoenixKitWebAnalytics.Admin`, which logs it to the activity log.
  The page also reports what is actually stored right now, which answers the
  two questions operators ask: "is it recording?" and "how big is this
  getting?".
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  require Logger

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWebAnalytics.Admin
  alias PhoenixKitWebAnalytics.Alerts
  alias PhoenixKitWebAnalytics.BotSignals
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Reports

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Settings"))
     |> assign(:retention_running?, false)
     |> load()}
  end

  @impl true
  def handle_event("save", params, socket) do
    case Admin.save_settings(params, Actor.opts(socket)) do
      {:ok, _changed} ->
        {:noreply, socket |> put_flash(:info, gettext("Settings saved.")) |> load()}

      {:error, :not_saved} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Some settings could not be saved. Check them and try again.")
         )}

      {:error, fields} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Nothing was saved. Check: %{fields}.",
             fields: Enum.map_join(fields, ", ", &field_label/1)
           )
         )}
    end
  end

  def handle_event("toggle_tracking", _params, socket) do
    case Admin.set_tracking(not socket.assigns.enabled?, Actor.opts(socket)) do
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not change tracking. Try again."))}

      _ ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("run_retention", _params, socket) do
    if socket.assigns.retention_running? do
      {:noreply, socket}
    else
      opts = Actor.opts(socket)

      {:noreply,
       socket
       |> assign(:retention_running?, true)
       |> start_async(:retention, fn -> Admin.run_retention(opts) end)}
    end
  end

  def handle_event("rotate_salt", _params, socket) do
    case Admin.rotate_salt(Actor.opts(socket)) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Visitor salt rotated. Visitors seen before now will count again today.")
         )
         |> load()}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("Could not store a new salt. Try again."))}
    end
  end

  @impl true
  def handle_async(:retention, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:retention_running?, false)
     |> put_flash(
       :info,
       gettext("Rolled up %{days} day(s) and pruned %{events} event(s).",
         days: result.rolled_up,
         events: result.pruned
       )
     )
     |> load()}
  end

  def handle_async(:retention, {:exit, reason}, socket) do
    Logger.warning("[WebAnalytics] manual retention pass failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:retention_running?, false)
     |> put_flash(:error, gettext("The retention pass failed. Details are in the server log."))}
  end

  @impl true
  def handle_info(message, socket) do
    Logger.debug("[WebAnalytics] SettingsLive ignored #{inspect(message)}")
    {:noreply, socket}
  end

  defp load(socket) do
    keys = Config.setting_keys()

    socket
    |> assign(:enabled?, PhoenixKitWebAnalytics.enabled?())
    |> assign(:config, Config.collection_config())
    |> assign(:alerts, Alerts.config())
    |> assign(:exclude_paths, Config.exclude_paths_raw())
    |> assign(:ignore_events, raw(keys.ignore_events, Config.default_ignore_events()))
    |> assign(:event_params, raw(keys.event_params, Config.default_event_params()))
    |> assign(:retention_days, Config.retention_days())
    |> assign(:recording_retention_days, Config.recording_retention_days())
    |> assign(:storage, Reports.storage_stats())
    |> assign(:live_skips?, live_skips?())
    |> assign(:notification_settings_path, Routes.path("/admin/notifications/settings"))
  end

  # LiveView visits skipped for want of `:x_headers` — on this node, or (by the
  # cluster's word) on another.
  defp live_skips? do
    BotSignals.skipped_live_visits() > 0 or BotSignals.skipping_live_visits?()
  end

  defp raw(key, default) do
    Settings.get_setting(key, default) || default
  rescue
    _ -> default
  end

  defp field_label(:session_timeout), do: gettext("Visit timeout")
  defp field_label(:retention_days), do: gettext("Retention")
  defp field_label(:recording_sample), do: gettext("Visitors recorded")
  defp field_label(:recording_retention_days), do: gettext("Keep recordings")
  defp field_label(:alert_max_per_hour), do: gettext("Alerts per hour")
  defp field_label(:exclude_paths), do: gettext("Excluded paths")
  defp field_label(:ignore_events), do: gettext("Events not to record")
  defp field_label(:event_params), do: gettext("Event values to keep")
  defp field_label(:alert_paths), do: gettext("Landing pages")
  defp field_label(:alert_events), do: gettext("Alert on these events")
  defp field_label(:alert_channels), do: gettext("Only from these channels")
  defp field_label(field), do: field |> Atom.to_string() |> String.replace("_", " ")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl space-y-6 px-4 py-6">
      <div class="flex items-center justify-between rounded-xl border border-base-300 bg-base-100 p-4">
        <div>
          <p class="font-medium">
            {if @enabled?, do: gettext("Tracking is on"), else: gettext("Tracking is off")}
          </p>
          <p class="text-sm text-base-content/60">
            {if @enabled?,
              do: gettext("Visits are being recorded."),
              else: gettext("Nothing is being recorded.")}
          </p>
        </div>
        <button
          type="button"
          phx-click="toggle_tracking"
          phx-disable-with={gettext("Saving…")}
          data-confirm={
            @enabled? && gettext("Stop recording visits? Reports keep what is already stored.")
          }
          class={["btn btn-sm", if(@enabled?, do: "btn-outline", else: "btn-primary")]}
        >
          {if @enabled?, do: gettext("Turn off"), else: gettext("Turn on")}
        </button>
      </div>

      <div
        :if={@live_skips?}
        id="web-analytics-x-headers-warning"
        role="alert"
        class="alert alert-warning text-sm"
      >
        <span>
          {gettext(
            "Behind a proxy without :x_headers, LiveView visits are not recorded. Add :x_headers to the LiveView socket's connect_info, on both transports — see Installation below."
          )}
        </span>
      </div>

      <form id="web-analytics-settings" phx-submit="save" class="space-y-6">
        <input type="hidden" name="_form" value="settings" />

        <section class="space-y-4 rounded-xl border border-base-300 bg-base-100 p-4">
          <h2 class="text-sm font-semibold">{gettext("Collection")}</h2>

          <.checkbox
            name="respect_dnt"
            checked={@config.respect_dnt?}
            label={gettext("Respect Do Not Track")}
          >
            <:description>
              {gettext("Skip visitors whose browser sends DNT or Global Privacy Control.")}
            </:description>
          </.checkbox>

          <.checkbox
            name="track_bots"
            checked={@config.track_bots?}
            label={gettext("Record bot traffic")}
          >
            <:description>
              {gettext(
                "Off by default — crawlers and monitors would otherwise dominate every report."
              )}
            </:description>
          </.checkbox>

          <.checkbox
            name="detect_bots"
            checked={@config.detect_bots?}
            label={gettext("Spot bots by behaviour")}
          >
            <:description>
              {gettext(
                "Bots are recognised by the name their browser sends. This also catches ones posing as a normal browser: browsers under automation (needs the client script), page views faster than a person reads, and LiveView pages that never connected — a scraper fetching HTML runs no JavaScript."
              )}
            </:description>
          </.checkbox>

          <.textarea
            id="exclude_paths"
            name="exclude_paths"
            label={gettext("Excluded paths")}
            value={@exclude_paths}
            rows="4"
            class="textarea w-full font-mono text-xs"
          />
          <p class="-mt-2 text-xs text-base-content/50">
            {gettext("One pattern per line. A trailing * matches a prefix.")}
          </p>

          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              type="number"
              id="session_timeout"
              name="session_timeout"
              label={gettext("Visit timeout, minutes")}
              value={@config.session_timeout_minutes}
              min="1"
              max="1440"
            />
            <.input
              type="number"
              id="retention_days"
              name="retention_days"
              label={gettext("Keep raw events, days")}
              value={@retention_days}
              min="0"
              max="3650"
            />
          </div>
          <p class="-mt-2 text-xs text-base-content/50">
            {gettext("0 keeps raw events forever. Daily totals are always kept.")}
          </p>
        </section>

        <section class="space-y-4 rounded-xl border border-base-300 bg-base-100 p-4">
          <div>
            <h2 class="text-sm font-semibold">{gettext("What visitors do")}</h2>
            <p class="text-xs text-base-content/50">
              {gettext(
                "LiveView pages report clicks, form submits and exits over their socket — no script needed. The optional client script adds what the server can't see."
              )}
            </p>
          </div>

          <.checkbox
            name="track_interactions"
            checked={@config.track_interactions?}
            label={gettext("Record LiveView interactions")}
          >
            <:description>
              {gettext(
                "Every event a LiveView handles, by name. Form typing is never recorded, nor are form contents."
              )}
            </:description>
          </.checkbox>

          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              id="ignore_events"
              name="ignore_events"
              label={gettext("Events not to record")}
              value={@ignore_events}
            />
            <.input
              id="event_params"
              name="event_params"
              label={gettext("Event values to keep")}
              value={@event_params}
            />
          </div>
          <p class="-mt-2 text-xs text-base-content/50">
            {gettext(
              "Comma-separated. Values of the listed parameter names (short ones only) are kept with an interaction, e.g. which tab was opened."
            )}
          </p>

          <.checkbox
            name="client_script"
            checked={@config.client_script?}
            label={gettext("Accept the client script")}
          >
            <:description>
              {gettext(
                "Outbound links, downloads, plain buttons, scroll depth, and exits from pages without a LiveView. The script ships with the module; this switch decides whether its reports are stored."
              )}
            </:description>
          </.checkbox>

          <.checkbox
            name="beacon"
            checked={@config.beacon_enabled?}
            label={gettext("Accept the beacon and pixel")}
          >
            <:description>
              {gettext(
                "Page views reported from the browser, for pages a CDN serves without reaching the app. The endpoints are public — leave off unless you use them."
              )}
            </:description>
          </.checkbox>
        </section>

        <section class="space-y-4 rounded-xl border border-base-300 bg-base-100 p-4">
          <div>
            <h2 class="text-sm font-semibold">{gettext("Session recordings")}</h2>
            <p class="text-xs text-base-content/50">
              {gettext(
                "Replay a visit: where the pointer went, what was clicked and hovered, how the page scrolled. Recorded by the client script; only coordinates and element positions — never text, typing or form values. Visitors asking not to be tracked, bots and excluded paths are never recorded."
              )}
            </p>
          </div>

          <.checkbox name="recording" checked={@config.recording?} label={gettext("Record visits")}>
            <:description>
              {gettext(
                "Off by default. A recorded page sends a few rows a minute while someone is using it — on a busy site, record a share of visitors."
              )}
            </:description>
          </.checkbox>

          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              type="number"
              id="recording_sample"
              name="recording_sample"
              label={gettext("Visitors recorded, %")}
              value={@config.recording_sample}
              min="1"
              max="100"
            />
            <.input
              type="number"
              id="recording_retention_days"
              name="recording_retention_days"
              label={gettext("Keep recordings, days")}
              value={@recording_retention_days}
              min="1"
              max="3650"
            />
          </div>
        </section>

        <section class="space-y-4 rounded-xl border border-base-300 bg-base-100 p-4">
          <div>
            <h2 class="text-sm font-semibold">{gettext("Alerts")}</h2>
            <p class="text-xs text-base-content/50">
              {gettext(
                "Sent to everyone who can open Web Analytics. Each person chooses in-app, email or Telegram, and an hourly or daily digest instead, in"
              )}
              <.link navigate={@notification_settings_path} class="link">
                {gettext("notification settings")}
              </.link>.
            </p>
          </div>

          <.checkbox name="alert_signups" checked={@alerts.signups?} label={gettext("New sign-ups")}>
            <:description>{gettext("Whenever an account is created.")}</:description>
          </.checkbox>

          <.checkbox name="alert_visitors" checked={@alerts.visitors?} label={gettext("New visitors")}>
            <:description>
              {gettext("When someone starts a visit that matches the filters below.")}
            </:description>
          </.checkbox>

          <div class="space-y-3 border-l-2 border-base-200 pl-4">
            <div>
              <p class="mb-1 text-sm font-medium">{gettext("Only from these channels")}</p>
              <div class="flex flex-wrap gap-x-4 gap-y-2">
                <label
                  :for={channel <- Alerts.channels()}
                  class="flex cursor-pointer items-center gap-2 text-sm"
                >
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm"
                    name="alert_channels[]"
                    value={channel}
                    checked={channel in @alerts.channels}
                  />
                  {channel_label(channel)}
                </label>
              </div>
            </div>

            <.input
              id="alert_paths"
              name="alert_paths"
              label={gettext("Landing pages")}
              value={Enum.join(@alerts.paths, ", ")}
              placeholder="/pricing, /blog*"
            />
            <p class="-mt-2 text-xs text-base-content/50">
              {gettext("Only visits that start on these pages. Blank means any page.")}
            </p>

            <.checkbox
              name="alert_skip_users"
              checked={@alerts.skip_users?}
              label={gettext("Skip signed-in users")}
            />

            <.input
              type="number"
              id="alert_max_per_hour"
              name="alert_max_per_hour"
              label={gettext("Alerts per hour, at most")}
              value={@alerts.max_per_hour}
              min="0"
              max="10000"
            />
            <p class="-mt-2 text-xs text-base-content/50">
              {gettext("Beyond this, the next alert says how many were held back. 0 means no limit.")}
            </p>
          </div>

          <.input
            id="alert_events"
            name="alert_events"
            label={gettext("Alert on these events")}
            value={Enum.join(@alerts.events, ", ")}
            placeholder="order.placed, contact_submit"
          />
          <p class="-mt-2 text-xs text-base-content/50">
            {gettext(
              "Custom event or interaction names, comma-separated. A trailing * matches a prefix."
            )}
          </p>
        </section>

        <div class="flex justify-end">
          <button type="submit" class="btn btn-primary btn-sm" phx-disable-with={gettext("Saving…")}>
            {gettext("Save settings")}
          </button>
        </div>
      </form>

      <section class="rounded-xl border border-base-300 bg-base-100 p-4">
        <h2 class="text-sm font-semibold">{gettext("Stored data")}</h2>
        <div class="mt-3 grid grid-cols-3 gap-4 text-sm">
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/50">
              {gettext("Events")}
            </div>
            <div class="text-lg font-semibold tabular-nums">
              {if @storage.events_estimated?, do: "≈ "}{format_number(@storage.events)}
            </div>
          </div>
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/50">
              {gettext("Rollup rows")}
            </div>
            <div class="text-lg font-semibold tabular-nums">
              {format_number(@storage.rollup_days)}
            </div>
          </div>
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/50">
              {gettext("Oldest event")}
            </div>
            <div class="text-lg font-semibold">
              {if @storage.oldest, do: Calendar.strftime(@storage.oldest, "%Y-%m-%d"), else: "—"}
            </div>
          </div>
        </div>

        <div class="mt-4 flex flex-wrap gap-2">
          <button
            type="button"
            phx-click="run_retention"
            phx-disable-with={gettext("Working…")}
            disabled={@retention_running?}
            class="btn btn-sm btn-outline"
          >
            <span :if={@retention_running?} class="loading loading-spinner loading-xs"></span>
            {gettext("Roll up & prune now")}
          </button>
          <button
            type="button"
            phx-click="rotate_salt"
            phx-disable-with={gettext("Rotating…")}
            data-confirm={
              gettext(
                "Visitors seen before now will be counted again today, and open visits split. Continue?"
              )
            }
            class="btn btn-sm btn-ghost"
          >
            {gettext("Rotate visitor salt")}
          </button>
        </div>
      </section>

      <section class="rounded-xl border border-base-300 bg-base-100 p-4 text-sm">
        <h2 class="text-sm font-semibold">{gettext("Installation")}</h2>
        <ol class="mt-3 list-decimal space-y-3 pl-5 text-base-content/70">
          <li>
            {gettext("Add the plug to your router's browser pipeline, after the session is fetched:")}
            <pre class="mt-1 overflow-x-auto rounded bg-base-200 p-2 text-xs"><code>plug PhoenixKitWebAnalytics.Plug</code></pre>
          </li>
          <li>
            {gettext("For LiveView pages, add the hook to your live_session:")}
            <pre class="mt-1 overflow-x-auto rounded bg-base-200 p-2 text-xs"><code>{"on_mount: [{PhoenixKitWebAnalytics.LiveHook, :track_navigation}]"}</code></pre>
          </li>
          <li>
            {gettext(
              "And let the LiveView socket see the visitor's address and browser — on both transports, websocket and longpoll:"
            )}
            <pre class="mt-1 overflow-x-auto rounded bg-base-200 p-2 text-xs"><code>{"connect_info: [:peer_data, :x_headers, :user_agent, session: @session_options]"}</code></pre>
          </li>
          <li>
            {gettext(
              "Behind a reverse proxy on the same host or network, the visitor's address is read from X-Forwarded-For (a port the proxy appends is dropped). Behind a chain — a CDN in front of a load balancer — put a plug that rewrites remote_ip (such as remote_ip) before the tracking plug."
            )}
          </li>
        </ol>
      </section>
    </div>
    """
  end
end
