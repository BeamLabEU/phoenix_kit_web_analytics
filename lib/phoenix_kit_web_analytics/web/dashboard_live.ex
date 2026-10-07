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

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Filters.track_online()
     |> assign(:page_title, gettext("Web Analytics"))
     |> assign(:session_timeout, PhoenixKitWebAnalytics.Config.session_timeout_minutes())
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
    {:noreply, Filters.refresh_online(socket)}
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
  end

  # Day buckets read through the rollups, so a trend reaching past the
  # retention horizon still shows the pruned days.
  defp series(filter, :day) do
    filter
    |> Reports.daily_timeseries()
    |> Enum.map(
      &%{bucket: DateTime.new!(&1.date, ~T[00:00:00], "Etc/UTC"), pageviews: &1.pageviews}
    )
  end

  defp series(filter, bucket), do: Reports.timeseries(filter, bucket)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <.top_row
        period={@period}
        site={@site}
        sites={@sites}
        path={@path}
        base_path={Paths.dashboard()}
        online={@online}
        live_path={Paths.live()}
      />

      <.disabled_notice :if={not @tracking_enabled?} settings_path={Paths.settings()} />

      <div class="grid grid-cols-2 gap-4 lg:grid-cols-3 xl:grid-cols-6">
        <.stat_tile
          id="stat-visitors"
          label={gettext("Visitors")}
          value={format_number(@overview.visitors)}
          delta={delta(@overview.visitors, @previous && @previous.visitors)}
        >
          <:info>
            <p>{gettext("Different people who opened at least one page.")}</p>
            <p>
              {gettext(
                "A person is recognised by their device and browser, for one day at a time and without cookies — so someone who comes back on another day is counted again."
              )}
            </p>
          </:info>
        </.stat_tile>
        <.stat_tile
          id="stat-pageviews"
          label={gettext("Page views")}
          value={format_number(@overview.pageviews)}
          delta={delta(@overview.pageviews, @previous && @previous.pageviews)}
          info_align="end"
        >
          <:info>
            <p>{gettext("How many times a page was opened, by all visitors together.")}</p>
            <p>
              {gettext(
                "Opening a page, moving to another page of the site, and reloading each count once."
              )}
            </p>
          </:info>
        </.stat_tile>
        <.stat_tile
          id="stat-visits"
          label={gettext("Visits")}
          value={format_number(@overview.sessions)}
          delta={delta(@overview.sessions, @previous && @previous.sessions)}
        >
          <:info>
            <p>
              {gettext(
                "One visit is everything a person does on the site in one go — from the first page they open until they leave."
              )}
            </p>
            <p>
              {gettext(
                "If they are away for more than %{minutes} minutes and come back, that starts a new visit, so one person can make several visits a day. Signing in has nothing to do with it.",
                minutes: @session_timeout
              )}
            </p>
          </:info>
        </.stat_tile>
        <.stat_tile
          id="stat-bounce"
          label={gettext("Bounce rate")}
          value={format_percent(@overview.bounce_rate)}
          delta={delta(@overview.bounce_rate, @previous && @previous.bounce_rate)}
          delta_good={:down}
          info_align="end"
        >
          <:info>
            <p>{gettext("The share of visits that saw only one page and left.")}</p>
            <p>
              {gettext(
                "High is normal for a blog post or a contact page people came for; high on a home page or a shop means people aren't going any further. Lower is usually better."
              )}
            </p>
          </:info>
        </.stat_tile>
        <.stat_tile
          id="stat-visit-length"
          label={gettext("Avg. visit")}
          value={format_duration(@overview.avg_session_seconds)}
        >
          <:info>
            <p>{gettext("How long a visit lasts on average.")}</p>
            <p>
              {gettext(
                "Measured from the moment the first page opens until the visitor leaves the last one. For a visit to a single page, that's how long the page was open."
              )}
            </p>
          </:info>
        </.stat_tile>
        <.stat_tile
          id="stat-time-on-page"
          label={gettext("Time on page")}
          value={format_duration(@engagement.avg_time_ms && @engagement.avg_time_ms / 1000)}
          info_align="end"
        >
          <:info>
            <p>
              {gettext(
                "How long a page stays open on average, before the visitor moves on or leaves."
              )}
            </p>
            <p>
              {gettext(
                "It is measured when a page is left, so it covers LiveView pages (and every page once the optional client script is on)."
              )}
            </p>
          </:info>
        </.stat_tile>
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
          id="card-top-pages"
          title={gettext("Top pages")}
          icon="hero-document-text"
          rows={@top_paths}
          label_header={gettext("Page")}
          link={Filters.link_to(Paths.pages(), @filter)}
          empty_message={gettext("No page views recorded in this period.")}
        >
          <:info>
            <p>{gettext("The pages opened most often.")}</p>
            <.columns_explained />
          </:info>
        </.breakdown_card>
        <.breakdown_card
          id="card-referrers"
          title={gettext("Top referrers")}
          icon="hero-arrow-trending-up"
          rows={@top_referrers}
          label_header={gettext("Came from")}
          link={Filters.link_to(Paths.sources(), @filter)}
          empty_message={gettext("All traffic in this period was direct.")}
          info_align="end"
        >
          <:info>
            <p>
              {gettext(
                "The site a visitor came from. When someone clicks a link to your site, their browser tells us the page the link was on; a campaign link's utm_source says it too."
              )}
            </p>
            <p>
              {gettext(
                "Visits with neither — typed in, a bookmark, or an app that hides it — are Direct, and aren't listed here."
              )}
            </p>
            <.columns_explained />
          </:info>
        </.breakdown_card>
        <.breakdown_card
          id="card-channels"
          title={gettext("Channels")}
          icon="hero-share"
          rows={@channels}
          labels={:channel}
          label_header={gettext("Channel")}
          link={Filters.link_to(Paths.sources(), @filter)}
        >
          <:info>
            <p>{gettext("Where visitors came from, grouped by kind:")}</p>
            <ul class="list-disc space-y-1 pl-4">
              <li>{gettext("Search — Google, Bing, DuckDuckGo, ChatGPT…")}</li>
              <li>{gettext("Social — Facebook, Instagram, X, LinkedIn, Hacker News…")}</li>
              <li>{gettext("Email — webmail and newsletter links")}</li>
              <li>
                {gettext("Paid — ad clicks, auto-tagged (gclid, msclkid…) or marked utm_medium=cpc")}
              </li>
              <li>{gettext("Referral — any other website")}</li>
              <li>{gettext("Direct — no link to tell: typed in, a bookmark, an app")}</li>
            </ul>
            <.columns_explained />
          </:info>
        </.breakdown_card>
        <.breakdown_card
          id="card-devices"
          title={gettext("Devices")}
          icon="hero-device-phone-mobile"
          rows={@devices}
          labels={:device}
          label_header={gettext("Device")}
          link={Filters.link_to(Paths.technology(), @filter)}
          info_align="end"
        >
          <:info>
            <p>
              {gettext(
                "Desktop, mobile or tablet — read from the browser's description of itself, which it sends with every page."
              )}
            </p>
            <.columns_explained />
          </:info>
        </.breakdown_card>
        <.breakdown_card
          id="card-interactions"
          title={gettext("What visitors do")}
          icon="hero-cursor-arrow-rays"
          rows={label_interactions(@interactions)}
          label_header={gettext("Action")}
          metric_header={gettext("Times")}
          link={Filters.link_to(Paths.events(), @filter)}
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
          id="card-exit-pages"
          title={gettext("Exit pages")}
          icon="hero-arrow-right-start-on-rectangle"
          rows={@exit_pages}
          label_header={gettext("Page")}
          metric_header={gettext("Exits")}
          link={Filters.link_to(Paths.sessions(), @filter)}
          link_label={gettext("Visits")}
          empty_message={gettext("No exits recorded in this period.")}
          info_align="end"
        >
          <:info>
            <p>{gettext("The pages visits ended on — where people left the site.")}</p>
            <p>
              {gettext(
                "Visitors: how many different people left from it. Exits: how many visits ended there."
              )}
            </p>
          </:info>
        </.breakdown_card>
      </div>
    </div>
    """
  end

  defp bucket_label(:hour), do: gettext("hourly")
  defp bucket_label(:month), do: gettext("monthly")
  defp bucket_label(_bucket), do: gettext("daily")
end
