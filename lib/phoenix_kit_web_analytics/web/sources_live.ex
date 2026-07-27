defmodule PhoenixKitWebAnalytics.Web.SourcesLive do
  @moduledoc """
  Acquisition — where traffic came from: channels, referring sites, and UTM
  campaigns.

  "Direct" here means no `Referer` header and no campaign parameters. That
  bucket is always larger than it looks like it should be: HTTPS-to-HTTP
  navigation, most mobile apps, and any client with a strict referrer policy
  all arrive with nothing attached.
  """

  use PhoenixKitWeb, :live_view

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Web.Filters

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Acquisition · Web Analytics")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> Filters.assign_filter(params) |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: Filters.patch_to(Paths.sources(), params))}
  end

  defp load(socket) do
    filter = socket.assigns.filter

    socket
    |> assign(:channels, Reports.channels(filter, limit: 10))
    |> assign(:referrers, Reports.top_referrers(filter, limit: 25))
    |> assign(:campaigns, Reports.top_campaigns(filter, limit: 25))
    |> assign(:utm_sources, Reports.top_utm_sources(filter, limit: 25))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">Acquisition</h1>
          <p class="text-sm text-base-content/60">Referrers, channels, and campaigns.</p>
        </div>
        <.filter_bar period={@period} site={@site} sites={@sites} />
      </div>

      <div class="grid gap-4 lg:grid-cols-2">
        <.breakdown_card
          title="Channels"
          icon="hero-share"
          rows={@channels}
          empty_message="No traffic recorded in this period."
        />
        <.breakdown_card
          title="Referring sites"
          icon="hero-arrow-trending-up"
          rows={@referrers}
          empty_message="All traffic in this period was direct."
        />
        <.breakdown_card
          title="Campaigns"
          icon="hero-megaphone"
          rows={@campaigns}
          empty_message="No utm_campaign parameters seen in this period."
        />
        <.breakdown_card
          title="Campaign sources"
          icon="hero-link"
          rows={@utm_sources}
          empty_message="No utm_source parameters seen in this period."
        />
      </div>

      <p class="text-xs text-base-content/50">
        Campaign parameters (<code>utm_source</code>, <code>utm_medium</code>, <code>utm_campaign</code>, <code>utm_term</code>, <code>utm_content</code>)
        are read from the query string and stored in their own columns. The rest of the
        query string is never stored.
      </p>
    </div>
    """
  end
end
