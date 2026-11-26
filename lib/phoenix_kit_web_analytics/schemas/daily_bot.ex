defmodule PhoenixKitWebAnalytics.Schemas.DailyBot do
  @moduledoc """
  One day of automated traffic per site, rule and bot — "GPTBot fetched 340
  pages in 12 visits on 2026-10-04", "the no-JavaScript rule took out 9
  visits".

  Written by `PhoenixKitWebAnalytics.Retention` beside `DailyStat` and
  `DailyDim` (which hold only traffic that isn't a bot's), so bot volume
  survives the raw events' retention like the rest of the trend.

    * `reason` — which rule judged the traffic automated: the
      `metadata["bot"]` an event carries (`"no_js"`, `"webdriver"`,
      `"rate"`, `"prefetch"`), or `"user_agent"` for a bot that says so in
      its User-Agent.
    * `bot_name` — the short name a declared bot gives
      (`PhoenixKitWebAnalytics.UserAgent.bot_name/1`), `""` when there is
      none (a behavioural verdict on a browser's User-Agent).
    * `reason` `"*"` (with no bot name) is the day's total over every rule
      at once (`PhoenixKitWebAnalytics.Dimensions.bots_total/1`): a visit
      two rules judged is one visit there.
    * `visits` and `visitors` count distinct visits and visitors per UTC day,
      so days add up the way `DailyStat`'s do.

  Like the other rollups, it holds only traffic without a
  `PhoenixKitWebAnalytics.TrafficFlags` bit, and no `"api"` events.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_web_analytics_daily_bots" do
    field(:date, :date)
    field(:site, :string, default: "")
    field(:reason, :string)
    field(:bot_name, :string, default: "")
    field(:hits, :integer, default: 0)
    field(:pageviews, :integer, default: 0)
    field(:visits, :integer, default: 0)
    field(:visitors, :integer, default: 0)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
