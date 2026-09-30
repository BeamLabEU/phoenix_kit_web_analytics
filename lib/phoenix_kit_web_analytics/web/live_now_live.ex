defmodule PhoenixKitWebAnalytics.Web.LiveNowLive do
  @moduledoc """
  Right now — who is on the site this moment, and what they're looking at.

  Two sources, because they see different things:

    * **Open pages** — every LiveView page connected right now, from
      `PhoenixKitWebAnalytics.LivePresence`. Exact: a page appears when it
      connects and disappears the moment the tab closes. Signed-in visitors
      are named.
    * **Recent visits** — sessions with any activity in the last five minutes,
      which also covers pages without a LiveView (the plug and client script
      see those, but nothing holds them open).

  Refreshes every five seconds.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  require Logger

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.LivePresence
  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Web.UserNames

  @refresh_ms 5_000
  @recent_minutes 5

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, gettext("Right now"))
     |> assign(:recent_minutes, @recent_minutes)
     |> assign(:presence?, LivePresence.running?())
     |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  def handle_info(message, socket) do
    Logger.debug("[WebAnalytics] LiveNowLive ignored #{inspect(message)}")
    {:noreply, socket}
  end

  defp load(socket) do
    now = DateTime.utc_now()
    open = LivePresence.list()

    recent =
      Reports.sessions(
        %{
          from: DateTime.add(now, -@recent_minutes * 60, :second),
          to: DateTime.add(now, 60, :second),
          site: nil,
          path: nil,
          period: "custom",
          bots: false
        },
        limit: 50
      )

    names =
      UserNames.for_uuids(Enum.map(open, & &1.user_uuid) ++ Enum.map(recent, & &1.user_uuid))

    socket
    |> assign(:now, now)
    |> assign(:open, open)
    |> assign(:recent, recent)
    |> assign(:names, names)
    |> assign(
      :open_by_path,
      open |> Enum.frequencies_by(& &1.path) |> Enum.sort_by(&elem(&1, 1), :desc)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <p class="flex items-center gap-2 text-sm text-base-content/60">
          <.status_dot
            variant={if @open != [], do: :success, else: :neutral}
            pulse={@open != []}
            size={:sm}
          />
          {ngettext("%{count} page open right now", "%{count} pages open right now", length(@open))}
        </p>
        <span class="text-xs text-base-content/50">{gettext("Updates every few seconds.")}</span>
      </div>

      <div
        :if={not @presence?}
        role="alert"
        class="alert alert-warning text-sm"
      >
        <.icon name="hero-exclamation-triangle" class="h-5 w-5" />
        <span>
          {gettext(
            "Live presence isn't running on this node, so open pages can't be listed. It starts with the module's children."
          )}
        </span>
      </div>

      <div class="grid gap-4 lg:grid-cols-3">
        <div class="min-w-0 rounded-xl border border-base-300 bg-base-100 lg:col-span-2">
          <div class="border-b border-base-300 px-4 py-3">
            <h2 class="text-sm font-semibold">{gettext("Open pages")}</h2>
            <p class="text-xs text-base-content/50">
              {gettext("Every LiveView page connected at this moment.")}
            </p>
          </div>
          <.empty_state
            :if={@open == []}
            title={gettext("Nobody has a page open right now.")}
            icon="hero-user"
            class="py-10"
          />
          <.table_default :if={@open != []} size="sm" wrapper_class="overflow-x-auto">
            <.table_default_header>
              <.table_default_row>
                <.table_default_header_cell>{gettext("Page")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("For")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Visitor")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Client")}</.table_default_header_cell>
              </.table_default_row>
            </.table_default_header>
            <.table_default_body>
              <.table_default_row :for={visit <- @open}>
                <.table_default_cell class="max-w-xs truncate font-mono text-xs">
                  {visit.path}
                </.table_default_cell>
                <.table_default_cell class="whitespace-nowrap tabular-nums">
                  {format_duration(DateTime.diff(@now, visit.since))}
                </.table_default_cell>
                <.table_default_cell>
                  <.link
                    :if={visit.user_uuid}
                    navigate={Paths.sessions_for_user(visit.user_uuid)}
                    class="text-primary hover:underline"
                  >
                    {Map.get(@names, visit.user_uuid, gettext("Signed-in user"))}
                  </.link>
                  <span :if={is_nil(visit.user_uuid)} class="text-base-content/50">
                    {gettext("Anonymous")}
                  </span>
                </.table_default_cell>
                <.table_default_cell class="whitespace-nowrap text-base-content/60">
                  {Enum.join(
                    Enum.reject(
                      [visit.browser, visit.os, device_label(visit.device_type)],
                      &is_nil/1
                    ),
                    " · "
                  )}
                </.table_default_cell>
              </.table_default_row>
            </.table_default_body>
          </.table_default>
        </div>

        <.breakdown_card
          title={gettext("Pages open now")}
          icon="hero-document-text"
          rows={Enum.map(@open_by_path, fn {path, count} -> %{label: path, pageviews: count} end)}
          metric_header={gettext("Open")}
          show_visitors={false}
          empty_message={gettext("No open pages.")}
        />
      </div>

      <div class="rounded-xl border border-base-300 bg-base-100">
        <div class="border-b border-base-300 px-4 py-3">
          <h2 class="text-sm font-semibold">{gettext("Recent visits")}</h2>
          <p class="text-xs text-base-content/50">
            {gettext(
              "Visits with activity in the last %{minutes} minutes, including pages without a LiveView.",
              minutes: @recent_minutes
            )}
          </p>
        </div>
        <.sessions_table sessions={@recent} names={@names} now={@now} id="recent-visits" />
      </div>
    </div>
    """
  end
end
