defmodule PhoenixKitWebAnalytics.Web.RateLimitsLive do
  @moduledoc """
  Rate limits — the rules the installed `PhoenixKitWebAnalytics.RateLimit.Plug`s
  enforce, whether they are on, what each has allowed and refused on this
  server since it started, and the latest refusals.

  Everything shown is this node's memory (`PhoenixKitWebAnalytics.Ring`):
  nothing about a refusal is stored. The on / log only / off switch and the
  blocked networks are in Settings.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  require Logger

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.RateLimit

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, gettext("Rate limits")) |> load()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_info(message, socket) do
    Logger.debug("[WebAnalytics] RateLimitsLive ignored #{inspect(message)}")
    {:noreply, socket}
  end

  defp load(socket), do: assign(socket, :status, RateLimit.status())

  defp mode_text(:on), do: gettext("Rate limits are on: requests over a limit are refused.")

  defp mode_text(:log_only),
    do:
      gettext(
        "Log only: requests over a limit are recorded below and let through. Use it to tune the limits."
      )

  defp mode_text(:off), do: gettext("Rate limits are off: nothing is counted or refused.")

  defp scope_label(:visitor), do: gettext("Visitor")
  defp scope_label(:network), do: gettext("Network")
  defp scope_label(_scope), do: "—"

  defp action_label(:refused), do: gettext("Refused")
  defp action_label(:logged), do: gettext("Logged")
  defp action_label(:blocked), do: gettext("Blocked")
  defp action_label(_action), do: "—"

  defp rule_label(:blocked), do: gettext("Blocked network")
  defp rule_label(name), do: to_string(name)

  defp window_label(ms) when rem(ms, 60_000) == 0,
    do: ngettext("%{count} minute", "%{count} minutes", div(ms, 60_000))

  defp window_label(ms) when rem(ms, 1000) == 0,
    do: ngettext("%{count} second", "%{count} seconds", div(ms, 1000))

  defp window_label(ms), do: "#{ms} ms"

  defp methods_label(:any), do: gettext("Any")
  defp methods_label(methods), do: Enum.join(methods, ", ")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <div
        id="web-analytics-rate-limit-mode"
        class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-base-300 bg-base-100 p-4"
      >
        <div>
          <p class="font-medium">{mode_text(@status.mode)}</p>
          <p class="text-sm text-base-content/60">
            {gettext(
              "Rules come from the RateLimit.Plug in the site's router; this page shows what this server has seen since it started. Nothing about a refusal is stored."
            )}
          </p>
        </div>
        <div class="flex items-center gap-2">
          <.link navigate={Paths.settings()} class="btn btn-sm btn-ghost">
            {gettext("Settings")}
          </.link>
          <button
            type="button"
            phx-click="refresh"
            phx-disable-with={gettext("Refreshing…")}
            class="btn btn-sm btn-outline"
          >
            {gettext("Refresh")}
          </button>
        </div>
      </div>

      <div :if={not @status.backend?} role="alert" class="alert alert-warning text-sm">
        {gettext(
          "The rate-limit counters are not running on this server, so nothing is limited: every request is let through."
        )}
      </div>

      <.report_card id="rate-limit-rules" title={gettext("Rules")} icon="hero-shield-check">
        <:info>
          <p>
            {gettext(
              "Each request a rule covers is counted for its visitor and for its network, and both must have room. The visitor is the analytics' visitor ID, which changes with the browser; the network (an IPv4 address, or an IPv6 /64) is what holds a client that changes its browser string."
            )}
          </p>
          <p>
            {gettext(
              "A rule with no paths is only counted where the site's code charges it. A rule appears here once its plug has seen a request."
            )}
          </p>
        </:info>
        <.empty_state
          :if={@status.rules == []}
          title={gettext("No rate limits are installed.")}
          icon="hero-shield-check"
          class="py-10 px-6"
        />
        <.table_default :if={@status.rules != []} size="xs" wrapper_class="overflow-x-auto">
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell>{gettext("Rule")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Paths")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Methods")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Per visitor")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Per network")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Window")}</.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Allowed")}
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Refused")}
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Logged")}
              </.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>
          <.table_default_body>
            <.table_default_row :for={rule <- @status.rules}>
              <.table_default_cell class="font-mono text-xs">{rule.name}</.table_default_cell>
              <.table_default_cell class="max-w-xs font-mono text-xs">
                {if rule.paths == [],
                  do: gettext("charged from code"),
                  else: Enum.join(rule.paths, " ")}
              </.table_default_cell>
              <.table_default_cell class="text-xs">{methods_label(rule.methods)}</.table_default_cell>
              <.table_default_cell class="tabular-nums">
                {format_number(rule.limit)}
              </.table_default_cell>
              <.table_default_cell class="tabular-nums">
                {format_number(rule.network_limit)}
              </.table_default_cell>
              <.table_default_cell class="whitespace-nowrap">
                {window_label(rule.window_ms)}
              </.table_default_cell>
              <.table_default_cell class="text-right tabular-nums">
                {format_number(rule.allowed)}
              </.table_default_cell>
              <.table_default_cell class="text-right tabular-nums">
                {format_number(rule.refused)}
              </.table_default_cell>
              <.table_default_cell class="text-right tabular-nums">
                {format_number(rule.logged)}
              </.table_default_cell>
            </.table_default_row>
          </.table_default_body>
        </.table_default>
        <p :if={@status.blocked > 0} class="px-4 py-2 text-xs text-base-content/60">
          {ngettext(
            "%{count} request from a blocked network was refused.",
            "%{count} requests from blocked networks were refused.",
            @status.blocked
          )}
        </p>
      </.report_card>

      <.report_card id="rate-limit-denials" title={gettext("Latest refusals")} icon="hero-no-symbol">
        <:info>
          <p>
            {gettext(
              "The last %{count} requests over a limit or from a blocked network, newest first, on this server. The network is shown whole only when Settings keeps whole addresses; otherwise its /24 or /48. Paths never include a query string.",
              count: RateLimit.denials_kept()
            )}
          </p>
        </:info>
        <.empty_state
          :if={@status.denials == []}
          title={gettext("Nothing has been refused.")}
          icon="hero-no-symbol"
          class="py-10 px-6"
        />
        <.table_default :if={@status.denials != []} size="xs" wrapper_class="overflow-x-auto">
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell>{gettext("Time")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Rule")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Limit hit")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("What happened")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Network")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Visitor")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Request")}</.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>
          <.table_default_body>
            <.table_default_row :for={denial <- @status.denials}>
              <.table_default_cell class="whitespace-nowrap text-base-content/60">
                {Calendar.strftime(denial.at, "%Y-%m-%d %H:%M:%S")}
              </.table_default_cell>
              <.table_default_cell class="font-mono text-xs">
                {rule_label(denial.rule)}
              </.table_default_cell>
              <.table_default_cell>{scope_label(denial.scope)}</.table_default_cell>
              <.table_default_cell>{action_label(denial.action)}</.table_default_cell>
              <.table_default_cell class="font-mono text-xs">
                {denial.network || "—"}
              </.table_default_cell>
              <.table_default_cell class="font-mono text-xs">
                {denial.visitor || "—"}
              </.table_default_cell>
              <.table_default_cell class="max-w-xs truncate font-mono text-xs">
                {Enum.join(Enum.reject([denial.method, denial.path], &is_nil/1), " ")}
              </.table_default_cell>
            </.table_default_row>
          </.table_default_body>
        </.table_default>
      </.report_card>
    </div>
    """
  end
end
