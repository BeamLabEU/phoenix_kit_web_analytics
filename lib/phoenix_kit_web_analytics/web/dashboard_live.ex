defmodule PhoenixKitWebAnalytics.Web.DashboardLive do
  @moduledoc """
  Overview — the page you land on: headline numbers with period-over-period
  change, the traffic trend, and the four breakdowns worth seeing first.

  Refreshes the "visitors right now" badge every 30 seconds. Nothing else
  polls: the rest of the page is a point-in-time report and re-running six
  aggregate queries on a timer would cost the database far more than it tells
  the operator.
  """

  use PhoenixKitWeb, :live_view

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Web.Filters

  @refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh_live)

    {:ok,
     socket
     |> assign(:page_title, "Web Analytics")
     |> assign(:active_visitors, 0)
     |> assign(:tracking_enabled?, PhoenixKitWebAnalytics.enabled?())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> Filters.assign_filter(params) |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: Filters.patch_to(Paths.dashboard(), params))}
  end

  @impl true
  def handle_info(:refresh_live, socket) do
    {:noreply, assign(socket, :active_visitors, Reports.active_visitors(5, socket.assigns.site))}
  end

  defp load(socket) do
    filter = socket.assigns.filter
    overview = Reports.overview(filter)

    socket
    |> assign(:overview, overview)
    |> assign(:previous, Reports.previous_overview(filter))
    |> assign(:series, Reports.timeseries(filter, socket.assigns.bucket))
    |> assign(:top_paths, Reports.top_paths(filter, limit: 8))
    |> assign(:top_referrers, Reports.top_referrers(filter, limit: 8))
    |> assign(:channels, Reports.channels(filter, limit: 6))
    |> assign(:devices, Reports.devices(filter, limit: 4))
    |> assign(:active_visitors, Reports.active_visitors(5, filter.site))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">Web Analytics</h1>
          <p class="text-sm text-base-content/60">
            Cookieless, server-side traffic for {Reports.period_label(@period) |> String.downcase()}.
          </p>
        </div>
        <.filter_bar
          period={@period}
          site={@site}
          sites={@sites}
          active_visitors={@active_visitors}
        />
      </div>

      <.disabled_notice :if={not @tracking_enabled?} settings_path={Paths.settings()} />

      <div class="grid grid-cols-2 gap-4 lg:grid-cols-3 xl:grid-cols-6">
        <.stat_tile
          label="Visitors"
          value={format_number(@overview.visitors)}
          delta={delta(@overview.visitors, @previous && @previous.visitors)}
        />
        <.stat_tile
          label="Page views"
          value={format_number(@overview.pageviews)}
          delta={delta(@overview.pageviews, @previous && @previous.pageviews)}
        />
        <.stat_tile
          label="Sessions"
          value={format_number(@overview.sessions)}
          delta={delta(@overview.sessions, @previous && @previous.sessions)}
        />
        <.stat_tile
          label="Bounce rate"
          value={format_percent(@overview.bounce_rate)}
          hint="Sessions with one page view"
          delta={delta(@overview.bounce_rate, @previous && @previous.bounce_rate)}
          delta_good={:down}
        />
        <.stat_tile
          label="Avg. session"
          value={format_duration(@overview.avg_session_seconds)}
          hint="Last hit minus first"
        />
        <.stat_tile
          label="Avg. response"
          value={format_ms(@overview.avg_response_ms)}
          hint="Server render time"
          delta_good={:down}
        />
      </div>

      <div class="rounded-xl border border-base-300 bg-base-100 p-4">
        <div class="mb-3 flex items-center justify-between">
          <h2 class="text-sm font-semibold">Page views</h2>
          <span class="text-xs text-base-content/50">{bucket_label(@bucket)}</span>
        </div>
        <.traffic_chart series={@series} metric={:pageviews} bucket={@bucket} />
      </div>

      <div class="grid gap-4 lg:grid-cols-2">
        <.breakdown_card
          title="Top pages"
          icon="hero-document-text"
          rows={@top_paths}
          link={Filters.link_to(Paths.pages(), @filter)}
          empty_message="No page views recorded in this period."
        />
        <.breakdown_card
          title="Top referrers"
          icon="hero-arrow-trending-up"
          rows={@top_referrers}
          link={Filters.link_to(Paths.sources(), @filter)}
          empty_message="All traffic in this period was direct."
        />
        <.breakdown_card
          title="Channels"
          icon="hero-share"
          rows={@channels}
          link={Filters.link_to(Paths.sources(), @filter)}
        />
        <.breakdown_card
          title="Devices"
          icon="hero-device-phone-mobile"
          rows={@devices}
          link={Filters.link_to(Paths.technology(), @filter)}
        />
      </div>
    </div>
    """
  end

  defp bucket_label(:hour), do: "hourly"
  defp bucket_label(:month), do: "monthly"
  defp bucket_label(_bucket), do: "daily"
end
