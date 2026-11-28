defmodule PhoenixKitWebAnalytics.Web.TechnologyLive do
  @moduledoc """
  Technology — browsers, operating systems, device classes, languages, and
  (when available) countries.

  Everything here is derived from the `User-Agent` and `Accept-Language`
  headers the browser already sends. Nothing is measured in the client, so
  there is no screen-size or hardware data: collecting that would need the
  script tag this module exists to avoid.

  With the Bots switch on, a Bots card names the bots that say who they are
  (`PhoenixKitWebAnalytics.UserAgent.bot_name/1`).

  The countries card stays empty until a geo resolver is configured or the app
  sits behind a CDN that sets a country header — see `PhoenixKitWebAnalytics.Geo`.
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
    {:ok, socket |> Filters.track_online() |> assign(:page_title, gettext("Technology"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> Filters.assign_filter(params) |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: Filters.patch_to(Paths.technology(), params))}
  end

  @impl true
  def handle_info(:refresh_online, socket), do: {:noreply, Filters.refresh_online(socket)}

  def handle_info(message, socket) do
    Logger.debug("[WebAnalytics] TechnologyLive ignored #{inspect(message)}")
    {:noreply, socket}
  end

  defp load(socket) do
    filter = socket.assigns.filter

    socket
    |> assign(:browsers, Reports.browsers(filter, limit: 15))
    |> assign(:operating_systems, Reports.operating_systems(filter, limit: 15))
    |> assign(:devices, Reports.devices(filter, limit: 5))
    |> assign(:countries, Reports.countries(filter, limit: 25))
    |> assign(:languages, Reports.languages(filter, limit: 15))
    |> assign(:bot_names, bot_names(filter))
  end

  # Which bots, by the name they give, when the Bots switch counts them in.
  defp bot_names(%{bots: true} = filter) do
    filter
    |> Reports.automated()
    |> Map.fetch!(:bots)
    |> Enum.take(15)
    |> Enum.map(&%{label: &1.bot_name, pageviews: &1.pageviews, visitors: &1.visitors})
  end

  defp bot_names(_filter), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <.top_row
        period={@period}
        site={@site}
        sites={@sites}
        path={@path}
        flagged={@filter.flagged}
        bots={@filter.bots}
        raw={Filters.raw?(@filter)}
        base_path={Paths.technology()}
        online={@online}
        live_path={Paths.live()}
      />

      <div class="grid gap-4 lg:grid-cols-2">
        <.breakdown_card
          id="card-browsers"
          title={gettext("Browsers")}
          labels={:client}
          icon="hero-globe-alt"
          rows={@browsers}
          label_header={gettext("Browser")}
        >
          <:info>
            <p>
              {gettext(
                "Read from the browser's description of itself, which it sends with every page. Nothing is measured on the visitor's device."
              )}
            </p>
            <.columns_explained />
          </:info>
        </.breakdown_card>
        <.breakdown_card
          id="card-systems"
          title={gettext("Operating systems")}
          labels={:client}
          icon="hero-computer-desktop"
          rows={@operating_systems}
          label_header={gettext("System")}
          info_align="end"
        >
          <:info>
            <p>
              {gettext("Windows, macOS, iOS, Android… — from the same description the browser sends.")}
            </p>
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
          id="card-languages"
          title={gettext("Languages")}
          icon="hero-language"
          rows={@languages}
          label_header={gettext("Language")}
          info_align="end"
        >
          <:info>
            <p>
              {gettext(
                "The language the visitor's browser asks for first (et-EE is Estonian as used in Estonia) — usually the language of their device."
              )}
            </p>
            <.columns_explained />
          </:info>
        </.breakdown_card>
        <.breakdown_card
          :if={@filter.bots}
          id="card-bots"
          title={gettext("Bots")}
          icon="hero-bug-ant"
          rows={@bot_names}
          label_header={gettext("Bot")}
          empty_message={
            gettext(
              "No bot named itself in this period. Bots are stored only while “Record bot traffic” is on in Settings."
            )
          }
        >
          <:info>
            <p>
              {gettext(
                "The name a bot gives in its User-Agent (Googlebot, GPTBot…). The User-Agent itself is never stored, only this name."
              )}
            </p>
            <.columns_explained />
          </:info>
        </.breakdown_card>
        <.breakdown_card
          id="card-countries"
          title={gettext("Countries")}
          icon="hero-map"
          rows={@countries}
          label_header={gettext("Country")}
          empty_message={
            gettext(
              "No location data. Configure a geo resolver, or run behind a CDN that sets a country header."
            )
          }
        >
          <:info>
            <p>
              {gettext(
                "Only filled when the site runs behind a CDN that says the visitor's country (Cloudflare does), or when a location lookup is configured. No IP address is ever stored."
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
