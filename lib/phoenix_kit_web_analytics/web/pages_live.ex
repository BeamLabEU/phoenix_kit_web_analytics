defmodule PhoenixKitWebAnalytics.Web.PagesLive do
  @moduledoc """
  Pages report — every path that received traffic, plus the response-time table
  that comes free with server-side tracking.

  Clicking a path filters the whole report down to it, which is the quickest
  way to ask "where does traffic to this page come from" without leaving the
  admin.
  """

  use PhoenixKitWeb, :live_view

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Web.Filters

  @page_limit 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Pages · Web Analytics")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> Filters.assign_filter(params) |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: Filters.patch_to(Paths.pages(), params))}
  end

  defp load(socket) do
    filter = socket.assigns.filter

    socket
    |> assign(:paths, Reports.top_paths(filter, limit: @page_limit))
    |> assign(:slowest, Reports.slowest_paths(filter, limit: 10))
    |> assign(:overview, Reports.overview(filter))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">Pages</h1>
          <p class="text-sm text-base-content/60">
            {format_number(@overview.pageviews)} page views across {format_number(length(@paths))} paths.
          </p>
        </div>
        <.filter_bar period={@period} site={@site} sites={@sites} />
      </div>

      <div class="rounded-xl border border-base-300 bg-base-100 overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Path</th>
              <th class="text-right">Visitors</th>
              <th class="text-right">Views</th>
              <th class="text-right">Share</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@paths == []}>
              <td colspan="4" class="py-8 text-center text-sm text-base-content/50">
                No page views recorded in this period.
              </td>
            </tr>
            <tr :for={row <- @paths} class="hover">
              <td class="max-w-md truncate font-mono text-xs" title={row.label}>{row.label}</td>
              <td class="text-right tabular-nums">{format_number(row.visitors)}</td>
              <td class="text-right tabular-nums font-medium">{format_number(row.pageviews)}</td>
              <td class="text-right tabular-nums text-base-content/50">
                {format_percent(share(row.pageviews, @overview.pageviews))}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={length(@paths) >= @page_limit} class="text-xs text-base-content/50">
        Showing the top {@page_limit} paths by page views.
      </p>

      <div class="rounded-xl border border-base-300 bg-base-100">
        <div class="border-b border-base-300 px-4 py-3">
          <h2 class="text-sm font-semibold">Slowest pages</h2>
          <p class="mt-1 text-xs text-base-content/50">
            Average server response time, for paths with at least 3 views in this period.
          </p>
        </div>

        <p :if={@slowest == []} class="px-4 py-8 text-center text-sm text-base-content/50">
          Not enough traffic yet to rank response times.
        </p>

        <table :if={@slowest != []} class="table table-sm">
          <thead>
            <tr>
              <th>Path</th>
              <th class="text-right">Views</th>
              <th class="text-right">Average</th>
              <th class="text-right">Slowest</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @slowest} class="hover">
              <td class="max-w-md truncate font-mono text-xs" title={row.label}>{row.label}</td>
              <td class="text-right tabular-nums">{format_number(row.pageviews)}</td>
              <td class="text-right tabular-nums font-medium">{format_ms(row.avg_ms)}</td>
              <td class="text-right tabular-nums text-base-content/50">{format_ms(row.max_ms)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp share(_part, total) when total in [0, nil], do: nil
  defp share(part, total), do: part * 100 / total
end
