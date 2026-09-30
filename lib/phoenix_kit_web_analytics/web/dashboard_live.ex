defmodule PhoenixKitWebAnalytics.Web.DashboardLive do
  @moduledoc """
  Overview — the page you land on: headline numbers with period-over-period
  change, the traffic trend, and the breakdowns worth seeing first.

  Refreshes the "online" badge every 30 seconds. Nothing else polls: the rest
  of the page is a point-in-time report and re-running its aggregate queries on
  a timer would cost the database far more than it tells the operator.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  require Logger

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Web.Filters

  @refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh_online)

    {:ok,
     socket
     |> assign(:page_title, gettext("Web Analytics"))
     |> assign(:online, 0)
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
  def handle_info(:refresh_online, socket) do
    {:noreply, assign(socket, :online, Filters.online(socket.assigns.site))}
  end

  def handle_info(message, socket) do
    Logger.debug("[WebAnalytics] DashboardLive ignored #{inspect(message)}")
    {:noreply, socket}
  end

  defp load(socket) do
    filter = socket.assigns.filter

    socket
    |> assign(:overview, Reports.overview(filter))
    |> assign(:previous, Reports.previous_overview(filter))
    |> assign(:engagement, Reports.engagement(filter))
    |> assign(:series, series(filter, socket.assigns.bucket))
    |> assign(:top_paths, Reports.top_paths(filter, limit: 8))
    |> assign(:top_referrers, Reports.top_referrers(filter, limit: 8))
    |> assign(:channels, Reports.channels(filter, limit: 6))
    |> assign(:devices, Reports.devices(filter, limit: 4))
    |> assign(:interactions, Reports.top_interactions(filter, limit: 8))
    |> assign(:exit_pages, Reports.exit_pages(filter, limit: 8))
    |> assign(:online, Filters.online(filter.site))
  end

  # Day buckets read through the rollups, so a trend reaching past the
  # retention horizon still shows the pruned days.
  defp series(filter, :day) do
    filter
    |> Reports.daily_timeseries()
    |> Enum.map(&%{bucket: DateTime.new!(&1.date, ~T[00:00:00], "Etc/UTC"), pageviews: &1.pageviews})
  end

  defp series(filter, bucket), do: Reports.timeseries(filter, bucket)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <p class="text-sm text-base-content/60">
          {gettext("Traffic for: %{period}", period: period_label(@period))}
        </p>
        <.filter_bar
          period={@period}
          site={@site}
          sites={@sites}
          path={@path}
          base_path={Paths.dashboard()}
          active_visitors={@online}
          live_path={Paths.live()}
        />
      </div>

      <.disabled_notice :if={not @tracking_enabled?} settings_path={Paths.settings()} />

      <div class="grid grid-cols-2 gap-4 lg:grid-cols-3 xl:grid-cols-6">
        <.stat_tile
          label={gettext("Visitors")}
          value={format_number(@overview.visitors)}
          delta={delta(@overview.visitors, @previous && @previous.visitors)}
        />
        <.stat_tile
          label={gettext("Page views")}
          value={format_number(@overview.pageviews)}
          delta={delta(@overview.pageviews, @previous && @previous.pageviews)}
        />
        <.stat_tile
          label={gettext("Sessions")}
          value={format_number(@overview.sessions)}
          delta={delta(@overview.sessions, @previous && @previous.sessions)}
        />
        <.stat_tile
          label={gettext("Bounce rate")}
          value={format_percent(@overview.bounce_rate)}
          hint={gettext("Sessions with one page view")}
          delta={delta(@overview.bounce_rate, @previous && @previous.bounce_rate)}
          delta_good={:down}
        />
        <.stat_tile
          label={gettext("Avg. session")}
          value={format_duration(@overview.avg_session_seconds)}
          hint={gettext("First hit to last, exits included")}
        />
        <.stat_tile
          label={gettext("Time on page")}
          value={format_duration(@engagement.avg_time_ms && @engagement.avg_time_ms / 1000)}
          hint={gettext("Average, from page exits")}
        />
      </div>

      <div class="rounded-xl border border-base-300 bg-base-100 p-4">
        <div class="mb-3 flex items-center justify-between">
          <h2 class="text-sm font-semibold">{gettext("Page views")}</h2>
          <span class="text-xs text-base-content/50">{bucket_label(@bucket)}</span>
        </div>
        <.traffic_chart series={@series} metric={:pageviews} bucket={@bucket} />
      </div>

      <div class="grid gap-4 lg:grid-cols-2">
        <.breakdown_card
          title={gettext("Top pages")}
          icon="hero-document-text"
          rows={@top_paths}
          link={Filters.link_to(Paths.pages(), @filter)}
          empty_message={gettext("No page views recorded in this period.")}
        />
        <.breakdown_card
          title={gettext("Top referrers")}
          icon="hero-arrow-trending-up"
          rows={@top_referrers}
          link={Filters.link_to(Paths.sources(), @filter)}
          empty_message={gettext("All traffic in this period was direct.")}
        />
        <.breakdown_card
          title={gettext("Channels")}
          icon="hero-share"
          rows={@channels}
          labels={:channel}
          link={Filters.link_to(Paths.sources(), @filter)}
        />
        <.breakdown_card
          title={gettext("Devices")}
          icon="hero-device-phone-mobile"
          rows={@devices}
          labels={:device}
          link={Filters.link_to(Paths.technology(), @filter)}
        />
        <.breakdown_card
          title={gettext("What visitors do")}
          icon="hero-cursor-arrow-rays"
          rows={@interactions}
          metric_header={gettext("Times")}
          link={Filters.link_to(Paths.events(), @filter)}
          empty_message={gettext("No clicks or form submits recorded in this period.")}
        />
        <.breakdown_card
          title={gettext("Exit pages")}
          icon="hero-arrow-right-start-on-rectangle"
          rows={@exit_pages}
          metric_header={gettext("Exits")}
          link={Filters.link_to(Paths.sessions(), @filter)}
          link_label={gettext("Sessions")}
          empty_message={gettext("No exits recorded in this period.")}
        />
      </div>
    </div>
    """
  end

  defp bucket_label(:hour), do: gettext("hourly")
  defp bucket_label(:month), do: gettext("monthly")
  defp bucket_label(_bucket), do: gettext("daily")
end
