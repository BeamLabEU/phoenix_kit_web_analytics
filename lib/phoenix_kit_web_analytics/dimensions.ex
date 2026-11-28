defmodule PhoenixKitWebAnalytics.Dimensions do
  @moduledoc false
  # Every breakdown the reports show, defined once. The daily rollup
  # (`Retention`) runs `aggregate/2` over one finished day and stores the rows
  # as `DailyDim`; `Reports` runs the very same query over the raw events not
  # rolled up yet (today) and adds the two. One definition, so a finished day
  # and today can never be counted differently.
  #
  # `aggregate/2` groups an Event query (already cut to a window) by site,
  # value and detail, and selects the same metric columns `DailyDim` stores.

  import Ecto.Query

  @names ~w(page referrer channel campaign utm_source browser os device language country event interaction)

  @doc "Every dimension name."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc """
  One row per (site, value, detail) for `dimension` over `query`:
  `%{site, value, detail, hits, visitors, exits, exit_visitors,
  engaged_ms_sum, engaged_count, scroll_sum, scroll_count, duration_ms_sum,
  duration_count, duration_max}`.

  `limit: n` keeps the `n` most visited values (by hits, then exits).
  """
  @spec aggregate(Ecto.Queryable.t(), String.t(), keyword()) :: Ecto.Query.t()
  def aggregate(query, dimension, opts \\ []) when dimension in @names do
    value = value(dimension)
    detail = detail(dimension)

    site = dynamic([e], fragment("COALESCE(?, '')", e.site))

    # Built as dynamics throughout: Ecto accepts a map of dynamics as the
    # whole select, but not a dynamic inside a literal select map.
    fields = %{
      site: site,
      value: value,
      detail: detail,
      hits: hits(dimension),
      visitors: visitors(dimension),
      exits: dynamic([e], fragment("COUNT(*) FILTER (WHERE ? = 'leave')", e.event_type)),
      exit_visitors:
        dynamic(
          [e],
          fragment(
            "COUNT(DISTINCT (?, ?::date)) FILTER (WHERE ? = 'leave')",
            e.visitor_id,
            e.inserted_at,
            e.event_type
          )
        ),
      engaged_ms_sum:
        dynamic(
          [e],
          fragment("COALESCE(SUM(?) FILTER (WHERE ? = 'leave'), 0)", e.engaged_ms, e.event_type)
        ),
      engaged_count:
        dynamic([e], fragment("COUNT(?) FILTER (WHERE ? = 'leave')", e.engaged_ms, e.event_type)),
      scroll_sum: dynamic([e], fragment("COALESCE(SUM(?), 0)", e.scroll_depth)),
      scroll_count: dynamic([e], count(e.scroll_depth)),
      duration_ms_sum:
        dynamic(
          [e],
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE ? = 'pageview'), 0)",
            e.duration_ms,
            e.event_type
          )
        ),
      duration_count:
        dynamic(
          [e],
          fragment("COUNT(?) FILTER (WHERE ? = 'pageview')", e.duration_ms, e.event_type)
        ),
      duration_max:
        dynamic(
          [e],
          fragment(
            "COALESCE(MAX(?) FILTER (WHERE ? = 'pageview'), 0)",
            e.duration_ms,
            e.event_type
          )
        )
    }

    query
    |> restrict(dimension)
    |> group_by(^[site, value, detail])
    |> select(^fields)
    |> top(Keyword.get(opts, :limit), fields)
  end

  defp top(query, nil, _fields), do: query

  defp top(query, limit, fields) do
    query
    |> order_by(^[desc: fields.hits, desc: fields.exits])
    |> limit(^limit)
  end

  @doc """
  The headline totals per site over `query`: `%{site, pageviews, visitors,
  events, exits, engaged_ms_sum, engaged_count, scroll_sum, scroll_count,
  duration_ms_sum, duration_count}` — the non-session columns of `DailyStat`.
  """
  @spec totals(Ecto.Queryable.t()) :: Ecto.Query.t()
  def totals(query) do
    from(e in query,
      group_by: fragment("COALESCE(?, '')", e.site),
      select: %{
        site: fragment("COALESCE(?, '')", e.site),
        pageviews: fragment("COUNT(*) FILTER (WHERE ? = 'pageview')", e.event_type),
        visitors:
          fragment(
            "COUNT(DISTINCT (?, ?::date)) FILTER (WHERE ? = 'pageview')",
            e.visitor_id,
            e.inserted_at,
            e.event_type
          ),
        events: fragment("COUNT(*) FILTER (WHERE ? = 'event')", e.event_type),
        exits: fragment("COUNT(*) FILTER (WHERE ? = 'leave')", e.event_type),
        engaged_ms_sum:
          fragment("COALESCE(SUM(?) FILTER (WHERE ? = 'leave'), 0)", e.engaged_ms, e.event_type),
        engaged_count:
          fragment("COUNT(?) FILTER (WHERE ? = 'leave')", e.engaged_ms, e.event_type),
        scroll_sum: fragment("COALESCE(SUM(?), 0)", e.scroll_depth),
        scroll_count: count(e.scroll_depth),
        duration_ms_sum:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE ? = 'pageview'), 0)",
            e.duration_ms,
            e.event_type
          ),
        duration_count:
          fragment("COUNT(?) FILTER (WHERE ? = 'pageview')", e.duration_ms, e.event_type)
      }
    )
  end

  @doc """
  Automated traffic per (site, reason, bot name) over `query`: `%{site,
  reason, bot_name, hits, pageviews, visits, visitors}` — what
  `DailyBot` stores, so a rolled-up day and the raw remainder count bots
  alike. Only bot rows, never an `"api"` event. `reason` is the row's
  `metadata["bot"]`, or `"user_agent"` for a bot that declared itself.

  Legacy event metadata is restricted to recognized labels before aggregation.
  """
  @spec bots(Ecto.Queryable.t()) :: Ecto.Query.t()
  def bots(query) do
    # Older custom-event metadata could contain arbitrary values for both
    # keys. Classify it before grouping so it cannot enter permanent rollups.
    labels = PhoenixKitWebAnalytics.UserAgent.bot_labels()

    classified =
      from(e in query,
        where: e.is_bot and e.event_type != "api",
        select: %{
          site: fragment("COALESCE(?, '')", e.site),
          reason:
            fragment(
              "CASE WHEN ?->>'bot' IN ('no_js', 'rate', 'webdriver', 'prefetch') THEN ?->>'bot' ELSE 'user_agent' END",
              e.metadata,
              e.metadata
            ),
          bot_name:
            fragment(
              "CASE WHEN ?->>'bot_name' = ANY(?) THEN ?->>'bot_name' ELSE '' END",
              e.metadata,
              type(^labels, {:array, :string}),
              e.metadata
            ),
          uuid: e.uuid,
          event_type: e.event_type,
          session_id: e.session_id,
          visitor_id: e.visitor_id,
          inserted_at: e.inserted_at
        }
      )

    from(e in subquery(classified),
      group_by: [e.site, e.reason, e.bot_name],
      select: %{
        site: e.site,
        reason: e.reason,
        bot_name: e.bot_name,
        hits: count(e.uuid),
        pageviews: fragment("COUNT(*) FILTER (WHERE ? = 'pageview')", e.event_type),
        visits: fragment("COUNT(DISTINCT (?, ?::date))", e.session_id, e.inserted_at),
        visitors: fragment("COUNT(DISTINCT (?, ?::date))", e.visitor_id, e.inserted_at)
      }
    )
  end

  @doc """
  Automated traffic per site over every rule at once — the same columns as
  `bots/1`, with `reason` `"*"` and no bot name — so a visit two rules
  judged is one visit here. `DailyBot` stores it beside the per-rule rows;
  the "judged automated" totals read it.
  """
  @spec bots_total(Ecto.Queryable.t()) :: Ecto.Query.t()
  def bots_total(query) do
    from(e in query,
      where: e.is_bot and e.event_type != "api",
      group_by: fragment("COALESCE(?, '')", e.site),
      select: %{
        site: fragment("COALESCE(?, '')", e.site),
        reason: fragment("'*'::text"),
        bot_name: fragment("''::text"),
        hits: count(e.uuid),
        pageviews: fragment("COUNT(*) FILTER (WHERE ? = 'pageview')", e.event_type),
        visits: fragment("COUNT(DISTINCT (?, ?::date))", e.session_id, e.inserted_at),
        visitors: fragment("COUNT(DISTINCT (?, ?::date))", e.visitor_id, e.inserted_at)
      }
    )
  end

  # Which events a dimension is made of — the same rules the reports always
  # applied (internal navigation is never a referrer or a channel, …).
  defp restrict(query, "page"),
    do: where(query, [e], e.event_type in ["pageview", "leave", "interaction"])

  defp restrict(query, "referrer") do
    where(
      query,
      [e],
      e.event_type == "pageview" and not is_nil(e.referrer_source) and
        e.referrer_medium not in ["internal", "none"]
    )
  end

  defp restrict(query, "channel") do
    where(
      query,
      [e],
      e.event_type == "pageview" and
        (is_nil(e.referrer_medium) or e.referrer_medium != "internal")
    )
  end

  defp restrict(query, "campaign"),
    do: where(query, [e], e.event_type == "pageview" and not is_nil(e.utm_campaign))

  defp restrict(query, "utm_source"),
    do: where(query, [e], e.event_type == "pageview" and not is_nil(e.utm_source))

  defp restrict(query, "language"),
    do: where(query, [e], e.event_type == "pageview" and not is_nil(e.language))

  defp restrict(query, "country"),
    do: where(query, [e], e.event_type == "pageview" and not is_nil(e.country_code))

  defp restrict(query, "event"),
    do: where(query, [e], e.event_type == "event" and not is_nil(e.event_name))

  defp restrict(query, "interaction"),
    do: where(query, [e], e.event_type == "interaction" and e.event_name != "scroll")

  defp restrict(query, dimension) when dimension in ["browser", "os", "device"],
    do: where(query, [e], e.event_type == "pageview")

  defp value("page"), do: dynamic([e], e.path)
  defp value("referrer"), do: dynamic([e], e.referrer_source)
  defp value("channel"), do: dynamic([e], fragment("COALESCE(?, 'none')", e.referrer_medium))
  defp value("campaign"), do: dynamic([e], e.utm_campaign)
  defp value("utm_source"), do: dynamic([e], e.utm_source)
  defp value("browser"), do: dynamic([e], fragment("COALESCE(?, 'Unknown')", e.browser))
  defp value("os"), do: dynamic([e], fragment("COALESCE(?, 'Unknown')", e.os))
  defp value("device"), do: dynamic([e], fragment("COALESCE(?, 'unknown')", e.device_type))
  defp value("language"), do: dynamic([e], e.language)
  defp value("country"), do: dynamic([e], e.country_code)
  defp value("event"), do: dynamic([e], e.event_name)
  defp value("interaction"), do: dynamic([e], e.event_name)

  defp detail("interaction"), do: dynamic([e], fragment("COALESCE(?, '')", e.target))
  defp detail(_dimension), do: dynamic([e], fragment("''::text"))

  # A page's hits are its page views (its rows also carry leaves and scroll
  # reports); every other dimension is already cut to the rows it counts.
  defp hits("page"),
    do: dynamic([e], fragment("COUNT(*) FILTER (WHERE ? = 'pageview')", e.event_type))

  defp hits(_dimension), do: dynamic([e], count(e.uuid))

  defp visitors("page"),
    do:
      dynamic(
        [e],
        fragment(
          "COUNT(DISTINCT (?, ?::date)) FILTER (WHERE ? = 'pageview')",
          e.visitor_id,
          e.inserted_at,
          e.event_type
        )
      )

  defp visitors(_dimension),
    do: dynamic([e], fragment("COUNT(DISTINCT (?, ?::date))", e.visitor_id, e.inserted_at))
end
