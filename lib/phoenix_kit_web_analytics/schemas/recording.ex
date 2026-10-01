defmodule PhoenixKitWebAnalytics.Schemas.Recording do
  @moduledoc """
  One chunk of a session recording — a few seconds of one page view: where
  the pointer went, what was clicked and hovered, how the page scrolled.

  Written by `PhoenixKitWebAnalytics.Recordings` from what the optional
  client script sends while recording is on; a page view is the chunks
  sharing a `page_key`, in `seq` order. `frames` is
  `%{"v" => 1, "f" => [[ms_since_page_start, type, ...], ...]}` — the format
  is documented in `PhoenixKitWebAnalytics.Recordings`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_web_analytics_recordings" do
    field(:session_id, Ecto.UUID)
    field(:page_key, :string)
    field(:seq, :integer)
    field(:path, :string)
    field(:site, :string)
    field(:viewport_w, :integer)
    field(:viewport_h, :integer)
    field(:frames, :map)
    field(:frame_count, :integer, default: 0)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
