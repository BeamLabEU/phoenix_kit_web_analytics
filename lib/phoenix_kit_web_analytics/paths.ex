defmodule PhoenixKitWebAnalytics.Paths do
  @moduledoc """
  Centralized path helpers for the Web Analytics module.

  Every link, redirect, and beacon URL goes through
  `PhoenixKit.Utils.Routes.path/1` so the host's PhoenixKit URL prefix and
  locale are applied. Never hardcode these paths — a host that mounts
  PhoenixKit at `/backend` instead of `/admin` would break every one of them.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/web-analytics"
  @collect_base "/phoenix-kit/analytics"

  @doc "Overview dashboard — totals, trend, and the top breakdowns."
  @spec dashboard() :: String.t()
  def dashboard, do: Routes.path(@base)

  @doc "Pages report — every path, ranked."
  @spec pages() :: String.t()
  def pages, do: Routes.path("#{@base}/pages")

  @doc "Acquisition report — referrers, sources, and UTM campaigns."
  @spec sources() :: String.t()
  def sources, do: Routes.path("#{@base}/sources")

  @doc "Technology report — browsers, operating systems, devices, countries."
  @spec technology() :: String.t()
  def technology, do: Routes.path("#{@base}/technology")

  @doc "Custom events report and the live hit feed."
  @spec events() :: String.t()
  def events, do: Routes.path("#{@base}/events")

  @doc "Who is on the site right now."
  @spec live() :: String.t()
  def live, do: Routes.path("#{@base}/live")

  @doc "Sessions — every visit, with where it started and ended."
  @spec sessions() :: String.t()
  def sessions, do: Routes.path("#{@base}/sessions")

  @doc "Sessions filtered to one logged-in user."
  @spec sessions_for_user(String.t()) :: String.t()
  def sessions_for_user(user_uuid), do: with_query(sessions(), %{"user" => user_uuid})

  @doc "One session's timeline — everything the visitor did, in order."
  @spec session(String.t()) :: String.t()
  def session(session_id), do: Routes.path("#{@base}/sessions/#{session_id}")

  @doc "Settings page for the module."
  @spec settings() :: String.t()
  def settings, do: Routes.path("#{@base}/settings")

  @doc """
  A dashboard URL carrying report filters as query parameters.

      iex> is_binary(PhoenixKitWebAnalytics.Paths.dashboard(%{"period" => "7d"}))
      true
  """
  @spec dashboard(map()) :: String.t()
  def dashboard(params) when is_map(params), do: with_query(dashboard(), params)

  @doc "A pages-report URL carrying report filters."
  @spec pages(map()) :: String.t()
  def pages(params) when is_map(params), do: with_query(pages(), params)

  # The collection routes are declared once, without a locale segment, so their
  # URLs must never get one — on a non-default locale a localized URL would 404.

  @doc "The beacon endpoint that accepts custom events (`POST`)."
  @spec beacon_endpoint() :: String.t()
  def beacon_endpoint, do: Routes.path("#{@collect_base}/event", locale: :none)

  @doc """
  The tracking-pixel endpoint (`GET`) for the page at `path`, optionally with
  a cache-busting value.
  """
  @spec pixel_endpoint(String.t() | nil, String.t() | nil) :: String.t()
  def pixel_endpoint(cache_buster \\ nil, path \\ nil) do
    with_query(Routes.path("#{@collect_base}/pixel.gif", locale: :none), %{
      "p" => path,
      "cb" => cache_buster && to_string(cache_buster)
    })
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp with_query(path, params) do
    case params
         |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
         |> URI.encode_query() do
      "" -> path
      query -> "#{path}?#{query}"
    end
  end
end
