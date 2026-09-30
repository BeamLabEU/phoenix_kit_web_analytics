defmodule PhoenixKitWebAnalytics.Test.TrackedLive do
  @moduledoc """
  A stand-in for a host's public LiveView page, mounted with
  `PhoenixKitWebAnalytics.LiveHook` in the test router — the thing the hook's
  tests click, type into, and patch around.
  """

  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :count, 0)}

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("add_to_cart", _params, socket),
    do: {:noreply, update(socket, :count, &(&1 + 1))}

  def handle_event("validate", _params, socket), do: {:noreply, socket}
  def handle_event("save", _params, socket), do: {:noreply, socket}
  def handle_event("ping", _params, socket), do: {:noreply, socket}

  def handle_event("go", %{"to" => to}, socket), do: {:noreply, push_patch(socket, to: to)}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="tracked">
      <p>Count: {@count}</p>
      <button
        id="add"
        phx-click="add_to_cart"
        phx-value-tab="pricing"
        phx-value-email="secret@example.com"
      >
        Add
      </button>
      <button id="ping" phx-click="ping">Ping</button>
      <form id="contact" phx-change="validate" phx-submit="save">
        <input name="message" value="" />
        <button type="submit">Send</button>
      </form>
    </div>
    """
  end
end
