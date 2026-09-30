defmodule PhoenixKitWebAnalytics.Web.EventsLive do
  @moduledoc """
  What visitors do — interactions (LiveView events, and the client script's
  clicks), custom events, and the live hit feed.

  The feed polls every 10 seconds while the page is open — it's the one view
  where "what's happening right now" is the point, and one indexed
  `ORDER BY inserted_at DESC LIMIT 50` is cheap enough to repeat. Every row
  links to its session, the whole visit in order.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  require Logger

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Web.Filters

  @refresh_ms 10_000
  @feed_types ~w(all pageview interaction leave event)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok,
     socket
     |> Filters.track_online()
     |> assign(:page_title, gettext("Events"))
     |> assign(:refresh_seconds, div(@refresh_ms, 1000))
     |> assign(:feed_type, "all")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> Filters.assign_filter(params) |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: Filters.patch_to(Paths.events(), params))}
  end

  def handle_event("feed_type", %{"feed_type" => type}, socket) when type in @feed_types do
    {:noreply, socket |> assign(:feed_type, type) |> load_feed()}
  end

  def handle_event("feed_type", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load_feed(socket)}
  def handle_info(:refresh_online, socket), do: {:noreply, Filters.refresh_online(socket)}

  def handle_info(message, socket) do
    Logger.debug("[WebAnalytics] EventsLive ignored #{inspect(message)}")
    {:noreply, socket}
  end

  defp load(socket) do
    filter = socket.assigns.filter

    socket
    |> assign(:events, Reports.top_events(filter, limit: 25))
    |> assign(:interactions, Reports.top_interactions(filter, limit: 25))
    |> assign(:overview, Reports.overview(filter))
    |> load_feed()
  end

  defp load_feed(socket) do
    # The window is re-read on every refresh, so "today" keeps up past
    # midnight instead of freezing at the filter built on load.
    filter =
      Reports.filter(
        period: socket.assigns.period,
        site: socket.assigns.site,
        path: socket.assigns.path
      )

    opts =
      case socket.assigns.feed_type do
        "all" -> [limit: 50]
        type -> [limit: 50, event_type: type]
      end

    assign(socket, :feed, Reports.recent_hits(filter, opts))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <.top_row
        period={@period}
        site={@site}
        sites={@sites}
        path={@path}
        base_path={Paths.events()}
        online={@online}
        live_path={Paths.live()}
      />

      <div class="grid gap-4 lg:grid-cols-2">
        <.breakdown_card
          id="card-interactions"
          title={gettext("What visitors do")}
          icon="hero-cursor-arrow-rays"
          rows={label_interactions(@interactions)}
          label_header={gettext("Action")}
          metric_header={gettext("Times")}
          empty_message={gettext("No clicks or form submits recorded in this period.")}
        >
          <:info>
            <p>
              {gettext(
                "Buttons clicked and forms sent on LiveView pages, by the name the page gives them — plus outbound links and downloads when the optional client script is on."
              )}
            </p>
            <p>
              {gettext(
                "Visitors: how many different people did it. Times: how often it was done in total."
              )}
            </p>
          </:info>
        </.breakdown_card>
        <.breakdown_card
          id="card-custom-events"
          title={gettext("Custom events")}
          icon="hero-bolt"
          rows={@events}
          label_header={gettext("Event")}
          metric_header={gettext("Times")}
          empty_message={gettext("No custom events recorded in this period.")}
          info_align="end"
        >
          <:info>
            <p>
              {gettext(
                "Events the site reports itself, with a name of its choosing — an order placed, a sign-up finished. They come from PhoenixKitWebAnalytics.track_event/2 in the app, or phoenixKitAnalytics(name, props) in the browser."
              )}
            </p>
            <p>
              {gettext(
                "Visitors: how many different people did it. Times: how often it was done in total."
              )}
            </p>
          </:info>
        </.breakdown_card>
      </div>

      <.report_card id="live-feed" title={gettext("Live feed")} icon="hero-signal">
        <:info>
          <p>
            {gettext("Every hit as it arrives, newest first — updated every %{seconds} seconds.",
              seconds: @refresh_seconds
            )}
          </p>
          <p>
            {gettext(
              "Page views, actions, exits (with how long the page was open) and custom events. The last column opens the whole visit."
            )}
          </p>
        </:info>
        <:actions>
          <form id="web-analytics-feed-type" phx-change="feed_type">
            <.select
              name="feed_type"
              value={@feed_type}
              options={[
                {gettext("All hits"), "all"},
                {gettext("Page views"), "pageview"},
                {gettext("Interactions"), "interaction"},
                {gettext("Exits"), "leave"},
                {gettext("Custom events"), "event"}
              ]}
              class="select-xs w-auto"
              aria-label={gettext("Hit type")}
            />
          </form>
        </:actions>
        <.empty_state
          :if={@feed == []}
          title={gettext("Nothing recorded in this period yet.")}
          icon="hero-signal"
          class="py-10"
        />

        <.table_default :if={@feed != []} size="xs" wrapper_class="overflow-x-auto">
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell>{gettext("Time")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("What")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Page")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Source")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Client")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Visit")}</.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>
          <.table_default_body>
            <.table_default_row :for={hit <- @feed}>
              <.table_default_cell class="whitespace-nowrap text-base-content/60">
                {Calendar.strftime(hit.inserted_at, "%H:%M:%S")}
              </.table_default_cell>
              <.table_default_cell class="max-w-xs truncate">
                <.hit_summary hit={hit} />
              </.table_default_cell>
              <.table_default_cell class="max-w-[14rem] truncate font-mono text-xs">
                {hit.path}
              </.table_default_cell>
              <.table_default_cell class="max-w-[10rem] truncate text-base-content/60">
                {if hit.event_type == "pageview",
                  do: hit.referrer_source || channel_label(hit.referrer_medium)}
              </.table_default_cell>
              <.table_default_cell class="whitespace-nowrap text-base-content/60">
                {Enum.join(Enum.reject([hit.browser, hit.os], &is_nil/1), " · ")}
              </.table_default_cell>
              <.table_default_cell>
                <.link
                  navigate={Paths.session(hit.session_id)}
                  class="font-mono text-[11px] text-primary hover:underline"
                  title={gettext("Open this visit")}
                >
                  {String.slice(to_string(hit.session_id), -8, 8)}
                </.link>
              </.table_default_cell>
            </.table_default_row>
          </.table_default_body>
        </.table_default>
      </.report_card>
    </div>
    """
  end
end
