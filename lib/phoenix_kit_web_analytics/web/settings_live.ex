defmodule PhoenixKitWebAnalytics.Web.SettingsLive do
  @moduledoc """
  Settings — collection rules, retention, and the installation checklist.

  Every value here is a row in the host's `phoenix_kit_settings` table, so
  changes take effect on the next request with no redeploy. The page also
  reports what is actually stored right now, which is the fastest way to answer
  the two questions operators ask: "is it recording?" and "how big is this
  getting?".
  """

  use PhoenixKitWeb, :live_view

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKit.Settings
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Retention

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings · Web Analytics")
     |> load()}
  end

  @impl true
  def handle_event("save", params, socket) do
    keys = Config.setting_keys()

    save_boolean(keys.track_bots, params["track_bots"])
    save_boolean(keys.respect_dnt, params["respect_dnt"])
    save_boolean(keys.beacon, params["beacon"])
    save_string(keys.exclude_paths, params["exclude_paths"])
    save_integer(keys.session_timeout, params["session_timeout"], 1, 1440)
    save_integer(keys.retention_days, params["retention_days"], 0, 3650)

    {:noreply,
     socket
     |> put_flash(:info, "Settings saved.")
     |> load()}
  end

  def handle_event("toggle_tracking", _params, socket) do
    if socket.assigns.enabled? do
      PhoenixKitWebAnalytics.disable_system()
    else
      PhoenixKitWebAnalytics.enable_system()
    end

    {:noreply, load(socket)}
  end

  def handle_event("run_retention", _params, socket) do
    result = Retention.run()

    {:noreply,
     socket
     |> put_flash(
       :info,
       "Rolled up #{result.rolled_up} day(s) and pruned #{result.pruned} event(s)."
     )
     |> load()}
  end

  def handle_event("rotate_salt", _params, socket) do
    Config.generate_salt()

    {:noreply,
     socket
     |> put_flash(
       :info,
       "Visitor salt rotated. Today's visitor counts will restart from zero."
     )
     |> load()}
  end

  defp load(socket) do
    config = Config.collection_config()

    socket
    |> assign(:enabled?, PhoenixKitWebAnalytics.enabled?())
    |> assign(:config, config)
    |> assign(:exclude_paths, Config.exclude_paths_raw())
    |> assign(:retention_days, Config.retention_days())
    |> assign(:storage, Reports.storage_stats())
  end

  # Settings values are strings; an unchecked box submits nothing at all.
  defp save_boolean(key, value) do
    Settings.update_boolean_setting_with_module(
      key,
      value in ["true", "on", true],
      "web_analytics"
    )
  end

  defp save_string(key, value) when is_binary(value),
    do: Settings.update_setting_with_module(key, value, "web_analytics")

  defp save_string(_key, _value), do: :ok

  defp save_integer(key, value, min, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} when int >= min and int <= max ->
        Settings.update_setting_with_module(key, Integer.to_string(int), "web_analytics")

      _ ->
        :ok
    end
  end

  defp save_integer(_key, _value, _min, _max), do: :ok

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl space-y-6 px-4 py-6">
      <div>
        <h1 class="text-2xl font-semibold">Web Analytics settings</h1>
        <p class="text-sm text-base-content/60">
          Collection rules and retention. Changes apply to the next request.
        </p>
      </div>

      <div class="flex items-center justify-between rounded-xl border border-base-300 bg-base-100 p-4">
        <div>
          <p class="font-medium">
            Tracking is {if @enabled?, do: "on", else: "off"}
          </p>
          <p class="text-sm text-base-content/60">
            {if @enabled?,
              do: "Page views are being recorded.",
              else: "Nothing is being recorded."}
          </p>
        </div>
        <button
          type="button"
          phx-click="toggle_tracking"
          class={["btn btn-sm", if(@enabled?, do: "btn-outline", else: "btn-primary")]}
        >
          {if @enabled?, do: "Turn off", else: "Turn on"}
        </button>
      </div>

      <form phx-submit="save" class="space-y-6 rounded-xl border border-base-300 bg-base-100 p-4">
        <div class="space-y-3">
          <h2 class="text-sm font-semibold">Collection</h2>

          <.checkbox
            name="respect_dnt"
            checked={@config.respect_dnt?}
            label="Respect Do Not Track"
          >
            <:description>
              Skip requests sending <code>DNT: 1</code> or <code>Sec-GPC: 1</code>.
            </:description>
          </.checkbox>

          <.checkbox name="track_bots" checked={@config.track_bots?} label="Record bot traffic">
            <:description>
              Off by default — crawlers and monitors would otherwise dominate every report.
            </:description>
          </.checkbox>

          <.checkbox
            name="beacon"
            checked={@config.beacon_enabled?}
            label="Accept hits from the browser beacon"
          >
            <:description>
              Enables the public <code>/phoenix-kit/analytics</code>
              endpoints, needed only for client-side custom events or cached pages.
              These are unauthenticated — leave off unless you use them.
            </:description>
          </.checkbox>
        </div>

        <div>
          <label for="exclude_paths" class="text-sm font-medium">Excluded paths</label>
          <p class="mb-1 text-xs text-base-content/50">
            One pattern per line. A trailing <code>*</code> matches a prefix.
          </p>
          <textarea
            id="exclude_paths"
            name="exclude_paths"
            rows="4"
            class="textarea w-full font-mono text-xs"
          >{@exclude_paths}</textarea>
        </div>

        <div class="grid gap-4 sm:grid-cols-2">
          <div>
            <label for="session_timeout" class="text-sm font-medium">Session timeout</label>
            <p class="mb-1 text-xs text-base-content/50">
              Minutes of inactivity that end a session.
            </p>
            <input
              id="session_timeout"
              type="number"
              name="session_timeout"
              min="1"
              max="1440"
              value={@config.session_timeout_minutes}
              class="input input-sm w-full"
            />
          </div>

          <div>
            <label for="retention_days" class="text-sm font-medium">Retention</label>
            <p class="mb-1 text-xs text-base-content/50">
              Days of raw events to keep. 0 keeps everything.
            </p>
            <input
              id="retention_days"
              type="number"
              name="retention_days"
              min="0"
              max="3650"
              value={@retention_days}
              class="input input-sm w-full"
            />
          </div>
        </div>

        <div class="flex justify-end">
          <button type="submit" class="btn btn-primary btn-sm">Save settings</button>
        </div>
      </form>

      <div class="rounded-xl border border-base-300 bg-base-100 p-4">
        <h2 class="text-sm font-semibold">Stored data</h2>
        <div class="mt-3 grid grid-cols-3 gap-4 text-sm">
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/50">Events</div>
            <div class="text-lg font-semibold tabular-nums">{format_number(@storage.events)}</div>
          </div>
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/50">Rollup rows</div>
            <div class="text-lg font-semibold tabular-nums">
              {format_number(@storage.rollup_days)}
            </div>
          </div>
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/50">Oldest event</div>
            <div class="text-lg font-semibold">
              {if @storage.oldest, do: Calendar.strftime(@storage.oldest, "%Y-%m-%d"), else: "—"}
            </div>
          </div>
        </div>

        <div class="mt-4 flex flex-wrap gap-2">
          <button type="button" phx-click="run_retention" class="btn btn-sm btn-outline">
            Roll up &amp; prune now
          </button>
          <button
            type="button"
            phx-click="rotate_salt"
            data-confirm="Rotating the salt restarts today's visitor counts from zero. Continue?"
            class="btn btn-sm btn-ghost"
          >
            Rotate visitor salt
          </button>
        </div>
      </div>

      <div class="rounded-xl border border-base-300 bg-base-100 p-4 text-sm">
        <h2 class="text-sm font-semibold">Installation</h2>
        <ol class="mt-3 list-decimal space-y-3 pl-5 text-base-content/70">
          <li>
            Add the plug to your router's <code>:browser</code>
            pipeline — this is the whole tracker: <pre class="mt-1 overflow-x-auto rounded bg-base-200 p-2 text-xs"><code>plug PhoenixKitWebAnalytics.Plug</code></pre>
          </li>
          <li>
            For LiveView navigation, add the hook to your <code>live_session</code>: <pre class="mt-1 overflow-x-auto rounded bg-base-200 p-2 text-xs"><code>{"on_mount: [{PhoenixKitWebAnalytics.LiveHook, :track_navigation}]"}</code></pre>
          </li>
          <li>
            Behind a proxy or CDN, put a plug that rewrites <code>remote_ip</code>
            (such as <code>remote_ip</code>) before the tracking plug — otherwise every visitor
            hashes to the same address.
          </li>
        </ol>
      </div>
    </div>
    """
  end
end
