defmodule PhoenixKitWebAnalytics.Web.BotsLive do
  @moduledoc """
  Bots — the visitors a profile is kept for, ranked by how much they look
  automated, with the reasons; one by one, or grouped by the network, subnet,
  address, device or User-Agent several of them share.

  The page only reads: nothing here drops or blocks a visitor. A group's key
  is a link that narrows the list to it, and the address-shaped groupings
  offer their likely bots as a plain list, to paste into whatever does the
  blocking.

  Everything is a link carrying the whole filter in the URL, so the page
  works without JavaScript and any view of it can be bookmarked.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  require Logger

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.Bots
  alias PhoenixKitWebAnalytics.BotScore
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Profiles

  @periods [1, 7, 30, 0]
  @views [:visitors | Bots.groups()]
  # What a list for a firewall can be made of.
  @listable [:network, :subnet, :ip]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Bots"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = filter(params)
    view = one_of(params["group"], @views, :visitors)

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:view, view)
     |> assign(:summary, Bots.summary(filter))
     |> assign(:kept, kept(Config.collection_config()))
     |> assign(:total, Profiles.count())
     |> load(view, filter)}
  end

  @impl true
  def handle_info(message, socket) do
    Logger.debug("[WebAnalytics] BotsLive ignored #{inspect(message)}")
    {:noreply, socket}
  end

  defp load(socket, :visitors, filter) do
    visitors = Bots.visitors(filter)

    socket
    |> assign(:visitors, visitors)
    |> assign(:sessions, Bots.latest_sessions(Enum.map(visitors, & &1.visitor_id)))
    |> assign(:groups, [])
  end

  defp load(socket, view, filter) do
    socket
    |> assign(:visitors, [])
    |> assign(:sessions, %{})
    |> assign(:groups, Bots.groups(view, filter))
  end

  # ── the filter and its URL ────────────────────────────────────────────────

  defp filter(params) do
    %{
      days: days(params["days"]),
      level: one_of(params["level"], Bots.levels(), :all),
      asn: positive(params["asn"]),
      subnet: matching(params["subnet"], ~r/\A[0-9a-fA-F:.]{2,45}\/\d{1,3}\z/),
      ip: matching(params["ip"], ~r/\A[0-9a-fA-F:.]{2,45}(\/\d{1,3})?\z/),
      device: matching(params["device"], ~r/\A[0-9a-f]{32}\z/),
      agent: matching(params["agent"], ~r/\A[0-9a-f]{32}\z/)
    }
  end

  defp days(value) do
    case positive(value) do
      days when days in @periods -> days
      _ -> if value == "0", do: 0, else: 7
    end
  end

  defp positive(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp positive(_value), do: nil

  defp matching(value, pattern) when is_binary(value),
    do: if(Regex.match?(pattern, value), do: value)

  defp matching(_value, _pattern), do: nil

  # A word out of a fixed few; anything else is the default. Never makes an
  # atom.
  defp one_of(value, allowed, default) when is_binary(value),
    do: Enum.find(allowed, default, &(Atom.to_string(&1) == value))

  defp one_of(_value, _allowed, default), do: default

  # The URL of this page with `changes` applied to the filter and view.
  defp to(filter, view, changes) do
    filter
    |> Map.put(:group, view)
    |> Map.merge(Map.new(changes))
    |> Enum.reject(fn {key, value} ->
      is_nil(value) or {key, value} in [days: 7, level: :all, group: :visitors]
    end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), to_string(value)} end)
    |> Paths.bots()
  end

  # Narrowing to a group shows its visitors.
  defp narrow_to(filter, :network, key), do: to(filter, :visitors, asn: positive(key))
  defp narrow_to(filter, :subnet, key), do: to(filter, :visitors, subnet: key)
  defp narrow_to(filter, :ip, key), do: to(filter, :visitors, ip: key)
  defp narrow_to(filter, :device, key), do: to(filter, :visitors, device: key)
  defp narrow_to(filter, :agent, key), do: to(filter, :visitors, agent: key)

  defp narrowed(filter) do
    for {key, label} <- [
          asn: gettext("Network"),
          subnet: gettext("Subnet"),
          ip: gettext("Address"),
          device: gettext("Device"),
          agent: gettext("User-Agent")
        ],
        value = filter[key] do
      {key, label, narrowed_value(key, value)}
    end
  end

  defp narrowed_value(:asn, asn), do: "AS#{asn}"
  defp narrowed_value(key, hash) when key in [:device, :agent], do: short(hash)
  defp narrowed_value(_key, value), do: value

  # ── labels ────────────────────────────────────────────────────────────────

  defp days_label(1), do: gettext("24 hours")
  defp days_label(7), do: gettext("7 days")
  defp days_label(30), do: gettext("30 days")
  defp days_label(0), do: gettext("All")

  defp level_label(:all), do: gettext("Everyone")
  defp level_label(:suspicious), do: gettext("Suspicious and up")
  defp level_label(:likely), do: gettext("Likely bots")

  defp view_label(:visitors), do: gettext("Visitors")
  defp view_label(:network), do: gettext("Networks")
  defp view_label(:subnet), do: gettext("Subnets")
  defp view_label(:ip), do: gettext("Addresses")
  defp view_label(:device), do: gettext("Devices")
  defp view_label(:agent), do: gettext("User-Agents")

  defp key_header(:network), do: gettext("Network")
  defp key_header(:subnet), do: gettext("Subnet")
  defp key_header(:ip), do: gettext("Address")
  defp key_header(:device), do: gettext("Device")
  defp key_header(:agent), do: gettext("User-Agent")

  # What a grouping needs kept before it has anything to show.
  defp needs(:network),
    do: gettext("Needs the network's owner kept, and a geo resolver that knows it.")

  defp needs(:subnet), do: gettext("Needs the IP address kept.")
  defp needs(:ip), do: gettext("Needs the IP address kept.")
  defp needs(:device), do: gettext("Needs device measurements kept, and the client script on.")
  defp needs(:agent), do: gettext("Needs the full User-Agent kept.")

  defp group_title(:network, group), do: "AS#{group.key}"
  defp group_title(view, group) when view in [:device, :agent], do: short(group.key)
  defp group_title(_view, group), do: group.key

  defp short(hash) when is_binary(hash), do: String.slice(hash, 0, 10)
  defp short(_hash), do: nil

  defp seen(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp seen(_at), do: "—"

  defp network_label(profile) do
    [profile.asn && "AS#{profile.asn}", profile.network]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp kept(config), do: %{any?: Profiles.wanted?(config)}

  # The likely bots of an address-shaped grouping, one per line.
  defp firewall_list(view, groups) when view in @listable do
    groups
    |> Enum.filter(&(&1.likely > 0))
    |> Enum.map_join("\n", &group_title(view, &1))
  end

  defp firewall_list(_view, _groups), do: ""

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:periods, @periods)
      |> assign(:views, @views)
      |> assign(:levels, Bots.levels())
      |> assign(:narrowed, narrowed(assigns.filter))
      |> assign(:firewall, firewall_list(assigns.view, assigns.groups))

    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 class="text-xl font-semibold">{gettext("Bots")}</h1>
          <p class="max-w-2xl text-sm text-base-content/60">
            {gettext(
              "Visitors by how much they look automated, and why. Nothing here drops or blocks anyone — it is what you would decide by."
            )}
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <div id="bots-period" class="join">
            <.link
              :for={days <- @periods}
              patch={to(@filter, @view, days: days)}
              class={["btn btn-sm join-item", @filter.days == days && "btn-active"]}
            >
              {days_label(days)}
            </.link>
          </div>
          <div id="bots-level" class="join">
            <.link
              :for={level <- @levels}
              patch={to(@filter, @view, level: level)}
              class={["btn btn-sm join-item", @filter.level == level && "btn-active"]}
            >
              {level_label(level)}
            </.link>
          </div>
        </div>
      </div>

      <.empty_state
        :if={@total == 0}
        variant="card"
        icon="hero-bug-ant"
        title={gettext("Nothing is kept about visitors yet.")}
        description={
          if @kept.any?,
            do:
              gettext(
                "A profile is written when a visit starts. Declared bots are dropped before that unless “Record bot traffic” is on in Settings."
              ),
            else:
              gettext(
                "This page reads what Settings → “Who a visitor is” keeps: the address, the User-Agent, request headers, the network, device measurements. Switch on what you want to tell bots by."
              )
        }
      >
        <.link navigate={Paths.settings()} class="btn btn-primary btn-sm">
          {gettext("Open settings")}
        </.link>
      </.empty_state>

      <div :if={@total > 0} class="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <.stat_tile
          id="bots-stat-visitors"
          label={gettext("Visitors")}
          value={format_number(@summary.visitors)}
        >
          <:info>
            <p>
              {gettext(
                "Visitor IDs seen in this period that something is kept about. One person or bot is several of them when its address changes, or when the ID's period ends."
              )}
            </p>
          </:info>
        </.stat_tile>
        <.stat_tile
          id="bots-stat-likely"
          label={gettext("Likely bots")}
          value={format_number(@summary.likely)}
        >
          <:info>
            <p>
              {gettext("A score of %{score} or more: the reasons found add up to that.",
                score: BotScore.threshold(:likely)
              )}
            </p>
          </:info>
        </.stat_tile>
        <.stat_tile
          id="bots-stat-suspicious"
          label={gettext("Suspicious")}
          value={format_number(@summary.suspicious)}
        >
          <:info>
            <p>
              {gettext("A score from %{from} to %{to}: something is off, not enough to say.",
                from: BotScore.threshold(:suspicious),
                to: BotScore.threshold(:likely) - 1
              )}
            </p>
          </:info>
        </.stat_tile>
        <.stat_tile
          id="bots-stat-devices"
          label={gettext("Devices")}
          value={format_number(@summary.devices)}
          info_align="end"
        >
          <:info>
            <p>
              {gettext(
                "Distinct device hashes among them — the same machine keeps its hash when its address changes. Needs device measurements kept."
              )}
            </p>
          </:info>
        </.stat_tile>
      </div>

      <div :if={@total > 0} class="space-y-3">
        <div class="flex flex-wrap items-center gap-2">
          <div id="bots-views" role="tablist" class="tabs tabs-box tabs-sm">
            <.link
              :for={view <- @views}
              role="tab"
              patch={to(@filter, view, [])}
              class={["tab", @view == view && "tab-active"]}
            >
              {view_label(view)}
            </.link>
          </div>
          <.link
            :for={{key, label, value} <- @narrowed}
            patch={to(@filter, @view, [{key, nil}])}
            class="badge badge-neutral gap-1"
            title={gettext("Remove this filter")}
          >
            {label}: <span class="font-mono">{value}</span>
            <.icon name="hero-x-mark" class="h-3 w-3" />
          </.link>
        </div>

        <div
          :if={@view == :visitors}
          id="bots-visitors"
          class="overflow-x-auto rounded-xl border border-base-300 bg-base-100"
        >
          <table class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("Score")}</th>
                <th>{gettext("Visitor")}</th>
                <th>{gettext("Why")}</th>
                <th>{gettext("Last seen")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={visitor <- @visitors} id={"bot-#{visitor.visitor_id}"} class="align-top">
                <td><.bot_score_badge score={visitor.bot_score} /></td>
                <td class="max-w-md space-y-0.5">
                  <div class="flex flex-wrap items-baseline gap-x-2 font-mono text-xs">
                    <.link
                      :if={visitor.ip}
                      patch={to(@filter, :visitors, ip: visitor.ip)}
                      class="link-hover link"
                    >
                      {visitor.ip}
                    </.link>
                    <span :if={!visitor.ip} class="text-base-content/50">
                      {short(visitor.visitor_id)}
                    </span>
                    <.link
                      :if={visitor.device_hash}
                      patch={to(@filter, :visitors, device: visitor.device_hash)}
                      class="link-hover link text-base-content/60"
                      title={gettext("Device")}
                    >
                      <.icon name="hero-computer-desktop" class="h-3 w-3" />
                      {short(visitor.device_hash)}
                    </.link>
                  </div>
                  <div :if={visitor.asn || visitor.network} class="text-xs">
                    <.link
                      :if={visitor.asn}
                      patch={to(@filter, :visitors, asn: visitor.asn)}
                      class="link-hover link"
                    >
                      {network_label(visitor)}
                    </.link>
                    <span :if={!visitor.asn}>{network_label(visitor)}</span>
                    <span :if={visitor.hosting} class="badge badge-ghost badge-xs">
                      {gettext("hosting")}
                    </span>
                  </div>
                  <div
                    :if={visitor.user_agent}
                    class="truncate font-mono text-xs text-base-content/60"
                    title={visitor.user_agent}
                  >
                    {visitor.user_agent}
                  </div>
                </td>
                <td class="max-w-sm"><.bot_reasons reasons={visitor.bot_reasons} /></td>
                <td class="whitespace-nowrap text-xs tabular-nums">{seen(visitor.last_seen_at)}</td>
                <td>
                  <.link
                    :if={@sessions[visitor.visitor_id]}
                    navigate={Paths.session(@sessions[visitor.visitor_id])}
                    class="btn btn-ghost btn-xs"
                  >
                    {gettext("Latest visit")}
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@visitors == []} class="p-6 text-center text-sm text-base-content/60">
            {gettext("No visitors match.")}
          </p>
        </div>

        <div
          :if={@view != :visitors}
          id="bots-groups"
          class="overflow-x-auto rounded-xl border border-base-300 bg-base-100"
        >
          <table class="table table-sm">
            <thead>
              <tr>
                <th>{key_header(@view)}</th>
                <th class="text-right">{gettext("Visitors")}</th>
                <th class="text-right">{gettext("Likely bots")}</th>
                <th>{gettext("Highest score")}</th>
                <th>{gettext("Last seen")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={group <- @groups} class="align-top">
                <td class="max-w-lg">
                  <.link
                    patch={narrow_to(@filter, @view, group.key)}
                    class="link-hover link font-mono text-xs"
                  >
                    {group_title(@view, group)}
                  </.link>
                  <div
                    :if={group.label}
                    class={["truncate text-xs text-base-content/60", @view == :agent && "font-mono"]}
                    title={group.label}
                  >
                    {group.label}
                  </div>
                </td>
                <td class="text-right tabular-nums">{format_number(group.visitors)}</td>
                <td class="text-right tabular-nums">{format_number(group.likely)}</td>
                <td><.bot_score_badge score={group.top_score} /></td>
                <td class="whitespace-nowrap text-xs tabular-nums">{seen(group.last_seen_at)}</td>
              </tr>
            </tbody>
          </table>
          <p :if={@groups == []} class="p-6 text-center text-sm text-base-content/60">
            {gettext("Nothing to group by.")} {needs(@view)}
          </p>
        </div>

        <details
          :if={@firewall != ""}
          id="bots-firewall-list"
          class="rounded-xl border border-base-300 bg-base-100 p-4"
        >
          <summary class="cursor-pointer text-sm font-semibold">
            {gettext("As a list")}
          </summary>
          <p class="mt-2 text-xs text-base-content/60">
            {gettext(
              "The rows above with at least one likely bot, one per line — to paste into a firewall, a CDN rule or a deny list. Look before you block: a network or subnet holds more than the visitors seen here."
            )}
          </p>
          <textarea
            readonly
            rows="8"
            class="textarea mt-2 w-full font-mono text-xs"
            aria-label={gettext("As a list")}
          >{@firewall}</textarea>
        </details>
      </div>
    </div>
    """
  end
end
