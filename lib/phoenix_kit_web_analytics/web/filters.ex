defmodule PhoenixKitWebAnalytics.Web.Filters do
  @moduledoc """
  Shared period/site filter handling for the report LiveViews.

  Every report page answers the same two questions — *when* and *which site* —
  and keeps both in the URL so a filtered view can be bookmarked, shared, and
  survives a refresh. This module owns that plumbing so the five pages don't
  each reimplement it.
  """

  import Phoenix.Component, only: [assign: 2]

  alias PhoenixKitWebAnalytics.Reports

  @doc """
  Reads `period` and `site` from the URL params and assigns `:filter`,
  `:period`, `:site`, `:sites`, and `:bucket`.

  Unknown period values fall back to the default rather than erroring — these
  come from a URL anyone can edit.
  """
  @spec assign_filter(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_filter(socket, params) do
    filter =
      Reports.filter(
        period: params["period"],
        site: params["site"]
      )

    assign(socket,
      filter: filter,
      period: filter.period,
      site: filter.site,
      bucket: Reports.bucket_for(filter.period),
      # Scoped to the selected window, not all time: an all-time GROUP BY site
      # would scan the entire events table on every page load, which is the one
      # query on these pages that has no time bound to keep it cheap.
      sites: Reports.sites(filter)
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
        "site" => params["site"]
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
    %{"period" => filter.period, "site" => filter.site}
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  @doc "Applies the current filter's params to another report path."
  @spec link_to(String.t(), Reports.filter()) :: String.t()
  def link_to(path, filter), do: patch_to(path, to_params(filter))
end
