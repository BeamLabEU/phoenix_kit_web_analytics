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
    |> assign(:online, PhoenixKitWebAnalytics.Web.Filters.online(nil))
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
      <.top_row online={@online} />

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
        <.report_card
          id="open-pages"
          title={gettext("Open pages")}
          icon="hero-eye"
          class="lg:col-span-2"
        >
          <:info>
            <p>
              {gettext(
                "Every page someone has open this moment, and for how long. Updated every few seconds; a page disappears the moment its tab is closed."
              )}
            </p>
            <p>
              {gettext(
                "Covers LiveView pages, which keep a live connection. Pages without one show up under Recent visits instead."
              )}
            </p>
          </:info>
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
        </.report_card>

        <.breakdown_card
          id="card-open-by-page"
          label_header={gettext("Page")}
          info_align="end"
          title={gettext("Pages open now")}
          icon="hero-document-text"
          rows={Enum.map(@open_by_path, fn {path, count} -> %{label: path, pageviews: count} end)}
          metric_header={gettext("Open")}
          show_visitors={false}
          empty_message={gettext("No open pages.")}
        >
          <:info>
            <p>
              {gettext(
                "The same open pages, counted per page — what the site is being used for right now."
              )}
            </p>
          </:info>
        </.breakdown_card>
      </div>

      <.report_card id="recent-visits-card" title={gettext("Recent visits")} icon="hero-clock">
        <:info>
          <p>
            {gettext(
              "Visits with any activity in the last %{minutes} minutes, newest first — including pages without a live connection. Open one to see what that visitor did.",
              minutes: @recent_minutes
            )}
          </p>
        </:info>
        <.sessions_table sessions={@recent} names={@names} now={@now} id="recent-visits" />
      </.report_card>
    </div>
    """
  end
end
