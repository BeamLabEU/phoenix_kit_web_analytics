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
     |> Filters.track_online()
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
  def handle_info(:refresh_online, socket), do: {:noreply, Filters.refresh_online(socket)}

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
      <.top_row
        period={@period}
        site={@site}
        sites={@sites}
        path={@path}
        base_path={Paths.pages()}
        online={@online}
        live_path={Paths.live()}
      />

      <.report_card id="all-pages" title={gettext("All pages")} icon="hero-document-text">
        <:info>
          <p>{gettext("Every page that was opened in this period, most viewed first.")}</p>
          <.columns_explained />
          <p>
            {gettext(
              "Share: this page's part of all page views. Time on page: how long it stayed open on average. Exits: how many visits ended on it."
            )}
          </p>
          <p>{gettext("Click a page to see the overview for that page alone.")}</p>
        </:info>
        <.empty_state
          :if={@paths == []}
          title={gettext("No page views recorded in this period.")}
          icon="hero-document-text"
          class="py-10"
        />
        <.table_default :if={@paths != []} size="sm" wrapper_class="overflow-x-auto">
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell>{gettext("Page")}</.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Visitors")}
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Views")}
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Share")}
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Time on page")}
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right">
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
              <.table_default_cell class="text-right tabular-nums text-base-content/60">
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
        <p :if={length(@paths) >= @page_limit} class="px-4 py-3 text-xs text-base-content/50">
          {gettext("Showing the top %{count} paths by page views.", count: @page_limit)}
        </p>
      </.report_card>

      <.report_card id="slowest-pages" title={gettext("Slowest pages")} icon="hero-clock">
        <:info>
          <p>
            {gettext(
              "How long the server took to build each page, on average — the time before the visitor's browser gets anything."
            )}
          </p>
          <p>
            {gettext(
              "Only pages opened at least %{count} times in this period, so one slow first load doesn't top the list.",
              count: @slow_min_views
            )}
          </p>
        </:info>
        <.empty_state
          :if={@slowest == []}
          title={gettext("Not enough traffic yet to rank response times.")}
          class="py-8"
        />

        <.table_default :if={@slowest != []} size="sm" wrapper_class="overflow-x-auto">
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell>{gettext("Page")}</.table_default_header_cell>
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
      </.report_card>
    </div>
    """
  end

  defp share(_part, total) when total in [0, nil], do: nil
  defp share(part, total), do: part * 100 / total
end
