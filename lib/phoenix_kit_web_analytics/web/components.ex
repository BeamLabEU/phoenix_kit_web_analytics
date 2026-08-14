defmodule PhoenixKitWebAnalytics.Web.Components do
  @moduledoc """
  The shared building blocks of the six report pages: the filter bar, stat
  tiles, the trend chart, and the ranked breakdown card.

  ## The charts are CSS, not JavaScript

  A module whose whole premise is "no client-side weight on your pages" would
  be a strange place to pull in a charting library for its own admin. Every
  visual here is `div`s with a percentage height or width — themed by daisyUI
  variables, responsive without a resize listener, and readable in both light
  and dark themes with no configuration. Values are exposed through `title`
  attributes, so hovering still tells you the exact number.
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKitWebAnalytics.Reports

  @doc """
  Period + site selector shared by every report page.

  Emits `phx-change="filter"` with `period` and `site` params.
  """
  attr :period, :string, required: true
  attr :site, :string, default: nil
  attr :sites, :list, default: []
  attr :active_visitors, :integer, default: nil

  def filter_bar(assigns) do
    ~H"""
    <form phx-change="filter" class="flex flex-wrap items-center gap-3">
      <select name="period" class="select select-sm" aria-label="Period">
        <option :for={{value, label} <- Reports.periods()} value={value} selected={value == @period}>
          {label}
        </option>
      </select>

      <select
        :if={@sites != []}
        name="site"
        class="select select-sm"
        aria-label="Site"
      >
        <option value="" selected={is_nil(@site)}>All sites</option>
        <option :for={site <- @sites} value={site} selected={site == @site}>{site}</option>
      </select>

      <span
        :if={is_integer(@active_visitors)}
        class="badge badge-success badge-outline gap-1"
        title="Distinct visitors in the last 5 minutes"
      >
        <span class="inline-block w-2 h-2 rounded-full bg-success"></span>
        {@active_visitors} now
      </span>
    </form>
    """
  end

  @doc """
  A headline number, optionally with its change against the previous period.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil
  attr :delta, :float, default: nil
  attr :delta_good, :atom, default: :up, values: [:up, :down]

  def stat_tile(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 p-4">
      <div class="text-xs uppercase tracking-wide text-base-content/50">{@label}</div>
      <div class="mt-1 flex items-baseline gap-2">
        <span class="text-2xl font-semibold tabular-nums">{@value}</span>
        <span :if={@delta} class={["text-xs font-medium", delta_class(@delta, @delta_good)]}>
          {format_delta(@delta)}
        </span>
      </div>
      <div :if={@hint} class="mt-1 text-xs text-base-content/50">{@hint}</div>
    </div>
    """
  end

  @doc """
  The trend chart — one column per bucket, height proportional to the metric.

  Renders nothing but `div`s: no canvas, no chart library, no resize handler.

  Named `traffic_chart` rather than `bar_chart` because core 2.0 introduced
  `PhoenixKitWeb.Components.Core.Chart.bar_chart/1`, which every LiveView
  imports via `use PhoenixKitWeb, :live_view` — two same-arity imports of that
  name make an unqualified call ambiguous and fail to compile. Core's is a
  generic SVG chart keyed on `id`/`data`; this one is bucket-aware and takes
  `series`/`metric`/`bucket`, so they are not interchangeable.
  """
  attr :series, :list, required: true
  attr :metric, :atom, default: :pageviews, values: [:pageviews, :visitors]
  attr :bucket, :atom, default: :day

  def traffic_chart(assigns) do
    assigns = assign(assigns, :max, max_value(assigns.series, assigns.metric))

    ~H"""
    <div :if={@series == []} class="py-10 text-center text-sm text-base-content/50">
      No traffic in this period yet.
    </div>

    <div :if={@series != []} class="space-y-2">
      <div class="flex h-40 items-end gap-px">
        <div
          :for={point <- @series}
          class="group relative flex-1 rounded-t bg-primary/70 transition-colors hover:bg-primary"
          style={"height: #{bar_height(point, @metric, @max)}%"}
          title={"#{bucket_label(point.bucket, @bucket)} — #{format_number(Map.get(point, @metric))} #{@metric}"}
        >
        </div>
      </div>
      <div class="flex justify-between text-xs text-base-content/50">
        <span>{@series |> List.first() |> axis_label(@bucket)}</span>
        <span>{@series |> List.last() |> axis_label(@bucket)}</span>
      </div>
    </div>
    """
  end

  @doc """
  A ranked "label + counts" card, with each row's share drawn as a bar behind
  the label.
  """
  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :icon, :string, default: nil
  attr :empty_message, :string, default: "Nothing recorded yet."
  attr :label_header, :string, default: nil
  attr :metric_header, :string, default: "Views"
  attr :link, :string, default: nil
  attr :link_label, :string, default: "View all"

  def breakdown_card(assigns) do
    assigns = assign(assigns, :max, max_value(assigns.rows, :pageviews))

    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100">
      <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
        <h2 class="flex items-center gap-2 text-sm font-semibold">
          <.icon :if={@icon} name={@icon} class="h-4 w-4 text-base-content/50" />
          {@title}
        </h2>
        <.link :if={@link} navigate={@link} class="text-xs text-primary hover:underline">
          {@link_label}
        </.link>
      </div>

      <p :if={@rows == []} class="px-4 py-8 text-center text-sm text-base-content/50">
        {@empty_message}
      </p>

      <div :if={@rows != []} class="divide-y divide-base-200">
        <div
          :for={row <- @rows}
          class="relative flex items-center justify-between gap-4 px-4 py-2 text-sm"
        >
          <div
            class="absolute inset-y-0 left-0 bg-primary/10"
            style={"width: #{share(row, @max)}%"}
            aria-hidden="true"
          >
          </div>
          <span class="relative truncate" title={to_string(row.label)}>{row.label}</span>
          <span class="relative flex shrink-0 items-center gap-3 tabular-nums">
            <span class="text-base-content/50" title="Distinct visitors">
              {format_number(row[:visitors])}
            </span>
            <span class="font-medium">{format_number(row.pageviews)}</span>
          </span>
        </div>
      </div>

      <div
        :if={@rows != []}
        class="flex justify-end gap-3 border-t border-base-200 px-4 py-2 text-[11px] uppercase tracking-wide text-base-content/40"
      >
        <span>Visitors</span>
        <span>{@metric_header}</span>
      </div>
    </div>
    """
  end

  @doc "A short call to action shown when tracking is installed but off."
  attr :settings_path, :string, required: true

  def disabled_notice(assigns) do
    ~H"""
    <div class="rounded-xl border border-warning/40 bg-warning/10 p-4 text-sm">
      <div class="flex items-start gap-3">
        <.icon name="hero-exclamation-triangle" class="mt-0.5 h-5 w-5 text-warning" />
        <div>
          <p class="font-medium">Tracking is off — no new hits are being recorded.</p>
          <p class="mt-1 text-base-content/70">
            Enable Web Analytics on the Modules page, and make sure
            <code class="rounded bg-base-200 px-1">plug PhoenixKitWebAnalytics.Plug</code>
            is in your router's <code class="rounded bg-base-200 px-1">:browser</code>
            pipeline.
          </p>
          <.link navigate={@settings_path} class="mt-2 inline-block text-primary hover:underline">
            Open settings
          </.link>
        </div>
      </div>
    </div>
    """
  end

  # ── formatting helpers (shared by the LiveViews) ───────────────────────────

  @doc """
  Formats an integer with thin thousands separators (`1 234 567`).

      iex> PhoenixKitWebAnalytics.Web.Components.format_number(1234567)
      "1,234,567"
  """
  @spec format_number(integer() | float() | nil) :: String.t()
  def format_number(nil), do: "—"
  def format_number(value) when is_float(value), do: value |> round() |> format_number()

  def format_number(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  def format_number(_value), do: "—"

  @doc """
  Formats a duration in seconds as `1m 05s`.

      iex> PhoenixKitWebAnalytics.Web.Components.format_duration(65.4)
      "1m 05s"
  """
  @spec format_duration(number() | nil) :: String.t()
  def format_duration(nil), do: "—"

  def format_duration(seconds) when is_number(seconds) do
    total = round(seconds)
    minutes = div(total, 60)
    rest = rem(total, 60)

    if minutes > 0 do
      "#{minutes}m #{String.pad_leading(Integer.to_string(rest), 2, "0")}s"
    else
      "#{rest}s"
    end
  end

  def format_duration(_seconds), do: "—"

  @doc "Formats a percentage to one decimal place."
  @spec format_percent(number() | nil) :: String.t()
  def format_percent(nil), do: "—"
  def format_percent(value) when is_number(value), do: "#{Float.round(value / 1, 1)}%"
  def format_percent(_value), do: "—"

  @doc "Formats a millisecond duration."
  @spec format_ms(number() | nil) :: String.t()
  def format_ms(nil), do: "—"
  def format_ms(ms) when is_number(ms) and ms >= 1000, do: "#{Float.round(ms / 1000, 2)}s"
  def format_ms(ms) when is_number(ms), do: "#{round(ms)}ms"
  def format_ms(_ms), do: "—"

  @doc """
  Percentage change from `previous` to `current`, or `nil` when there is no
  meaningful comparison (no previous data, or no previous period at all).
  """
  @spec delta(number() | nil, number() | nil) :: float() | nil
  def delta(_current, nil), do: nil
  def delta(_current, 0), do: nil
  def delta(nil, _previous), do: nil

  def delta(current, previous) when is_number(current) and is_number(previous),
    do: (current - previous) * 100 / previous

  def delta(_current, _previous), do: nil

  # ── internals ──────────────────────────────────────────────────────────────

  defp max_value([], _metric), do: 0

  defp max_value(rows, metric) do
    rows
    |> Enum.map(&(Map.get(&1, metric) || 0))
    |> Enum.max(fn -> 0 end)
  end

  # A bucket with data always gets a visible sliver, so "a little" never looks
  # the same as "none".
  defp bar_height(_point, _metric, 0), do: 0

  defp bar_height(point, metric, max) do
    case Map.get(point, metric) || 0 do
      0 -> 0
      value -> max(value * 100 / max, 2)
    end
  end

  defp share(_row, 0), do: 0
  defp share(row, max), do: (row[:pageviews] || 0) * 100 / max

  defp bucket_label(%DateTime{} = bucket, :hour), do: Calendar.strftime(bucket, "%b %-d, %H:00")
  defp bucket_label(%DateTime{} = bucket, :month), do: Calendar.strftime(bucket, "%b %Y")
  defp bucket_label(%DateTime{} = bucket, _), do: Calendar.strftime(bucket, "%b %-d")
  defp bucket_label(other, _bucket), do: to_string(other)

  defp axis_label(nil, _bucket), do: ""
  defp axis_label(point, bucket), do: bucket_label(point.bucket, bucket)

  defp format_delta(delta) when delta > 0, do: "+#{Float.round(delta, 1)}%"
  defp format_delta(delta), do: "#{Float.round(delta / 1, 1)}%"

  defp delta_class(delta, good) do
    improving? = (good == :up and delta >= 0) or (good == :down and delta <= 0)

    if improving?, do: "text-success", else: "text-error"
  end
end
