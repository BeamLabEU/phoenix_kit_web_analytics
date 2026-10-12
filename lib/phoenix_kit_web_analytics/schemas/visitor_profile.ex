defmodule PhoenixKitWebAnalytics.Schemas.VisitorProfile do
  @moduledoc """
  What is kept about who a visitor is — one row per visitor ID.

  Every column but the ID and the two times is optional, and each is filled
  only while its setting is on (`PhoenixKitWebAnalytics.Profiles`). With all
  of them off — the default — no row is written at all.

  A visitor ID is a hash of the address and the User-Agent
  (`PhoenixKitWebAnalytics.Visitor`), so one ID has one of each: they are
  stored here once rather than on every event.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_web_analytics_visitor_profiles" do
    field(:visitor_id, :string)
    # Whole, or its network in CIDR form — as `web_analytics_store_ip` says.
    field(:ip, :string)
    field(:user_agent, :string)
    # %{"http" => _, "names" => [_], "values" => %{_ => _}} — see Profiles.
    field(:headers, :map)
    # Who runs the visitor's network, from the geo resolver.
    field(:asn, :integer)
    field(:network, :string)
    field(:hosting, :boolean)
    # Device measurements from the client script, and a hash of them.
    field(:signals, :map)
    field(:device_hash, :string)
    # When the visitor's latest visit started.
    field(:last_seen_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
