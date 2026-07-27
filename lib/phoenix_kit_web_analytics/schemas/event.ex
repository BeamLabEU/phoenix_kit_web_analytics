defmodule PhoenixKitWebAnalytics.Schemas.Event do
  @moduledoc """
  One analytics hit — a page view or a custom event.

  Rows are append-only: there is no `updated_at` and nothing ever updates an
  event after insert. `PhoenixKitWebAnalytics.Retention` rolls old rows into
  `PhoenixKitWebAnalytics.Schemas.DailyStat` and deletes them.

  ## Identity is cookieless

  There is no cookie, no local storage, and no raw IP address in this table.
  `visitor_id` is a truncated SHA-256 of `salt <> ip <> user_agent <> date`
  (see `PhoenixKitWebAnalytics.Visitor`) — it cannot be reversed to an IP, it
  cannot be joined across days, and it changes when the daily salt rotates.
  `session_id` is stitched server-side by
  `PhoenixKitWebAnalytics.Collector`: an event reuses the visitor's previous
  session when the previous hit is inside the session window, otherwise it
  starts a new one.

  ## Event types

    * `"pageview"` — one HTML response served, or one LiveView navigation
    * `"event"` — a custom event reported through
      `PhoenixKitWebAnalytics.track_event/2` or the beacon endpoint

  Tables are created by `PhoenixKitWebAnalytics.Migrations`, never by this
  schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @event_types ~w(pageview event)
  @device_types ~w(desktop mobile tablet bot unknown)
  @referrer_mediums ~w(none organic social referral internal email paid)

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_web_analytics_events" do
    field(:event_type, :string, default: "pageview")
    field(:event_name, :string)
    field(:site, :string)
    field(:path, :string)
    field(:page_title, :string)

    field(:visitor_id, :string)
    field(:session_id, UUIDv7)
    field(:user_uuid, UUIDv7)

    field(:referrer, :string)
    field(:referrer_source, :string)
    field(:referrer_medium, :string)
    field(:utm_source, :string)
    field(:utm_medium, :string)
    field(:utm_campaign, :string)
    field(:utm_term, :string)
    field(:utm_content, :string)

    field(:browser, :string)
    field(:browser_version, :string)
    field(:os, :string)
    field(:os_version, :string)
    field(:device_type, :string)
    field(:language, :string)
    field(:is_bot, :boolean, default: false)

    field(:country_code, :string)
    field(:region, :string)
    field(:city, :string)

    field(:status, :integer)
    field(:duration_ms, :integer)

    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @castable ~w(
    event_type event_name site path page_title
    visitor_id session_id user_uuid
    referrer referrer_source referrer_medium
    utm_source utm_medium utm_campaign utm_term utm_content
    browser browser_version os os_version device_type language is_bot
    country_code region city status duration_ms metadata inserted_at
  )a

  @doc "Valid `event_type` values."
  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  @doc "Valid `device_type` values."
  @spec device_types() :: [String.t()]
  def device_types, do: @device_types

  @doc "Valid `referrer_medium` values."
  @spec referrer_mediums() :: [String.t()]
  def referrer_mediums, do: @referrer_mediums

  @doc """
  Changeset for a single hit.

  Long free-text fields are truncated rather than rejected — an over-long
  `page_title` or referrer from the wild must never cost us the whole event.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @castable)
    |> validate_required([:event_type, :path, :visitor_id, :session_id])
    |> validate_inclusion(:event_type, @event_types)
    |> validate_inclusion(:device_type, @device_types)
    |> validate_inclusion(:referrer_medium, @referrer_mediums)
    |> validate_event_name()
    |> truncate(:path, 2048)
    |> truncate(:page_title, 512)
    |> truncate(:referrer, 2048)
    |> truncate(:site, 255)
    |> truncate(:event_name, 120)
    |> truncate(:referrer_source, 120)
    |> truncate(:utm_source, 255)
    |> truncate(:utm_medium, 255)
    |> truncate(:utm_campaign, 255)
    |> truncate(:utm_term, 255)
    |> truncate(:utm_content, 255)
    |> truncate(:browser, 60)
    |> truncate(:browser_version, 30)
    |> truncate(:os, 60)
    |> truncate(:os_version, 30)
    |> truncate(:language, 20)
    |> truncate(:region, 120)
    |> truncate(:city, 120)
    |> upcase_country_code()
  end

  # A custom event without a name would be indistinguishable in every report.
  defp validate_event_name(changeset) do
    if get_field(changeset, :event_type) == "event" do
      validate_required(changeset, [:event_name])
    else
      changeset
    end
  end

  defp truncate(changeset, field, max) do
    case get_change(changeset, field) do
      value when is_binary(value) and byte_size(value) > max ->
        put_change(changeset, field, binary_part(value, 0, max))

      _ ->
        changeset
    end
  end

  defp upcase_country_code(changeset) do
    case get_change(changeset, :country_code) do
      code when is_binary(code) ->
        put_change(changeset, :country_code, code |> String.upcase() |> String.slice(0, 2))

      _ ->
        changeset
    end
  end
end
