defmodule PhoenixKitWebAnalytics.Web.EventsLive do
  @moduledoc """
  Custom events and the live hit feed.

  The feed polls every 10 seconds while the page is open — it's the one view
  where "what's happening right now" is the point, and one indexed
  `ORDER BY inserted_at DESC LIMIT 50` is cheap enough to repeat. Everything
  displayed is already non-identifying, so there is nothing to redact: the
  visitor column shows the first characters of the daily hash purely so you can
  see two hits belonging to one person.
  """

  use PhoenixKitWeb, :live_view

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Web.Filters

  @refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Events · Web Analytics")
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

  def handle_event("feed_type", %{"feed_type" => type}, socket) do
    {:noreply, socket |> assign(:feed_type, type) |> load_feed()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load_feed(socket)}

  defp load(socket) do
    filter = socket.assigns.filter

    socket
    |> assign(:events, Reports.top_events(filter, limit: 25))
    |> assign(:overview, Reports.overview(filter))
    |> load_feed()
  end

  defp load_feed(socket) do
    opts =
      case socket.assigns.feed_type do
        "pageview" -> [limit: 50, event_type: "pageview"]
        "event" -> [limit: 50, event_type: "event"]
        _ -> [limit: 50]
      end

    assign(socket, :feed, Reports.recent_hits(socket.assigns.filter, opts))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">Events</h1>
          <p class="text-sm text-base-content/60">
            {format_number(@overview.events)} custom events in this period.
          </p>
        </div>
        <.filter_bar period={@period} site={@site} sites={@sites} />
      </div>

      <div class="grid gap-4 lg:grid-cols-3">
        <div class="lg:col-span-1">
          <.breakdown_card
            title="Custom events"
            icon="hero-bolt"
            rows={@events}
            metric_header="Count"
            empty_message="No custom events recorded. Send them with PhoenixKitWebAnalytics.track_event/2 or the beacon snippet."
          />
        </div>

        <div class="rounded-xl border border-base-300 bg-base-100 lg:col-span-2">
          <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 px-4 py-3">
            <div>
              <h2 class="text-sm font-semibold">Live feed</h2>
              <p class="text-xs text-base-content/50">
                Most recent hits, refreshed every 10 seconds.
              </p>
            </div>
            <form phx-change="feed_type">
              <select name="feed_type" class="select select-xs" aria-label="Hit type">
                <option value="all" selected={@feed_type == "all"}>All hits</option>
                <option value="pageview" selected={@feed_type == "pageview"}>Page views</option>
                <option value="event" selected={@feed_type == "event"}>Custom events</option>
              </select>
            </form>
          </div>

          <p :if={@feed == []} class="px-4 py-10 text-center text-sm text-base-content/50">
            Nothing recorded in this period yet.
          </p>

          <div :if={@feed != []} class="overflow-x-auto">
            <table class="table table-xs">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>What</th>
                  <th>Source</th>
                  <th>Client</th>
                  <th>Visitor</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={hit <- @feed} class="hover">
                  <td class="whitespace-nowrap text-base-content/60">
                    {Calendar.strftime(hit.inserted_at, "%H:%M:%S")}
                  </td>
                  <td class="max-w-xs truncate">
                    <span :if={hit.event_type == "event"} class="badge badge-xs badge-primary mr-1">
                      {hit.event_name}
                    </span>
                    <span class="font-mono text-xs" title={hit.path}>{hit.path}</span>
                  </td>
                  <td class="max-w-[10rem] truncate text-base-content/60">
                    {hit.referrer_source || channel_label(hit.referrer_medium)}
                  </td>
                  <td class="whitespace-nowrap text-base-content/60">
                    {hit.browser} · {hit.os}
                  </td>
                  <td
                    class="font-mono text-[11px] text-base-content/40"
                    title="Daily rotating hash — not an identifier"
                  >
                    {String.slice(hit.visitor_id || "", 0, 8)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp channel_label("none"), do: "Direct"
  defp channel_label(nil), do: "Direct"
  defp channel_label(medium), do: String.capitalize(medium)
end
