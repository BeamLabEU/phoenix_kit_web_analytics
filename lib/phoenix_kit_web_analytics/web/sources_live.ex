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
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  require Logger

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Web.Filters

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> Filters.track_online() |> assign(:page_title, gettext("Acquisition"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> Filters.assign_filter(params) |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: Filters.patch_to(Paths.sources(), params))}
  end

  @impl true
  def handle_info(:refresh_online, socket), do: {:noreply, Filters.refresh_online(socket)}

  def handle_info(message, socket) do
    Logger.debug("[WebAnalytics] SourcesLive ignored #{inspect(message)}")
    {:noreply, socket}
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
      <.top_row
        period={@period}
        site={@site}
        sites={@sites}
        path={@path}
        base_path={Paths.sources()}
        online={@online}
        live_path={Paths.live()}
      />

      <div class="grid gap-4 lg:grid-cols-2">
        <.breakdown_card
          id="card-channels"
          title={gettext("Channels")}
          icon="hero-share"
          rows={@channels}
          labels={:channel}
          label_header={gettext("Channel")}
          empty_message={gettext("No traffic recorded in this period.")}
        >
          <:info>
            <p>{gettext("Where visitors came from, grouped by kind:")}</p>
            <ul class="list-disc space-y-1 pl-4">
              <li>{gettext("Search — Google, Bing, DuckDuckGo, ChatGPT…")}</li>
              <li>{gettext("Social — Facebook, Instagram, X, LinkedIn, Hacker News…")}</li>
              <li>{gettext("Email — webmail and newsletter links")}</li>
              <li>{gettext("Paid — campaign links marked as ads (utm_medium=cpc)")}</li>
              <li>{gettext("Referral — any other website")}</li>
              <li>{gettext("Direct — no link to tell: typed in, a bookmark, an app")}</li>
            </ul>
            <.columns_explained />
          </:info>
        </.breakdown_card>
        <.breakdown_card
          id="card-referrers"
          title={gettext("Referring sites")}
          icon="hero-arrow-trending-up"
          rows={@referrers}
          label_header={gettext("Came from")}
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
          id="card-campaigns"
          title={gettext("Campaigns")}
          icon="hero-megaphone"
          rows={@campaigns}
          label_header={gettext("Campaign")}
          empty_message={gettext("No utm_campaign parameters seen in this period.")}
        >
          <:info>
            <p>
              {gettext(
                "Visits that arrived through a link tagged with utm_campaign — for example ?utm_campaign=autumn-sale in a newsletter or an ad."
              )}
            </p>
            <p>
              {gettext(
                "Only the utm_ parameters are kept from a link's address; the rest of it is never stored."
              )}
            </p>
            <.columns_explained />
          </:info>
        </.breakdown_card>
        <.breakdown_card
          id="card-utm-sources"
          title={gettext("Campaign sources")}
          icon="hero-link"
          rows={@utm_sources}
          label_header={gettext("Source")}
          empty_message={gettext("No utm_source parameters seen in this period.")}
          info_align="end"
        >
          <:info>
            <p>
              {gettext(
                "The utm_source of tagged links — who sent the visitor, in the words of whoever made the link: newsletter, facebook, partner-site."
              )}
            </p>
            <.columns_explained />
          </:info>
        </.breakdown_card>
      </div>
    </div>
    """
  end
end
