defmodule PhoenixKitWebAnalytics.Web.Filters do
  @moduledoc """
  Shared period/site filter handling for the report LiveViews.

  Every report page answers the same two questions — *when* and *which site* —
  and keeps both in the URL so a filtered view can be bookmarked, shared, and
  survives a refresh. A third, optional `path` narrows every report to one page
  (set by clicking a path on the Pages report). This module owns that plumbing so the five pages don't
  each reimplement it.
  """

  import Phoenix.Component, only: [assign: 2]

  alias PhoenixKitWebAnalytics.LivePresence
  alias PhoenixKitWebAnalytics.Reports

  @doc """
  Reads `period`, `site` and `path` from the URL params and assigns `:filter`,
  `:period`, `:site`, `:path`, `:sites`, and `:bucket`.

  Unknown period values fall back to the default rather than erroring — these
  come from a URL anyone can edit.
  """
  @spec assign_filter(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_filter(socket, params) do
    filter =
      Reports.filter(
        period: params["period"],
        site: params["site"],
        path: path_param(params["path"])
      )

    assign(socket,
      filter: filter,
      period: filter.period,
      site: filter.site,
      path: filter.path,
      bucket: Reports.bucket_for(filter.period),
      # Scoped to the selected window, not all time: an all-time GROUP BY site
      # would scan the entire events table on every page load, which is the one
      # query on these pages that has no time bound to keep it cheap.
      sites: Reports.sites(filter),
      online: online(filter.site)
    )
  end

  @doc """
  Builds the URL to patch to when the filter form changes.

  Empty values are dropped, so the default view has a clean URL.
  """
  @spec patch_to(String.t(), map()) :: String.t()
  def patch_to(path, params) do
    query =
      %{
        "period" => params["period"],
        "site" => params["site"],
        "path" => path_param(params["path"])
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> URI.encode_query()

    case query do
      "" -> path
      query -> "#{path}?#{query}"
    end
  end

  @doc """
  The current filter as URL params, for links between report pages that should
  keep the selected window.
  """
  @spec to_params(Reports.filter()) :: map()
  def to_params(filter) do
    %{"period" => filter.period, "site" => filter.site, "path" => filter[:path]}
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  @doc "Applies the current filter's params to another report path."
  @spec link_to(String.t(), Reports.filter()) :: String.t()
  def link_to(path, filter), do: patch_to(path, to_params(filter))

  @online_refresh_ms 30_000

  @doc """
  Assigns `:online` and, once connected, refreshes it every 30 seconds by
  sending the LiveView `:refresh_online` — which it hands back to
  `refresh_online/1`. Every report page shows the same badge this way.
  """
  @spec track_online(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def track_online(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: :timer.send_interval(@online_refresh_ms, self(), :refresh_online)

    assign(socket, online: 0)
  end

  @doc "Re-reads the online count for the page's current site filter."
  @spec refresh_online(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_online(socket), do: assign(socket, online: online(socket.assigns[:site]))

  @doc """
  How many people are on the site now: the larger of the pages open over a
  LiveView socket (exact) and the visitors with a hit in the last five minutes
  (covers pages without a LiveView).
  """
  @spec online(String.t() | nil) :: non_neg_integer()
  def online(site) do
    max(LivePresence.count(site), Reports.active_visitors(5, site))
  end

  # Only an absolute path is a path filter; anything else from the URL is
  # ignored rather than matching nothing.
  defp path_param("/" <> _ = path), do: path
  defp path_param(_path), do: nil
end
