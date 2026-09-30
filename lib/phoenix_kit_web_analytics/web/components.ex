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
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  import PhoenixKitWeb.Components.Core.Chart, only: [bar_chart: 1]
  import PhoenixKitWeb.Components.Core.EmptyState
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.StatusDot
  import PhoenixKitWeb.Components.Core.TableDefault

  alias PhoenixKitWebAnalytics.Reports

  @doc """
  Period + site selector shared by every report page.

  Emits `phx-change="filter"` with `period` and `site` params.
  """
  attr :id, :string, default: "web-analytics-filter"
  attr :period, :string, required: true
  attr :site, :string, default: nil
  attr :sites, :list, default: []
  attr :active_visitors, :integer, default: nil
  attr :live_path, :string, default: nil
  attr :path, :string, default: nil, doc: "the active path filter, if any"
  attr :base_path, :string, default: nil, doc: "this report's URL, to clear the path filter"

  def filter_bar(assigns) do
    ~H"""
    <form id={@id} phx-change="filter" class="flex flex-wrap items-center gap-2">
      <input :if={@path} type="hidden" name="path" value={@path} />
      <.link
        :if={@path && @base_path}
        patch={
          PhoenixKitWebAnalytics.Web.Filters.patch_to(@base_path, %{
            "period" => @period,
            "site" => @site
          })
        }
        class="badge badge-primary gap-1 font-mono"
        title={gettext("Remove the page filter")}
      >
        {@path} <.icon name="hero-x-mark" class="h-3 w-3" />
      </.link>
      <.select
        name="period"
        value={@period}
        options={Enum.map(Reports.periods(), fn {value, _} -> {period_label(value), value} end)}
        class="select-sm w-auto"
        aria-label={gettext("Period")}
      />
      <.select
        :if={@sites != []}
        name="site"
        value={@site || ""}
        options={[{gettext("All sites"), ""} | Enum.map(@sites, &{&1, &1})]}
        class="select-sm w-auto"
        aria-label={gettext("Site")}
      />
      <.link :if={is_integer(@active_visitors)} navigate={@live_path} class="badge badge-ghost gap-2">
        <.status_dot
          variant={if @active_visitors > 0, do: :success, else: :neutral}
          pulse={@active_visitors > 0}
          size={:xs}
        />
        {ngettext("%{count} online", "%{count} online", @active_visitors)}
      </.link>
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
  The trend chart — core's server-rendered SVG `bar_chart`, one bar per
  bucket, with the first and last bucket named beneath it (as HTML, never as
  SVG text, which the chart's stretched aspect ratio would distort).
  """
  attr :id, :string, default: "web-analytics-trend"
  attr :series, :list, required: true
  attr :metric, :atom, default: :pageviews, values: [:pageviews, :visitors]
  attr :bucket, :atom, default: :day

  def traffic_chart(assigns) do
    assigns =
      assign(
        assigns,
        :data,
        Enum.map(assigns.series, fn point ->
          %{
            label: bucket_label(point.bucket, assigns.bucket),
            value: Map.get(point, assigns.metric)
          }
        end)
      )

    ~H"""
    <.empty_state
      :if={@series == [] or Enum.all?(@data, &(&1.value in [0, nil]))}
      title={gettext("No traffic in this period yet.")}
      icon="hero-chart-bar"
      class="py-10"
    />

    <div :if={@series != [] and Enum.any?(@data, &(&1.value not in [0, nil]))} class="space-y-2">
      <.bar_chart
        id={@id}
        data={@data}
        height={160}
        class="text-primary"
        aria_label={gettext("Page views over time")}
      />
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

  `labels` names a vocabulary the row labels come from (`:channel`, `:device`)
  so raw stored values ("organic", "desktop") are shown translated.
  """
  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :icon, :string, default: nil
  attr :empty_message, :string, default: nil
  attr :metric_header, :string, default: nil
  attr :link, :string, default: nil
  attr :link_label, :string, default: nil
  attr :labels, :atom, default: nil, values: [nil, :channel, :device]
  attr :show_visitors, :boolean, default: true

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
          {@link_label || gettext("View all")}
        </.link>
      </div>

      <.empty_state
        :if={@rows == []}
        title={@empty_message || gettext("Nothing recorded yet.")}
        class="py-8"
      />

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
          <% label = row_label(row.label, @labels) %>
          <span class="relative min-w-0 truncate" title={label}>{label}</span>
          <span class="relative flex shrink-0 items-center gap-3 tabular-nums">
            <span
              :if={@show_visitors}
              class="text-base-content/50"
              title={gettext("Distinct visitors")}
            >
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
        <span :if={@show_visitors}>{gettext("Visitors")}</span>
        <span>{@metric_header || gettext("Views")}</span>
      </div>
    </div>
    """
  end

  @doc "A short call to action shown when tracking is installed but off."
  attr :settings_path, :string, required: true

  def disabled_notice(assigns) do
    ~H"""
    <div role="alert" class="alert alert-warning">
      <.icon name="hero-exclamation-triangle" class="h-5 w-5" />
      <div>
        <p class="font-medium">{gettext("Tracking is off — no new hits are being recorded.")}</p>
        <p class="mt-1 text-sm">
          {gettext(
            "Enable Web Analytics on the Modules page, and make sure %{plug} is in your router's browser pipeline.",
            plug: "PhoenixKitWebAnalytics.Plug"
          )}
        </p>
        <.link navigate={@settings_path} class="mt-2 inline-block underline">
          {gettext("Open settings")}
        </.link>
      </div>
    </div>
    """
  end

  @doc """
  One hit described in words, with an icon — "Viewed page", "Clicked
  add_to_cart", "Left after 1m 05s" — for the live feed and session timelines.
  """
  attr :hit, :map, required: true

  def hit_summary(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5">
      <.icon name={hit_icon(@hit.event_type)} class="h-3.5 w-3.5 shrink-0 text-base-content/50" />
      <span>{hit_text(@hit)}</span>
      <span
        :for={{key, value} <- hit_params(@hit)}
        class="badge badge-ghost badge-xs font-mono"
      >
        {key}={value}
      </span>
    </span>
    """
  end

  defp hit_icon("pageview"), do: "hero-document-text"
  defp hit_icon("interaction"), do: "hero-cursor-arrow-rays"
  defp hit_icon("leave"), do: "hero-arrow-right-start-on-rectangle"
  defp hit_icon("event"), do: "hero-bolt"
  defp hit_icon(_type), do: "hero-signal"

  defp hit_text(%{event_type: "pageview", page_title: title}) when is_binary(title),
    do: gettext("Viewed “%{title}”", title: title)

  defp hit_text(%{event_type: "pageview"}), do: gettext("Viewed page")

  defp hit_text(%{event_type: "interaction", event_name: "scroll", scroll_depth: depth}),
    do: gettext("Scrolled to %{percent}%", percent: depth || 0)

  defp hit_text(%{event_type: "interaction", event_name: name, target: target})
       when is_binary(target),
       do: "#{interaction_label(name)}: #{target}"

  defp hit_text(%{event_type: "interaction", event_name: name}),
    do: gettext("Did “%{event}”", event: name)

  defp hit_text(%{event_type: "leave", engaged_ms: ms, scroll_depth: depth})
       when is_integer(depth) and depth > 0,
       do:
         gettext("Left after %{time}, scrolled %{percent}%",
           time: format_duration(ms && ms / 1000),
           percent: depth
         )

  defp hit_text(%{event_type: "leave", engaged_ms: ms}),
    do: gettext("Left after %{time}", time: format_duration(ms && ms / 1000))

  defp hit_text(%{event_type: "event", event_name: name}),
    do: gettext("Event “%{event}”", event: name)

  defp hit_text(_hit), do: gettext("Hit")

  defp hit_params(%{metadata: %{"params" => params}}) when is_map(params), do: Enum.sort(params)
  defp hit_params(_hit), do: []

  @doc """
  A list of visits (rows from `Reports.sessions/2`): when, who, where they
  landed and left, how many pages, what they did, how long, where from. Each
  row opens the visit's timeline. Cards on narrow screens.
  """
  attr :id, :string, required: true
  attr :sessions, :list, required: true
  attr :names, :map, default: %{}
  attr :now, :any, default: nil
  attr :empty_message, :string, default: nil

  def sessions_table(assigns) do
    ~H"""
    <.empty_state
      :if={@sessions == []}
      title={@empty_message || gettext("No visits in this period.")}
      icon="hero-users"
      class="py-10"
    />
    <.table_default
      :if={@sessions != []}
      id={@id}
      size="sm"
      toggleable
      items={@sessions}
      item_id={& &1.session_id}
      card_title={&visitor_name(&1, @names)}
      card_fields={
        fn session ->
          [
            %{label: gettext("Started"), value: format_time(session.started_at, @now)},
            %{label: gettext("Landed on"), value: session.entry_path},
            %{label: gettext("Pages"), value: format_number(session.pageviews)},
            %{label: gettext("Duration"), value: format_duration(session.seconds)},
            %{label: gettext("Source"), value: session_source(session)}
          ]
        end
      }
      wrapper_class="overflow-x-auto"
    >
      <:card_actions :let={session}>
        <.link
          navigate={PhoenixKitWebAnalytics.Paths.session(session.session_id)}
          class="btn btn-ghost btn-xs"
        >
          {gettext("Open visit")}
        </.link>
      </:card_actions>
      <.table_default_header>
        <.table_default_row>
          <.table_default_header_cell>{gettext("Started")}</.table_default_header_cell>
          <.table_default_header_cell>{gettext("Visitor")}</.table_default_header_cell>
          <.table_default_header_cell>{gettext("Landed on → left from")}</.table_default_header_cell>
          <.table_default_header_cell class="text-right">
            {gettext("Pages")}
          </.table_default_header_cell>
          <.table_default_header_cell class="text-right">
            {gettext("Actions")}
          </.table_default_header_cell>
          <.table_default_header_cell class="text-right">
            {gettext("Duration")}
          </.table_default_header_cell>
          <.table_default_header_cell>{gettext("Source")}</.table_default_header_cell>
          <.table_default_header_cell>{gettext("Client")}</.table_default_header_cell>
        </.table_default_row>
      </.table_default_header>
      <.table_default_body>
        <.table_default_row :for={session <- @sessions}>
          <.table_default_cell class="whitespace-nowrap text-base-content/70">
            <.link
              navigate={PhoenixKitWebAnalytics.Paths.session(session.session_id)}
              class="text-primary hover:underline"
            >
              {format_time(session.started_at, @now)}
            </.link>
          </.table_default_cell>
          <.table_default_cell class="whitespace-nowrap">
            <span class={is_nil(session.user_uuid) && "text-base-content/50"}>
              {visitor_name(session, @names)}
            </span>
          </.table_default_cell>
          <.table_default_cell class="max-w-xs truncate font-mono text-xs">
            {session.entry_path}<span
              :if={session.exit_path && session.exit_path != session.entry_path}
              class="text-base-content/50"
            > → {session.exit_path}</span>
          </.table_default_cell>
          <.table_default_cell class="text-right tabular-nums">
            {format_number(session.pageviews)}
          </.table_default_cell>
          <.table_default_cell class="text-right tabular-nums">
            {format_number(session.interactions)}
          </.table_default_cell>
          <.table_default_cell class="text-right tabular-nums">
            {format_duration(session.seconds)}
          </.table_default_cell>
          <.table_default_cell class="max-w-[10rem] truncate text-base-content/70">
            {session_source(session)}
          </.table_default_cell>
          <.table_default_cell class="whitespace-nowrap text-base-content/60">
            {Enum.join(
              Enum.reject([session.browser, session.os, session.country_code], &is_nil/1),
              " · "
            )}
          </.table_default_cell>
        </.table_default_row>
      </.table_default_body>
    </.table_default>
    """
  end

  @doc ~s(A visit's visitor: the signed-in user's display name, or "Anonymous".)
  @spec visitor_name(map(), map()) :: String.t()
  def visitor_name(%{user_uuid: uuid}, names) when is_binary(uuid),
    do: Map.get(names, uuid, gettext("Signed-in user"))

  def visitor_name(_session, _names), do: gettext("Anonymous")

  @doc "Where a visit came from: the referring source, else its channel."
  @spec session_source(map()) :: String.t()
  def session_source(%{source: source}) when is_binary(source), do: source
  def session_source(session), do: channel_label(session[:medium])

  @doc """
  A timestamp for a list: the time alone for today, the date and time
  otherwise.
  """
  @spec format_time(DateTime.t() | NaiveDateTime.t() | nil, DateTime.t() | nil) :: String.t()
  def format_time(nil, _now), do: "—"

  def format_time(%NaiveDateTime{} = at, now),
    do: at |> DateTime.from_naive!("Etc/UTC") |> format_time(now)

  def format_time(%DateTime{} = at, now) do
    today = (now || DateTime.utc_now()) |> DateTime.to_date()

    if Date.compare(DateTime.to_date(at), today) == :eq,
      do: Calendar.strftime(at, "%H:%M:%S"),
      else: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  end

  # ── vocabulary labels ──────────────────────────────────────────────────────

  @doc ~s(The label for a period value: "7d" is "Last 7 days".)
  @spec period_label(String.t()) :: String.t()
  def period_label("today"), do: gettext("Today")
  def period_label("yesterday"), do: gettext("Yesterday")
  def period_label("7d"), do: gettext("Last 7 days")
  def period_label("30d"), do: gettext("Last 30 days")
  def period_label("90d"), do: gettext("Last 90 days")
  def period_label("12m"), do: gettext("Last 12 months")
  def period_label("all"), do: gettext("All time")
  def period_label(other), do: to_string(other)

  @doc "The label for a stored channel (`referrer_medium`) value."
  @spec channel_label(String.t() | nil) :: String.t()
  def channel_label(medium) when medium in [nil, "none"], do: gettext("Direct")
  def channel_label("organic"), do: gettext("Search")
  def channel_label("social"), do: gettext("Social")
  def channel_label("referral"), do: gettext("Referral")
  def channel_label("internal"), do: gettext("Internal")
  def channel_label("email"), do: gettext("Email")
  def channel_label("paid"), do: gettext("Paid")
  def channel_label(other), do: to_string(other)

  @doc "The label for a stored device class."
  @spec device_label(String.t() | nil) :: String.t()
  def device_label("desktop"), do: gettext("Desktop")
  def device_label("mobile"), do: gettext("Mobile")
  def device_label("tablet"), do: gettext("Tablet")
  def device_label("bot"), do: gettext("Bot")
  def device_label(_other), do: gettext("Unknown")

  @doc "The label for an interaction name recorded by the client script."
  @spec interaction_label(String.t() | nil) :: String.t()
  def interaction_label("outbound"), do: gettext("Outbound link")
  def interaction_label("download"), do: gettext("Download")
  def interaction_label("contact"), do: gettext("Contact link")
  def interaction_label("click"), do: gettext("Click")
  def interaction_label("scroll"), do: gettext("Scrolled")
  def interaction_label(name), do: to_string(name)

  @doc "A `Reports.top_interactions/2` row as words: \"Outbound link · github.com/x\"."
  @spec interaction_row_label(map()) :: String.t()
  def interaction_row_label(%{name: name, target: nil}), do: interaction_label(name)

  def interaction_row_label(%{name: name, target: target}),
    do: "#{interaction_label(name)} · #{target}"

  @doc "Top-interaction rows with their labels in words, for a breakdown card."
  @spec label_interactions([map()]) :: [map()]
  def label_interactions(rows),
    do: Enum.map(rows, &Map.put(&1, :label, interaction_row_label(&1)))

  defp row_label(label, :channel), do: channel_label(label)
  defp row_label(label, :device), do: device_label(label)
  defp row_label(label, _vocabulary), do: to_string(label)

  # ── formatting helpers (shared by the LiveViews) ───────────────────────────

  @doc """
  Formats an integer with thousands separators.

      iex> PhoenixKitWebAnalytics.Web.Components.format_number(1234567)
      "1,234,567"
  """
  @spec format_number(integer() | float() | nil) :: String.t()
  def format_number(nil), do: "—"
  def format_number(value) when is_float(value), do: value |> round() |> format_number()

  def format_number(value) when is_integer(value) and value < 0,
    do: "-" <> format_number(-value)

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

  defp share(_row, 0), do: 0
  defp share(row, max), do: (row[:pageviews] || 0) * 100 / max

  # Numeric dates: `%b` month names are English-only.
  defp bucket_label(%DateTime{} = bucket, :hour), do: Calendar.strftime(bucket, "%Y-%m-%d %H:00")
  defp bucket_label(%DateTime{} = bucket, :month), do: Calendar.strftime(bucket, "%Y-%m")
  defp bucket_label(%DateTime{} = bucket, _), do: Calendar.strftime(bucket, "%Y-%m-%d")
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
