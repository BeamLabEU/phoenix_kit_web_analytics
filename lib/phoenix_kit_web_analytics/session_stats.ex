defmodule PhoenixKitWebAnalytics.SessionStats do
  @moduledoc false
  # The per-session facts behind bounce rate and session length, shared by the
  # live reports and the daily rollup so the two can never define a session
  # differently.
  #
  #   * a session counts only if it has at least one page view — a session made
  #     of nothing but a late "leave" or a server-side custom event isn't a
  #     visit anyone made;
  #   * `hits` is its page-view count, so a bounce is `hits == 1`;
  #   * `seconds` is last hit minus first over EVERY event type, so a visitor
  #     who reads one page for three minutes and leaves has a three-minute
  #     session (the leave event carries the end), not the zero a
  #     page-views-only calculation gives.

  import Ecto.Query

  @doc """
  Groups `query` (already restricted to a time window) into one row per
  session: `%{session_id, hits, seconds}`, plus `site` with `by_site: true`.
  """
  @spec per_session(Ecto.Queryable.t(), keyword()) :: Ecto.Query.t()
  def per_session(query, opts \\ []) do
    if Keyword.get(opts, :by_site, false) do
      from(e in query,
        group_by: [fragment("COALESCE(?, '')", e.site), e.session_id],
        having: fragment("COUNT(*) FILTER (WHERE ? = 'pageview')", e.event_type) > 0,
        select: %{
          site: fragment("COALESCE(?, '')", e.site),
          session_id: e.session_id,
          hits: fragment("COUNT(*) FILTER (WHERE ? = 'pageview')", e.event_type),
          seconds: fragment("EXTRACT(EPOCH FROM (MAX(?) - MIN(?)))", e.inserted_at, e.inserted_at)
        }
      )
    else
      from(e in query,
        group_by: e.session_id,
        having: fragment("COUNT(*) FILTER (WHERE ? = 'pageview')", e.event_type) > 0,
        select: %{
          session_id: e.session_id,
          hits: fragment("COUNT(*) FILTER (WHERE ? = 'pageview')", e.event_type),
          seconds: fragment("EXTRACT(EPOCH FROM (MAX(?) - MIN(?)))", e.inserted_at, e.inserted_at)
        }
      )
    end
  end
end
