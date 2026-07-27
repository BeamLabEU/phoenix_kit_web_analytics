defmodule PhoenixKitWebAnalytics.Web.TechnologyLive do
  @moduledoc """
  Technology — browsers, operating systems, device classes, languages, and
  (when available) countries.

  Everything here is derived from the `User-Agent` and `Accept-Language`
  headers the browser already sends. Nothing is measured in the client, so
  there is no screen-size or hardware data: collecting that would need the
  script tag this module exists to avoid.

  The countries card stays empty until a geo resolver is configured or the app
  sits behind a CDN that sets a country header — see `PhoenixKitWebAnalytics.Geo`.
  """

  use PhoenixKitWeb, :live_view

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Web.Filters

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Technology · Web Analytics")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> Filters.assign_filter(params) |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: Filters.patch_to(Paths.technology(), params))}
  end

  defp load(socket) do
    filter = socket.assigns.filter

    socket
    |> assign(:browsers, Reports.browsers(filter, limit: 15))
    |> assign(:operating_systems, Reports.operating_systems(filter, limit: 15))
    |> assign(:devices, Reports.devices(filter, limit: 5))
    |> assign(:countries, Reports.countries(filter, limit: 25))
    |> assign(:languages, Reports.languages(filter, limit: 15))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">Technology</h1>
          <p class="text-sm text-base-content/60">
            Derived from request headers — nothing is measured in the browser.
          </p>
        </div>
        <.filter_bar period={@period} site={@site} sites={@sites} />
      </div>

      <div class="grid gap-4 lg:grid-cols-2">
        <.breakdown_card title="Browsers" icon="hero-globe-alt" rows={@browsers} />
        <.breakdown_card
          title="Operating systems"
          icon="hero-computer-desktop"
          rows={@operating_systems}
        />
        <.breakdown_card title="Devices" icon="hero-device-phone-mobile" rows={@devices} />
        <.breakdown_card title="Languages" icon="hero-language" rows={@languages} />
        <.breakdown_card
          title="Countries"
          icon="hero-map"
          rows={@countries}
          empty_message="No location data. Configure a geo resolver, or run behind a CDN that sets a country header."
        />
      </div>
    </div>
    """
  end
end
