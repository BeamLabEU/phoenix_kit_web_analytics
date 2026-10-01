defmodule PhoenixKitWebAnalytics.Schemas.DailyStat do
  @moduledoc """
  One day of pre-aggregated totals per site — what survives after raw events
  are pruned.

  `PhoenixKitWebAnalytics.Retention` writes one row per (`date`, `site`) for
  completed days, then deletes raw events past the retention window. Reports
  read raw events when they are still there and fall back to these rows for
  older days, so the long-range trend line outlives the raw data.

  ## Adding days up

  `visitors` is a distinct count for that day — and it **does** add up across
  days, because the visitor ID itself changes every day (see
  `PhoenixKitWebAnalytics.Visitor`): nobody can be the same visitor on two
  days, so the sum over a range is exactly what a distinct count over the raw
  events would give. That is what lets reports read finished days from here.

  The per-day breakdowns (pages, referrers, …) are
  `PhoenixKitWebAnalytics.Schemas.DailyDim` rows.

  `site` is `""` (not `NULL`) when a hit had no host, so the unique index on
  (`date`, `site`) actually constrains those rows.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_web_analytics_daily_stats" do
    field(:date, :date)
    field(:site, :string, default: "")

    field(:pageviews, :integer, default: 0)
    field(:visitors, :integer, default: 0)
    field(:sessions, :integer, default: 0)
    field(:bounces, :integer, default: 0)
    field(:events, :integer, default: 0)
    field(:total_session_seconds, :integer, default: 0)
    field(:exits, :integer, default: 0)
    field(:engaged_ms_sum, :integer, default: 0)
    field(:engaged_count, :integer, default: 0)
    field(:scroll_sum, :integer, default: 0)
    field(:scroll_count, :integer, default: 0)
    field(:duration_ms_sum, :integer, default: 0)
    field(:duration_count, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(date site pageviews visitors sessions bounces events total_session_seconds
               exits engaged_ms_sum engaged_count scroll_sum scroll_count duration_ms_sum
               duration_count)a

  @doc "Changeset for a daily rollup row."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(stat, attrs) do
    stat
    |> cast(attrs, @castable)
    |> validate_required([:date])
    |> put_default_site()
    |> validate_number(:pageviews, greater_than_or_equal_to: 0)
    |> validate_number(:visitors, greater_than_or_equal_to: 0)
    |> validate_number(:sessions, greater_than_or_equal_to: 0)
    |> validate_number(:bounces, greater_than_or_equal_to: 0)
    |> validate_number(:events, greater_than_or_equal_to: 0)
    |> validate_number(:total_session_seconds, greater_than_or_equal_to: 0)
    |> unique_constraint([:date, :site])
  end

  defp put_default_site(changeset) do
    case get_field(changeset, :site) do
      nil -> put_change(changeset, :site, "")
      _ -> changeset
    end
  end

  @doc """
  Average session length in seconds, or `nil` when the day recorded no
  sessions.
  """
  @spec avg_session_seconds(t()) :: float() | nil
  def avg_session_seconds(%__MODULE__{sessions: sessions}) when sessions in [0, nil], do: nil

  def avg_session_seconds(%__MODULE__{sessions: sessions, total_session_seconds: total}),
    do: total / sessions

  @doc """
  Bounce rate as a percentage, or `nil` when the day recorded no sessions.
  """
  @spec bounce_rate(t()) :: float() | nil
  def bounce_rate(%__MODULE__{sessions: sessions}) when sessions in [0, nil], do: nil

  def bounce_rate(%__MODULE__{sessions: sessions, bounces: bounces}),
    do: bounces * 100 / sessions
end
