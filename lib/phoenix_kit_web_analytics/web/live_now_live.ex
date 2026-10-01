defmodule PhoenixKitWebAnalytics.Web.LiveNowLive do
  @moduledoc """
  Right now — who is on the site this moment, and what they're looking at.

  Two sources, because they see different things:

    * **Open pages** — every LiveView page connected right now, from
      `PhoenixKitWebAnalytics.LivePresence`, shown per visitor or counted per
      page (two tabs of one card). Exact: a page appears when it connects and
      disappears the moment the tab closes.
    * **Recent visits** — visits with any activity in the last five minutes,
      which also covers pages without a LiveView.

  Built for a busy site: every list shows 50 rows at a time and pages from
  there — open pages from an ordered in-memory index, recent visits from the
  newest events — so the cost doesn't grow with the number of people online.

  The "for how long" times tick every second (only the clock changes, no
  query); the lists themselves refresh every five seconds.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  require Logger

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.LivePresence
  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Web.Filters
  alias PhoenixKitWebAnalytics.Web.UserNames

  @refresh_ms 5_000
  @tick_ms 1_000
  @recent_minutes 5
  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_ms, self(), :refresh)
      :timer.send_interval(@tick_ms, self(), :tick)
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Right now"))
     |> assign(:recent_minutes, @recent_minutes)
     |> assign(:page_size, @page_size)
     |> assign(:presence?, LivePresence.running?())
     |> assign(:open_tab, "visitors")
     # Paging: the cursor of the current page and the ones before it, so
     # "Newer" can step back.
     |> assign(:open_after, nil)
     |> assign(:open_history, [])
     |> assign(:recent_before, nil)
     |> assign(:recent_history, [])
     |> load()}
  end

  @impl true
  def handle_event("open_tab", %{"tab" => tab}, socket) when tab in ["visitors", "pages"] do
    {:noreply, socket |> assign(:open_tab, tab) |> assign_by_path()}
  end

  def handle_event("open_older", _params, socket) do
    %{open_after: current, open_next: next, open_history: history} = socket.assigns

    {:noreply, socket |> assign(open_after: next, open_history: [current | history]) |> load()}
  end

  def handle_event("open_newer", _params, socket) do
    case socket.assigns.open_history do
      [previous | rest] ->
        {:noreply, socket |> assign(open_after: previous, open_history: rest) |> load()}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_event("recent_older", _params, socket) do
    %{recent_before: current, recent_next: next, recent_history: history} = socket.assigns

    {:noreply,
     socket |> assign(recent_before: next, recent_history: [current | history]) |> load()}
  end

  def handle_event("recent_newer", _params, socket) do
    case socket.assigns.recent_history do
      [previous | rest] ->
        {:noreply, socket |> assign(recent_before: previous, recent_history: rest) |> load()}

      [] ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}

  def handle_info(message, socket) do
    Logger.debug("[WebAnalytics] LiveNowLive ignored #{inspect(message)}")
    {:noreply, socket}
  end

  defp load(socket) do
    {open, open_next} = LivePresence.page(limit: @page_size, after: socket.assigns.open_after)

    {recent, recent_next} =
      Reports.recent_sessions(@recent_minutes,
        limit: @page_size,
        before: socket.assigns.recent_before
      )

    names =
      UserNames.for_uuids(Enum.map(open, & &1.user_uuid) ++ Enum.map(recent, & &1.user_uuid))

    socket
    |> assign(:online, Filters.online(nil))
    |> assign(:open_total, LivePresence.count(nil))
    |> assign(:now, DateTime.utc_now())
    |> assign(:open, open)
    |> assign(:open_next, open_next)
    |> assign_by_path()
    |> assign(:recent, recent)
    |> assign(:recent_next, recent_next)
    |> assign(:names, names)
  end

  # Only counted while its tab is showing.
  defp assign_by_path(%{assigns: %{open_tab: "pages"}} = socket),
    do: assign(socket, :open_by_path, LivePresence.by_path(@page_size))

  defp assign_by_path(socket), do: assign(socket, :open_by_path, [])

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <.top_row online={@online} />

      <div :if={not @presence?} role="alert" class="alert alert-warning text-sm">
        <.icon name="hero-exclamation-triangle" class="h-5 w-5" />
        <span>
          {gettext(
            "Live presence isn't running on this node, so open pages can't be listed. It starts with the module's children."
          )}
        </span>
      </div>

      <.report_card id="open-pages" title={gettext("Open pages")} icon="hero-eye">
        <:info>
          <p>
            {gettext(
              "Every page someone has open this moment. Each visitor: one row per open page, with how long it has been open. By page: the same pages counted per page — what the site is being used for right now."
            )}
          </p>
          <p>
            {gettext(
              "Covers LiveView pages, which keep a live connection. Pages without one show up under Recent visits instead."
            )}
          </p>
        </:info>
        <:actions>
          <div role="tablist" class="tabs tabs-box tabs-xs">
            <button
              type="button"
              role="tab"
              phx-click="open_tab"
              phx-value-tab="visitors"
              class={["tab", @open_tab == "visitors" && "tab-active"]}
            >
              {gettext("Each visitor")}
            </button>
            <button
              type="button"
              role="tab"
              phx-click="open_tab"
              phx-value-tab="pages"
              class={["tab", @open_tab == "pages" && "tab-active"]}
            >
              {gettext("By page")}
            </button>
          </div>
        </:actions>

        <.empty_state
          :if={@open == [] and @open_history == []}
          title={gettext("Nobody has a page open right now.")}
          icon="hero-user"
          class="py-10 px-6"
        />

        <div :if={@open_tab == "visitors" and (@open != [] or @open_history != [])}>
          <.table_default size="sm" wrapper_class="overflow-x-auto">
            <.table_default_header>
              <.table_default_row>
                <.table_default_header_cell>{gettext("Page")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("For")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Visitor")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Client")}</.table_default_header_cell>
              </.table_default_row>
            </.table_default_header>
            <.table_default_body>
              <.table_default_row :for={visit <- @open}>
                <.table_default_cell class="max-w-xs truncate font-mono text-xs">
                  {visit.path}
                </.table_default_cell>
                <.table_default_cell class="whitespace-nowrap tabular-nums">
                  {format_duration(DateTime.diff(@now, visit.since))}
                </.table_default_cell>
                <.table_default_cell>
                  <.link
                    :if={visit.user_uuid}
                    navigate={Paths.sessions_for_user(visit.user_uuid)}
                    class="text-primary hover:underline"
                  >
                    {Map.get(@names, visit.user_uuid, gettext("Signed-in user"))}
                  </.link>
                  <span :if={is_nil(visit.user_uuid)} class="text-base-content/50">
                    {gettext("Anonymous")}
                  </span>
                </.table_default_cell>
                <.table_default_cell class="whitespace-nowrap text-base-content/60">
                  {Enum.join(
                    Enum.reject(
                      [visit.browser, visit.os, device_label(visit.device_type)],
                      &is_nil/1
                    ),
                    " · "
                  )}
                </.table_default_cell>
              </.table_default_row>
            </.table_default_body>
          </.table_default>
          <.pager
            newer?={@open_history != []}
            older?={@open_next != nil}
            newer_event="open_newer"
            older_event="open_older"
            summary={ngettext("%{count} page open", "%{count} pages open", @open_total)}
          />
        </div>

        <div :if={@open_tab == "pages" and @open_by_path != []}>
          <div class="flex items-center gap-2 px-4 pt-2 pb-1 text-[11px] uppercase tracking-wide text-base-content/40">
            <span class="min-w-0 flex-1">{gettext("Page")}</span>
            <span class="w-16 shrink-0 text-right">{gettext("Open")}</span>
          </div>
          <div class="divide-y divide-base-200 pb-1">
            <div
              :for={{path, count} <- @open_by_path}
              class="relative flex items-center gap-2 px-4 py-2 text-sm"
            >
              <div
                class="absolute inset-y-0 left-0 bg-primary/10"
                style={"width: #{count * 100 / max(elem(hd(@open_by_path), 1), 1)}%"}
                aria-hidden="true"
              >
              </div>
              <span class="relative min-w-0 flex-1 truncate font-mono text-xs" title={path}>
                {path}
              </span>
              <span class="relative w-16 shrink-0 text-right font-medium tabular-nums">
                {format_number(count)}
              </span>
            </div>
          </div>
          <p :if={length(@open_by_path) >= @page_size} class="px-4 py-3 text-xs text-base-content/50">
            {gettext("The %{count} pages with the most people on them.", count: @page_size)}
          </p>
        </div>
      </.report_card>

      <.report_card id="recent-visits-card" title={gettext("Recent visits")} icon="hero-clock">
        <:info>
          <p>
            {gettext(
              "Visits with any activity in the last %{minutes} minutes, most recently active first — including pages without a live connection. Open one to see what that visitor did.",
              minutes: @recent_minutes
            )}
          </p>
        </:info>
        <.sessions_table sessions={@recent} names={@names} now={@now} id="recent-visits" />
        <.pager
          :if={@recent != [] or @recent_history != []}
          newer?={@recent_history != []}
          older?={@recent_next != nil}
          newer_event="recent_newer"
          older_event="recent_older"
        />
      </.report_card>
    </div>
    """
  end
end
