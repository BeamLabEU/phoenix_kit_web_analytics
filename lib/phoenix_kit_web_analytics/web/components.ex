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
  import PhoenixKitWeb.Components.Core.PopoverPanel
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.StatusDot
  import PhoenixKitWeb.Components.Core.TableDefault

  alias PhoenixKitWebAnalytics.Reports

  @doc """
  The period selector shared by every report page — plus the site selector,
  only when the app actually served more than one host (an app on one domain
  has nothing to choose), and the page-filter chip when one is active.

  Two switches widen what is counted — the traffic the settings leave out
  (the site's own people and networks) and bot traffic. Either reads the
  period from raw events, which retention prunes, so a note says so.

  Emits `phx-change="filter"` with `period`, `site`, `path`, `flagged` and
  `bots` params.
  """
  attr :id, :string, default: "web-analytics-filter"
  attr :period, :string, required: true
  attr :site, :string, default: nil
  attr :sites, :list, default: []
  attr :path, :string, default: nil, doc: "the active path filter, if any"
  attr :base_path, :string, default: nil, doc: "this report's URL, to clear the path filter"
  attr :flagged, :boolean, default: false, doc: "showing the traffic the settings leave out"
  attr :bots, :boolean, default: false, doc: "showing bot traffic"

  attr :raw, :boolean,
    default: false,
    doc: "read from raw events for the switches' sake (theirs, or a setting counting a flag in)"

  def filter_bar(assigns) do
    ~H"""
    <form id={@id} phx-change="filter" class="flex flex-wrap items-center gap-2">
      <input :if={@path} type="hidden" name="path" value={@path} />
      <.select
        name="period"
        value={@period}
        options={Enum.map(Reports.periods(), fn {value, _} -> {period_label(value), value} end)}
        class="select-sm w-auto"
        aria-label={gettext("Period")}
      />
      <.select
        :if={length(@sites) > 1}
        name="site"
        value={@site || ""}
        options={[{gettext("All sites"), ""} | Enum.map(@sites, &{&1, &1})]}
        class="select-sm w-auto"
        aria-label={gettext("Site")}
      />
      <label
        class="flex cursor-pointer items-center gap-1.5 text-sm"
        title={
          gettext(
            "Also count the traffic Settings leave out of the statistics: the site's own people and their networks."
          )
        }
      >
        <input
          type="checkbox"
          name="flagged"
          value="1"
          checked={@flagged}
          class="checkbox checkbox-sm"
        />
        {gettext("Own traffic")}
      </label>
      <label
        class="flex cursor-pointer items-center gap-1.5 text-sm"
        title={gettext("Also count bot traffic (stored only when Settings record it).")}
      >
        <input type="checkbox" name="bots" value="1" checked={@bots} class="checkbox checkbox-sm" />
        {gettext("Bots")}
      </label>
      <span
        :if={@flagged or @bots or @raw}
        id={"#{@id}-raw-note"}
        class="text-xs text-base-content/50"
      >
        {gettext(
          "Read from raw events: days older than the raw-event retention have no data here, rather than zero visits."
        )}
      </span>
      <.link
        :if={@path && @base_path}
        patch={
          PhoenixKitWebAnalytics.Web.Filters.patch_to(@base_path, %{
            "period" => @period,
            "site" => @site,
            "flagged" => @flagged,
            "bots" => @bots
          })
        }
        class="badge badge-primary gap-1 font-mono"
        title={gettext("Remove the page filter")}
      >
        {@path} <.icon name="hero-x-mark" class="h-3 w-3" />
      </.link>
    </form>
    """
  end

  @doc """
  "N online" — people on the site now — linking to the Right now page.
  """
  attr :count, :integer, required: true

  attr :path, :string,
    default: nil,
    doc: "where the badge links; nil on the Right now page itself"

  def online_badge(assigns) do
    ~H"""
    <.link
      :if={@path}
      navigate={@path}
      class="badge badge-ghost h-8 gap-2 px-3"
      title={gettext("People on the site now — open Right now")}
    >
      <.online_badge_content count={@count} />
    </.link>
    <span :if={is_nil(@path)} class="badge badge-ghost h-8 gap-2 px-3">
      <.online_badge_content count={@count} />
    </span>
    """
  end

  attr :count, :integer, required: true

  defp online_badge_content(assigns) do
    ~H"""
    <.status_dot
      variant={if @count > 0, do: :success, else: :neutral}
      pulse={@count > 0}
      size={:xs}
    />
    {ngettext("%{count} online", "%{count} online", @count)}
    """
  end

  @doc """
  The top row of every report page: the filters on the left, the online
  badge on the right. On the Right now page, pass no `period` (there is no
  window to choose) and no `live_path`.
  """
  attr :period, :string, default: nil
  attr :site, :string, default: nil
  attr :sites, :list, default: []
  attr :path, :string, default: nil
  attr :base_path, :string, default: nil
  attr :online, :integer, required: true
  attr :live_path, :string, default: nil
  attr :flagged, :boolean, default: false
  attr :bots, :boolean, default: false
  attr :raw, :boolean, default: false

  def top_row(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3">
      <.filter_bar
        :if={@period}
        period={@period}
        site={@site}
        sites={@sites}
        path={@path}
        base_path={@base_path}
        flagged={@flagged}
        bots={@bots}
        raw={@raw}
      />
      <span :if={is_nil(@period)}></span>
      <.online_badge count={@online} path={@live_path} />
    </div>
    """
  end

  @doc """
  A titled card around a table or list, with an optional (i) explanation
  and actions on the right — the frame every report section shares.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, default: nil
  attr :info_align, :string, default: "start", values: ["start", "end"]
  attr :class, :any, default: nil
  slot :info
  slot :actions
  slot :inner_block, required: true

  def report_card(assigns) do
    ~H"""
    <div id={@id} class={["min-w-0 rounded-xl border border-base-300 bg-base-100", @class]}>
      <div class="flex flex-wrap items-center justify-between gap-2 border-b border-base-300 px-4 py-3">
        <h2 class="flex items-center gap-2 text-sm font-semibold">
          <.icon :if={@icon} name={@icon} class="h-4 w-4 text-base-content/50" />
          {@title}
          <.info_tip :if={@info != []} id={"#{@id}-info"} title={@title} align={@info_align}>
            {render_slot(@info)}
          </.info_tip>
        </h2>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A small (i) that opens an explanation — a card under the icon on wide
  screens, a full-width card on a phone. Opens and closes on the client, with
  no server round trip.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :align, :string, default: "start", values: ["start", "end"]
  slot :inner_block, required: true

  def info_tip(assigns) do
    ~H"""
    <span class="relative inline-flex align-middle">
      <button
        type="button"
        phx-click={toggle_popover(@id)}
        class="inline-flex h-5 w-5 items-center justify-center rounded-full text-base-content/40 hover:text-base-content/80 focus:outline-none focus-visible:ring-2 focus-visible:ring-primary"
        aria-label={gettext("What does “%{title}” mean?", title: @title)}
      >
        <.icon name="hero-information-circle" class="h-4 w-4" />
      </button>
      <.popover_panel id={@id} align={@align} width_class="sm:w-80">
        <div class="space-y-2 p-4 text-left text-sm font-normal normal-case tracking-normal text-base-content">
          <p class="font-semibold">{@title}</p>
          <div class="space-y-2 text-base-content/80">{render_slot(@inner_block)}</div>
        </div>
      </.popover_panel>
    </span>
    """
  end

  @doc """
  A headline number, optionally with its change against the previous period
  and an (i) explanation (the `:info` slot).
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :delta, :float, default: nil
  attr :delta_good, :atom, default: :up, values: [:up, :down]
  attr :info_align, :string, default: "start", values: ["start", "end"]
  slot :info

  def stat_tile(assigns) do
    ~H"""
    <div id={@id} class="rounded-xl border border-base-300 bg-base-100 p-4">
      <div class="flex items-center gap-1 text-xs uppercase tracking-wide text-base-content/50">
        <span>{@label}</span>
        <.info_tip :if={@info != []} id={"#{@id}-info"} title={@label} align={@info_align}>
          {render_slot(@info)}
        </.info_tip>
      </div>
      <div class="mt-1 flex items-baseline gap-2">
        <span class="text-2xl font-semibold tabular-nums">{@value}</span>
        <span :if={@delta} class={["text-xs font-medium", delta_class(@delta, @delta_good)]}>
          {format_delta(@delta)}
        </span>
      </div>
    </div>
    """
  end

  @doc """
  The trend chart — core's server-rendered SVG `bar_chart`, one bar per
  bucket, with dates in a row beneath it that uses the chart's own slot
  widths, so every date sits under its bar. Only every few buckets are
  labelled (at most about seven), which keeps a month of days readable on a
  phone. Hovering a bar shows its exact date and count.
  """
  attr :id, :string, default: "web-analytics-trend"
  attr :series, :list, required: true
  attr :metric, :atom, default: :pageviews, values: [:pageviews, :visitors]
  attr :bucket, :atom, default: :day

  def traffic_chart(assigns) do
    n = length(assigns.series)
    every = max(ceil(n / 7), 1)

    assigns =
      assigns
      |> assign(
        :data,
        Enum.map(assigns.series, fn point ->
          %{
            label: bucket_label(point.bucket, assigns.bucket),
            value: Map.get(point, assigns.metric)
          }
        end)
      )
      |> assign(
        :ticks,
        assigns.series
        |> Enum.with_index()
        |> Enum.map(fn {point, i} ->
          # Count from the end, so the latest bucket (today) is always named.
          if rem(n - 1 - i, every) == 0, do: tick_label(point.bucket, assigns.bucket)
        end)
      )
      |> assign(:slot, if(n > 0, do: 100 / n, else: 100))

    ~H"""
    <.empty_state
      :if={@series == [] or Enum.all?(@data, &(&1.value in [0, nil]))}
      title={gettext("No traffic in this period yet.")}
      icon="hero-chart-bar"
      class="py-10 px-6"
    />

    <div :if={@series != [] and Enum.any?(@data, &(&1.value not in [0, nil]))}>
      <div class="h-40">
        <.bar_chart
          id={@id}
          data={@data}
          height={160}
          class="text-primary"
          aria_label={gettext("Page views over time")}
          value_format={&format_number/1}
        />
      </div>
      <div class="mt-1 flex text-[11px] text-base-content/50 tabular-nums">
        <span
          :for={tick <- @ticks}
          class="overflow-visible whitespace-nowrap text-center"
          style={"width: #{@slot}%"}
        >
          {tick}
        </span>
      </div>
    </div>
    """
  end

  @doc """
  A ranked list: a label and one or two counts per row, with each row's
  share drawn as a bar behind it. Column headers sit on top, in the same
  fixed-width columns as the numbers, and the title's (i) explains where the
  data comes from and what the columns count.

  `labels` names a vocabulary the row labels come from (`:channel`, `:device`)
  so raw stored values ("organic", "desktop") are shown translated.
  """
  attr :id, :string, default: nil, doc: "needed for the (i) explanation"
  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :icon, :string, default: nil
  attr :empty_message, :string, default: nil
  attr :label_header, :string, default: nil
  attr :metric_header, :string, default: nil
  attr :link, :string, default: nil
  attr :link_label, :string, default: nil
  attr :labels, :atom, default: nil, values: [nil, :channel, :device, :client]
  attr :show_visitors, :boolean, default: true
  attr :info_align, :string, default: "start", values: ["start", "end"]
  slot :info

  def breakdown_card(assigns) do
    assigns = assign(assigns, :max, max_value(assigns.rows, :pageviews))

    ~H"""
    <%!-- min-w-0: as a grid item the card would otherwise size to its longest
         label and push the page wider than a phone screen. --%>
    <div class="min-w-0 rounded-xl border border-base-300 bg-base-100">
      <div class="flex items-center justify-between gap-2 border-b border-base-300 px-4 py-3">
        <h2 class="flex items-center gap-2 text-sm font-semibold">
          <.icon :if={@icon} name={@icon} class="h-4 w-4 text-base-content/50" />
          {@title}
          <.info_tip
            :if={@info != [] and @id}
            id={"#{@id}-info"}
            title={@title}
            align={@info_align}
          >
            {render_slot(@info)}
          </.info_tip>
        </h2>
        <.link :if={@link} navigate={@link} class="shrink-0 text-xs text-primary hover:underline">
          {@link_label || gettext("View all")}
        </.link>
      </div>

      <.empty_state
        :if={@rows == []}
        title={@empty_message || gettext("Nothing recorded yet.")}
        class="py-8 px-6"
      />

      <div
        :if={@rows != []}
        class="flex items-center gap-2 px-4 pt-2 pb-1 text-[11px] uppercase tracking-wide text-base-content/40"
      >
        <span class="min-w-0 flex-1 truncate">{@label_header}</span>
        <span :if={@show_visitors} class="w-16 shrink-0 text-right">{gettext("Visitors")}</span>
        <span class="w-16 shrink-0 text-right">{@metric_header || gettext("Views")}</span>
      </div>

      <div :if={@rows != []} class="divide-y divide-base-200 pb-1">
        <div :for={row <- @rows} class="relative flex items-center gap-2 px-4 py-2 text-sm">
          <div
            class="absolute inset-y-0 left-0 bg-primary/10"
            style={"width: #{share(row, @max)}%"}
            aria-hidden="true"
          >
          </div>
          <% label = row_label(row.label, @labels) %>
          <span class="relative min-w-0 flex-1 truncate" title={label}>{label}</span>
          <span
            :if={@show_visitors}
            class="relative w-16 shrink-0 text-right tabular-nums text-base-content/60"
          >
            {format_number(row[:visitors])}
          </span>
          <span class="relative w-16 shrink-0 text-right font-medium tabular-nums">
            {format_number(row.pageviews)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  "Newer" / "Older" paging under a list, with an optional summary between.
  Either `phx-click` events (`newer_event` / `older_event`) or links
  (`newer_path` / `older_path`, patched) move between pages.
  """
  attr :newer?, :boolean, required: true
  attr :older?, :boolean, required: true
  attr :newer_event, :string, default: nil
  attr :older_event, :string, default: nil
  attr :newer_path, :string, default: nil
  attr :older_path, :string, default: nil
  attr :summary, :string, default: nil

  def pager(assigns) do
    ~H"""
    <div
      :if={@newer? or @older? or @summary}
      class="flex items-center justify-between gap-2 border-t border-base-200 px-4 py-2"
    >
      <.pager_button
        enabled={@newer?}
        event={@newer_event}
        path={@newer_path}
        icon="hero-chevron-left"
        label={gettext("Newer")}
      />
      <span class="text-xs text-base-content/50">{@summary}</span>
      <.pager_button
        enabled={@older?}
        event={@older_event}
        path={@older_path}
        icon="hero-chevron-right"
        label={gettext("Older")}
        icon_after
      />
    </div>
    """
  end

  attr :enabled, :boolean, required: true
  attr :event, :string, default: nil
  attr :path, :string, default: nil
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :icon_after, :boolean, default: false

  defp pager_button(assigns) do
    ~H"""
    <span :if={not @enabled} class="w-20"></span>
    <.link :if={@enabled and @path} patch={@path} class="btn btn-ghost btn-xs gap-1">
      <.icon :if={not @icon_after} name={@icon} class="h-3 w-3" />{@label}<.icon
        :if={@icon_after}
        name={@icon}
        class="h-3 w-3"
      />
    </.link>
    <button
      :if={@enabled and is_nil(@path)}
      type="button"
      phx-click={@event}
      class="btn btn-ghost btn-xs gap-1"
    >
      <.icon :if={not @icon_after} name={@icon} class="h-3 w-3" />{@label}<.icon
        :if={@icon_after}
        name={@icon}
        class="h-3 w-3"
      />
    </button>
    """
  end

  @doc "The standard explanation of a breakdown card's Visitors / Views columns."
  def columns_explained(assigns) do
    ~H"""
    <p>
      {gettext(
        "Visitors: how many different people. Views: how many times, counting every person's every view — one person opening a page three times is 1 visitor and 3 views."
      )}
    </p>
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
      class="py-10 px-6"
    />
    <.table_default
      :if={@sessions != []}
      id={@id}
      size="sm"
      toggleable
      show_toggle={false}
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
              Enum.reject(
                [client_label(session.browser), client_label(session.os), session.country_code],
                &is_nil/1
              ),
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

  @doc """
  The label for a stored browser or operating-system name: real names
  (Chrome, macOS) are shown as they are; the two placeholders the
  User-Agent parser stores are translated.
  """
  @spec client_label(String.t() | nil) :: String.t() | nil
  def client_label("Unknown"), do: gettext("Unknown")
  def client_label("Other"), do: gettext("Other")
  def client_label(name), do: name

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
  defp row_label(label, :client), do: client_label(label)
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

  # Short dates for the tick row under the chart: 24.09, 14:00, 09.2026.
  defp tick_label(%DateTime{} = bucket, :hour), do: Calendar.strftime(bucket, "%H:00")
  defp tick_label(%DateTime{} = bucket, :month), do: Calendar.strftime(bucket, "%m.%Y")
  defp tick_label(%DateTime{} = bucket, _), do: Calendar.strftime(bucket, "%d.%m")
  defp tick_label(other, _bucket), do: to_string(other)

  defp format_delta(delta) when delta > 0, do: "+#{Float.round(delta, 1)}%"
  defp format_delta(delta), do: "#{Float.round(delta / 1, 1)}%"

  defp delta_class(delta, good) do
    improving? = (good == :up and delta >= 0) or (good == :down and delta <= 0)

    if improving?, do: "text-success", else: "text-error"
  end
end
