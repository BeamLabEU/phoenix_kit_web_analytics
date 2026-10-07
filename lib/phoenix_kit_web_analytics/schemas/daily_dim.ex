defmodule PhoenixKitWebAnalytics.Schemas.DailyDim do
  @moduledoc """
  One day of one breakdown value per site — "`/pricing` had 812 views from
  640 visitors on 2026-09-30", "Google sent 212 views".

  Written by `PhoenixKitWebAnalytics.Retention` for finished days, read by
  `PhoenixKitWebAnalytics.Reports`, so a breakdown over a month reads a few
  thousand rows instead of every raw event. Like `DailyStat`, the `visitors`
  of different days add up exactly, because the visitor ID changes daily.

  `dimension` is one of the names defined by the shared dimensions module. `detail`
  is a second key where the value alone isn't enough (an interaction's
  target); it is `""` otherwise. For the `page` dimension the engagement
  columns carry that page's exits, time on page, scroll depth and server
  response times.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_web_analytics_daily_dims" do
    field(:date, :date)
    field(:site, :string, default: "")
    field(:dimension, :string)
    field(:value, :string)
    field(:detail, :string, default: "")

    field(:hits, :integer, default: 0)
    field(:visitors, :integer, default: 0)
    field(:exits, :integer, default: 0)
    field(:exit_visitors, :integer, default: 0)
    field(:engaged_ms_sum, :integer, default: 0)
    field(:engaged_count, :integer, default: 0)
    field(:scroll_sum, :integer, default: 0)
    field(:scroll_count, :integer, default: 0)
    field(:duration_ms_sum, :integer, default: 0)
    field(:duration_count, :integer, default: 0)
    field(:duration_max, :integer, default: 0)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
