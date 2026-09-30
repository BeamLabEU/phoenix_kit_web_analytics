defmodule PhoenixKitWebAnalytics.Web.SessionLive do
  @moduledoc """
  One visit, replayed — every page view, interaction, custom event and exit,
  in order, with the time since the visit began. The summary on top says who
  (a signed-in user's name, otherwise anonymous), where from, on what, and for
  how long.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  require Logger

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Web.UserNames

  # Long visits (a bot, a tab left on an auto-refreshing page) can hold
  # thousands of events; the timeline shows them 500 at a time.
  @page 500
  # Each "Show more" reloads from the start, so the list stops growing here.
  @max_show 5_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Visit"))}
  end

  @impl true
  def handle_params(%{"session_id" => session_id} = params, _uri, socket) do
    show = show_param(params["show"])
    rows = Reports.session_timeline(session_id, limit: show + 1)
    {events, rest} = Enum.split(rows, show)
    user_uuid = Enum.find_value(events, & &1.user_uuid)

    {:noreply,
     socket
     |> assign(:session_id, session_id)
     |> assign(:events, events)
     |> assign(
       :first,
       List.first(Enum.filter(events, &(&1.event_type == "pageview"))) || List.first(events)
     )
     |> assign(:user_uuid, user_uuid)
     |> assign(:user_name, user_uuid && Map.get(UserNames.for_uuids([user_uuid]), user_uuid))
     |> assign(:show, show)
     |> assign(:more?, rest != [])
     |> assign(:max_show, @max_show)
     |> assign(:summary, Reports.session_summary(session_id))}
  end

  @impl true
  def handle_info(message, socket) do
    Logger.debug("[WebAnalytics] SessionLive ignored #{inspect(message)}")
    {:noreply, socket}
  end

  defp show_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> min(n, @max_show)
      _ -> @page
    end
  end

  defp show_param(_value), do: @page

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl space-y-6 px-4 py-6">
      <.link navigate={Paths.sessions()} class="btn btn-ghost btn-sm">
        <.icon name="hero-arrow-left" class="h-4 w-4" /> {gettext("Visits")}
      </.link>

      <.empty_state
        :if={@events == []}
        variant="card"
        title={gettext("This visit isn't here.")}
        description={gettext("It may have been pruned by retention, or the link is wrong.")}
        icon="hero-magnifying-glass"
      />

      <div :if={@summary} class="rounded-xl border border-base-300 bg-base-100 p-4">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h2 class="text-lg font-semibold">
              {if @user_uuid,
                do: @user_name || gettext("Signed-in user"),
                else: gettext("Anonymous visitor")}
            </h2>
            <p class="text-sm text-base-content/60">
              {Calendar.strftime(@summary.started, "%Y-%m-%d %H:%M:%S")} UTC
            </p>
            <.link
              :if={@user_uuid}
              navigate={Paths.sessions_for_user(@user_uuid)}
              class="text-sm text-primary hover:underline"
            >
              {gettext("All visits by this user")}
            </.link>
          </div>
          <div class="grid grid-cols-3 gap-4 text-center">
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/50">
                {gettext("Duration")}
              </div>
              <div class="text-lg font-semibold tabular-nums">
                {format_duration(@summary.seconds)}
              </div>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/50">
                {gettext("Pages")}
              </div>
              <div class="text-lg font-semibold tabular-nums">{@summary.pageviews}</div>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/50">
                {gettext("Actions")}
              </div>
              <div class="text-lg font-semibold tabular-nums">{@summary.actions}</div>
            </div>
          </div>
        </div>

        <dl :if={@first} class="mt-4 grid grid-cols-1 gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
          <.fact
            label={gettext("Came from")}
            value={@first.referrer_source || channel_label(@first.referrer_medium)}
          />
          <.fact label={gettext("Referrer")} value={@first.referrer} mono />
          <.fact label={gettext("Campaign")} value={@first.utm_campaign} />
          <.fact label={gettext("Landed on")} value={@first.path} mono />
          <.fact
            label={gettext("Device")}
            value={
              Enum.join(
                Enum.reject([@first.browser, @first.os, device_label(@first.device_type)], &is_nil/1),
                " · "
              )
            }
          />
          <.fact label={gettext("Language")} value={@first.language} />
          <.fact label={gettext("Country")} value={@first.country_code} />
          <.fact
            label={gettext("Furthest scroll")}
            value={@summary.max_scroll && "#{@summary.max_scroll}%"}
          />
        </dl>
      </div>

      <ol :if={@events != []} class="relative space-y-0 border-l border-base-300 pl-6">
        <li :for={event <- @events} class="relative pb-4">
          <span class="absolute -left-[1.85rem] top-1 flex h-3 w-3 items-center justify-center rounded-full bg-base-100 ring-2 ring-base-300"></span>
          <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <span class="w-14 shrink-0 text-xs tabular-nums text-base-content/50">
              +{format_offset(DateTime.diff(event.inserted_at, @summary.started))}
            </span>
            <span class="text-sm"><.hit_summary hit={event} /></span>
            <span class="font-mono text-xs text-base-content/60">{event.path}</span>
          </div>
        </li>
      </ol>

      <p :if={@more? and @show >= @max_show} class="text-center text-xs text-base-content/50">
        {gettext("Showing the first %{count} events of this visit.", count: format_number(@max_show))}
      </p>

      <div :if={@more? and @show < @max_show} class="flex justify-center">
        <.link
          patch={Paths.session(@session_id) <> "?show=#{min(@show + 500, @max_show)}"}
          class="btn btn-ghost btn-sm"
        >
          {gettext("Show more")}
        </.link>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false

  defp fact(assigns) do
    ~H"""
    <div :if={@value not in [nil, ""]} class="flex gap-2">
      <dt class="w-32 shrink-0 text-base-content/50">{@label}</dt>
      <dd
        class={["min-w-0 truncate", @mono && "font-mono text-xs leading-5"]}
        title={to_string(@value)}
      >
        {@value}
      </dd>
    </div>
    """
  end

  defp format_offset(seconds) when seconds < 3600 do
    "#{div(seconds, 60)}:#{String.pad_leading(Integer.to_string(rem(seconds, 60)), 2, "0")}"
  end

  defp format_offset(seconds) do
    "#{div(seconds, 3600)}:#{String.pad_leading(Integer.to_string(div(rem(seconds, 3600), 60)), 2, "0")}:#{String.pad_leading(Integer.to_string(rem(seconds, 60)), 2, "0")}"
  end
end
