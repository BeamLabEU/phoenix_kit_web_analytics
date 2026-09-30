defmodule PhoenixKitWebAnalytics.Web.PagesLive do
  @moduledoc """
  Pages report — every path that received traffic, with how long visitors
  stayed on it and how often they left the site from it, plus the
  response-time table that comes free with server-side tracking.

  Clicking a path opens the Overview filtered to that page — where its
  visitors came from, what they did, where they went next.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  require Logger

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Web.Filters

  @page_limit 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Pages"))
     |> assign(:page_limit, @page_limit)
     |> assign(:slow_min_views, Reports.slow_min_views())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> Filters.assign_filter(params) |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: Filters.patch_to(Paths.pages(), params))}
  end

  @impl true
  def handle_info(message, socket) do
    Logger.debug("[WebAnalytics] PagesLive ignored #{inspect(message)}")
    {:noreply, socket}
  end

  defp load(socket) do
    filter = socket.assigns.filter
    paths = Reports.top_paths(filter, limit: @page_limit)

    socket
    |> assign(:paths, paths)
    |> assign(:engagement, Reports.page_engagement(filter, Enum.map(paths, & &1.label)))
    |> assign(:slowest, Reports.slowest_paths(filter, limit: 10))
    |> assign(:overview, Reports.overview(filter))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <p class="text-sm text-base-content/60">
          {gettext("%{views} page views across %{paths} paths.",
            views: format_number(@overview.pageviews),
            paths: format_number(length(@paths))
          )}
        </p>
        <.filter_bar
          period={@period}
          site={@site}
          sites={@sites}
          path={@path}
          base_path={Paths.pages()}
        />
      </div>

      <div class="rounded-xl border border-base-300 bg-base-100">
        <.empty_state
          :if={@paths == []}
          title={gettext("No page views recorded in this period.")}
          icon="hero-document-text"
          class="py-10"
        />
        <.table_default :if={@paths != []} size="sm" wrapper_class="overflow-x-auto">
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell>{gettext("Path")}</.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Visitors")}
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Views")}
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Share")}
              </.table_default_header_cell>
              <.table_default_header_cell
                class="text-right"
                title={gettext("Average time on the page, from exits")}
              >
                {gettext("Time on page")}
              </.table_default_header_cell>
              <.table_default_header_cell
                class="text-right"
                title={gettext("Visits that ended on this page")}
              >
                {gettext("Exits")}
              </.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>
          <.table_default_body>
            <.table_default_row :for={row <- @paths}>
              <% engagement = Map.get(@engagement, row.label, %{}) %>
              <.table_default_cell class="max-w-md truncate font-mono text-xs">
                <.link
                  navigate={
                    Filters.patch_to(Paths.dashboard(), %{
                      "period" => @period,
                      "site" => @site,
                      "path" => row.label
                    })
                  }
                  class="hover:underline"
                  title={gettext("Show this page's traffic")}
                >
                  {row.label}
                </.link>
              </.table_default_cell>
              <.table_default_cell class="text-right tabular-nums">
                {format_number(row.visitors)}
              </.table_default_cell>
              <.table_default_cell class="text-right tabular-nums font-medium">
                {format_number(row.pageviews)}
              </.table_default_cell>
              <.table_default_cell class="text-right tabular-nums text-base-content/50">
                {format_percent(share(row.pageviews, @overview.pageviews))}
              </.table_default_cell>
              <.table_default_cell class="text-right tabular-nums">
                {format_duration(engagement[:avg_time_ms] && engagement[:avg_time_ms] / 1000)}
              </.table_default_cell>
              <.table_default_cell class="text-right tabular-nums text-base-content/70">
                {format_number(engagement[:exits] || 0)}
              </.table_default_cell>
            </.table_default_row>
          </.table_default_body>
        </.table_default>
      </div>

      <p :if={length(@paths) >= @page_limit} class="text-xs text-base-content/50">
        {gettext("Showing the top %{count} paths by page views.", count: @page_limit)}
      </p>

      <div class="rounded-xl border border-base-300 bg-base-100">
        <div class="border-b border-base-300 px-4 py-3">
          <h2 class="text-sm font-semibold">{gettext("Slowest pages")}</h2>
          <p class="mt-1 text-xs text-base-content/50">
            {gettext(
              "Average server response time, for paths with at least %{count} views in this period.",
              count: @slow_min_views
            )}
          </p>
        </div>

        <.empty_state
          :if={@slowest == []}
          title={gettext("Not enough traffic yet to rank response times.")}
          class="py-8"
        />

        <.table_default :if={@slowest != []} size="sm" wrapper_class="overflow-x-auto">
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell>{gettext("Path")}</.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Views")}
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Average")}
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Slowest")}
              </.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>
          <.table_default_body>
            <.table_default_row :for={row <- @slowest}>
              <.table_default_cell class="max-w-md truncate font-mono text-xs">
                {row.label}
              </.table_default_cell>
              <.table_default_cell class="text-right tabular-nums">
                {format_number(row.pageviews)}
              </.table_default_cell>
              <.table_default_cell class="text-right tabular-nums font-medium">
                {format_ms(row.avg_ms)}
              </.table_default_cell>
              <.table_default_cell class="text-right tabular-nums text-base-content/50">
                {format_ms(row.max_ms)}
              </.table_default_cell>
            </.table_default_row>
          </.table_default_body>
        </.table_default>
      </div>
    </div>
    """
  end

  defp share(_part, total) when total in [0, nil], do: nil
  defp share(part, total), do: part * 100 / total
end
