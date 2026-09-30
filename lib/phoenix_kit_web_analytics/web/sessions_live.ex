defmodule PhoenixKitWebAnalytics.Web.SessionsLive do
  @moduledoc """
  Sessions — every visit in the period, newest first: who (a signed-in user's
  name, otherwise anonymous), where they landed and where they left, how many
  pages, how many actions, how long, and where they came from. Each opens the
  visit's full timeline.

  `?user=<uuid>` narrows the list to one signed-in user's visits — their
  journey across the site over the period.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  require Logger

  import PhoenixKitWebAnalytics.Web.Components

  alias PhoenixKitWebAnalytics.Paths
  alias PhoenixKitWebAnalytics.Reports
  alias PhoenixKitWebAnalytics.Web.Filters
  alias PhoenixKitWebAnalytics.Web.UserNames

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Sessions"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> Filters.assign_filter(params)
     |> assign(:user_uuid, uuid_param(params["user"]))
     |> assign(:before, before_param(params["before"]))
     |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    params = Map.put(params, "user", socket.assigns.user_uuid)
    {:noreply, push_patch(socket, to: patch_path(params))}
  end

  @impl true
  def handle_info(message, socket) do
    Logger.debug("[WebAnalytics] SessionsLive ignored #{inspect(message)}")
    {:noreply, socket}
  end

  defp load(socket) do
    sessions =
      Reports.sessions(socket.assigns.filter,
        limit: @page_size,
        user_uuid: socket.assigns.user_uuid,
        before: socket.assigns.before
      )

    names = UserNames.for_uuids([socket.assigns.user_uuid | Enum.map(sessions, & &1.user_uuid)])

    socket
    |> assign(:sessions, sessions)
    |> assign(:names, names)
    |> assign(:more?, length(sessions) == @page_size)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl space-y-6 px-4 py-6">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <p class="text-sm text-base-content/60">
          <%= if @user_uuid do %>
            {gettext("Visits by %{name}.", name: Map.get(@names, @user_uuid, gettext("a signed-in user")))}
            <.link patch={patch_path(%{"period" => @period, "site" => @site})} class="link">
              {gettext("Show everyone")}
            </.link>
          <% else %>
            {gettext("Every visit, newest first. Open one to see everything that visitor did.")}
          <% end %>
        </p>
        <.filter_bar
          period={@period}
          site={@site}
          sites={@sites}
          path={@path}
          base_path={Paths.sessions()}
        />
      </div>

      <div class="rounded-xl border border-base-300 bg-base-100">
        <.sessions_table
          id="web-analytics-sessions"
          sessions={@sessions}
          names={@names}
          empty_message={gettext("No visits in this period.")}
        />
      </div>

      <div :if={@more? or @before} class="flex justify-between">
        <.link
          :if={@before}
          patch={patch_path(%{"period" => @period, "site" => @site, "user" => @user_uuid})}
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-arrow-left" class="h-4 w-4" /> {gettext("Newest")}
        </.link>
        <span :if={is_nil(@before)}></span>
        <.link
          :if={@more?}
          patch={
            patch_path(%{
              "period" => @period,
              "site" => @site,
              "user" => @user_uuid,
              "before" => @sessions |> List.last() |> Map.fetch!(:started_at) |> to_iso()
            })
          }
          class="btn btn-ghost btn-sm"
        >
          {gettext("Older visits")} <.icon name="hero-arrow-right" class="h-4 w-4" />
        </.link>
      </div>
    </div>
    """
  end

  defp patch_path(params) do
    base = Filters.patch_to(Paths.sessions(), params)

    extra =
      params
      |> Map.take(["user", "before"])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    case {extra, String.contains?(base, "?")} do
      {[], _} -> base
      {extra, true} -> base <> "&" <> URI.encode_query(extra)
      {extra, false} -> base <> "?" <> URI.encode_query(extra)
    end
  end

  defp uuid_param(value) do
    case Ecto.UUID.cast(value || "") do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp before_param(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp before_param(_value), do: nil

  defp to_iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp to_iso(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
end
