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
  """
  @spec aggregate(Ecto.Queryable.t(), String.t()) :: Ecto.Query.t()
  def aggregate(query, dimension) when dimension in @names do
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
          fragment("COUNT(DISTINCT ?) FILTER (WHERE ? = 'leave')", e.visitor_id, e.event_type)
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
          fragment("COUNT(DISTINCT ?) FILTER (WHERE ? = 'pageview')", e.visitor_id, e.event_type),
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
        fragment("COUNT(DISTINCT ?) FILTER (WHERE ? = 'pageview')", e.visitor_id, e.event_type)
      )

  defp visitors(_dimension), do: dynamic([e], count(e.visitor_id, :distinct))
end
