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
  The exception is `click_id`: an ad platform's own identifier, kept when a
  visit lands with one, which is pseudonymous and links to the platform's
  user (see the README's Privacy section).
  `session_id` is stitched server-side by
  `PhoenixKitWebAnalytics.Collector`: an event reuses the visitor's previous
  session when the previous hit is inside the session window, otherwise it
  starts a new one.

  ## Event types

    * `"pageview"` — one HTML response served, or one LiveView navigation
    * `"event"` — a custom event reported through
      `PhoenixKitWebAnalytics.track_event/2` or the beacon endpoint
    * `"interaction"` — something the visitor did on a page: a LiveView event
      (`event_name` is the event, e.g. `"add_to_cart"`) or a click reported by
      the optional client script (`event_name` is `"click"`, `"outbound"` or
      `"download"`, `target` what was clicked)
    * `"leave"` — the visitor left a page; `engaged_ms` is how long it was
      open and `scroll_depth` (client script only) how far they scrolled

  Tables are created by `PhoenixKitWebAnalytics.Migrations`, never by this
  schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @event_types ~w(pageview event interaction leave)
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
    # An ad click's own identifier and the parameter that carried it (`gclid`,
    # `gbraid`, `msclkid`, …; `Tracking.click_source/1` names the platform). The
    # only mark a paid click leaves on the URL, and what a conversion is
    # reported back against.
    field(:click_id, :string)
    field(:click_param, :string)

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
    field(:engaged_ms, :integer)
    field(:scroll_depth, :integer)
    field(:target, :string)
    # The first hit of its visit — what the visits list pages through.
    field(:session_start, :boolean, default: false)
    # Bits of `PhoenixKitWebAnalytics.TrafficFlags`: the site's own people
    # and their networks. 0 is the audience.
    field(:traffic_flags, :integer, default: 0)

    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @castable ~w(
    event_type event_name site path page_title
    visitor_id session_id user_uuid
    referrer referrer_source referrer_medium
    utm_source utm_medium utm_campaign utm_term utm_content
    click_id click_param
    browser browser_version os os_version device_type language is_bot
    country_code region city status duration_ms engaged_ms scroll_depth target
    session_start traffic_flags metadata inserted_at
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
    |> strip_nul_bytes()
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
    |> truncate(:click_id, 255)
    |> truncate(:click_param, 20)
    |> truncate(:browser, 60)
    |> truncate(:browser_version, 30)
    |> truncate(:os, 60)
    |> truncate(:os_version, 30)
    |> truncate(:language, 20)
    |> truncate(:region, 120)
    |> truncate(:city, 120)
    |> truncate(:target, 512)
    |> clamp(:scroll_depth, 0, 100)
    |> clamp(:engaged_ms, 0, 24 * 60 * 60 * 1000)
    |> upcase_country_code()
  end

  # A custom event or interaction without a name would be indistinguishable in
  # every report.
  defp validate_event_name(changeset) do
    if get_field(changeset, :event_type) in ["event", "interaction"] do
      validate_required(changeset, [:event_name])
    else
      changeset
    end
  end

  # Never on a byte boundary inside a character: Postgres rejects the invalid
  # UTF-8 and the whole hit is lost.
  # PostgreSQL refuses a NUL byte in text and in a JSON string even though it
  # is valid UTF-8, and a hit is one insert: a `?utm_source=%00` would cost the
  # whole event. Nothing a NUL belongs in is a name or a path anyone reads.
  defp strip_nul_bytes(changeset) do
    Enum.reduce(changeset.changes, changeset, fn {field, value}, acc ->
      case scrub_nul(value) do
        ^value -> acc
        scrubbed -> put_change(acc, field, scrubbed)
      end
    end)
  end

  defp scrub_nul(value) when is_binary(value), do: String.replace(value, <<0>>, "")

  defp scrub_nul(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, inner} -> {scrub_nul(key), scrub_nul(inner)} end)

  defp scrub_nul(value) when is_list(value), do: Enum.map(value, &scrub_nul/1)
  defp scrub_nul(value), do: value

  defp truncate(changeset, field, max) do
    case get_change(changeset, field) do
      value when is_binary(value) and byte_size(value) > max ->
        put_change(changeset, field, PhoenixKitWebAnalytics.Tracking.truncate_utf8(value, max))

      _ ->
        changeset
    end
  end

  # Client-reported numbers are clamped rather than rejected, for the same
  # reason long strings are truncated.
  defp clamp(changeset, field, min, max) do
    case get_change(changeset, field) do
      value when is_integer(value) -> put_change(changeset, field, value |> max(min) |> min(max))
      _ -> changeset
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
