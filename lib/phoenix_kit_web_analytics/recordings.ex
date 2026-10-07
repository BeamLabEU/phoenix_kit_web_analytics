defmodule PhoenixKitWebAnalytics.Recordings do
  @moduledoc """
  Session recordings: how a visitor moved the pointer, what they clicked and
  hovered, how the page scrolled — enough to replay a visit over the page it
  happened on.

  **Off by default** (`web_analytics_recording`). The optional client script
  asks `GET /phoenix-kit/analytics/recording` once per page load whether to
  record; while it does, it posts a chunk every few seconds (and one when
  the page is hidden or left) to `POST /phoenix-kit/analytics/recording`.

  ## What is never recorded

  Text. No keystrokes, no form values, no page content, no element text —
  only coordinates and short element selectors (`main > form.signup >
  button:nth-of-type(2)`). Visitors sending Do Not Track or Global Privacy
  Control, bots, and excluded paths are never recorded.

  Neither is the site's own traffic, by the `PhoenixKitWebAnalytics.TrafficFlags`
  bits the statistics leave out: an address in an internal or staff network
  is refused up front, and a chunk is dropped when its visit carries such a
  bit — a visit that becomes an admin's (a sign-in) stops being recorded
  from there; what was stored before stays.

  ## Volume

  A recorded page view is a chunk every ~10 seconds while something happens,
  so on a busy site recording everyone is a lot of rows. Two knobs:

    * `web_analytics_recording_sample` — the percent of visitors recorded
      (decided from the daily visitor hash, so a visitor is recorded for the
      whole day or not at all);
    * `web_analytics_recording_retention_days` — recordings older than this
      are deleted by the retention pass (30 days by default).

  Writes go through the collector's capped task pool, so under a flood
  chunks are dropped rather than queued.

  ## Frame format (version 1)

  A chunk's `frames` is `%{"v" => 1, "f" => frames}`; each frame is a list
  starting with the milliseconds since the page was shown, then a type:

  | Frame | Meaning |
  |-------|---------|
  | `[t, "m", x, y]` | pointer at viewport `x`, `y` |
  | `[t, "c", x, y, selector]` | click (or tap) at `x`, `y` on `selector` |
  | `[t, "h", selector]` | pointer rested on `selector` (hover) |
  | `[t, "s", scroll_x, scroll_y]` | page scrolled to |
  | `[t, "r", width, height]` | viewport resized to |
  | `[t, "v", 0 \\| 1]` | page hidden / shown again |

  The chunk carries the viewport size at the start of the page view; a
  replay loads `path` at that size, applies the scrolls and draws the
  pointer, clicks and hovers over it.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.InternalTraffic
  alias PhoenixKitWebAnalytics.Schemas.Event
  alias PhoenixKitWebAnalytics.Schemas.Recording
  alias PhoenixKitWebAnalytics.TrafficFlags
  alias PhoenixKitWebAnalytics.UserAgent
  alias PhoenixKitWebAnalytics.Visitor

  @types ~w(m c h s r v)
  @max_frames 2_000
  @max_chunks_per_minute 30
  # About an hour of chunks every ~10 s; a page open longer stops recording.
  @max_seq 400
  @max_selector 200
  @max_coordinate 100_000
  # A page view replayed whole, but a visit stops loading here.
  @max_frames_per_visit 100_000
  @delete_batch 5_000
  @max_delete_batches 100

  @doc """
  Whether this request's visitor should be recorded on `path`: recording on,
  the visitor sampled in, not a bot, not opted out, the path not excluded,
  the address not in a network whose traffic the statistics leave out.
  """
  @spec record?(map(), String.t() | nil) :: boolean()
  def record?(client, path) do
    config = Config.collection_config()

    config.enabled? and config.recording? and is_binary(path) and
      not Config.excluded?(path, config.exclusions) and
      not (config.respect_dnt? and client[:opted_out?] == true) and
      not UserAgent.bot?(client[:user_agent]) and
      not TrafficFlags.excluded?(
        InternalTraffic.network_flags(client[:ip], config),
        config.excluded_flags
      ) and
      sampled?(visitor_id(client), config.recording_sample)
  end

  defp sampled?(nil, _percent), do: false
  defp sampled?(_visitor_id, 100), do: true
  defp sampled?(visitor_id, percent), do: :erlang.phash2(visitor_id, 100) < percent

  @doc """
  Validates a chunk the client script posted and stores it, off the
  caller's process. Returns `:ok` when it was accepted for writing and
  `{:error, reason}` when it was refused — `:not_recording`, `:invalid`,
  `:too_fast` (over #{@max_chunks_per_minute} chunks a minute from one
  visitor).
  """
  @spec store(map(), map()) :: :ok | {:error, :not_recording | :invalid | :too_fast}
  def store(client, params) when is_map(params) do
    with {:ok, chunk} <- validate(params),
         true <- record?(client, chunk.path) || {:error, :not_recording},
         visitor_id when is_binary(visitor_id) <- visitor_id(client),
         true <- within_rate?(visitor_id) || {:error, :too_fast} do
      Collector.run_async(fn -> insert(client, visitor_id, chunk) end)
    else
      nil -> {:error, :not_recording}
      error -> error
    end
  end

  def store(_client, _params), do: {:error, :invalid}

  # A page sends a chunk every ~10 s, plus one when it's hidden or left;
  # far more than that from one visitor is someone filling the table.
  defp within_rate?(visitor_id),
    do: PhoenixKitWebAnalytics.BotSignals.count(:recording, visitor_id) <= @max_chunks_per_minute

  @doc false
  # Public for the controller test: what a payload turns into, or :error.
  @spec validate(map()) :: {:ok, map()} | {:error, :invalid}
  def validate(params) do
    with key when is_binary(key) <- params["k"],
         true <- Regex.match?(~r/\A[A-Za-z0-9]{8,32}\z/, key),
         seq when is_integer(seq) and seq >= 0 and seq <= @max_seq <- params["s"],
         {:ok, path} <- clean_path(params["p"]),
         frames when is_list(frames) and frames != [] <- params["f"] do
      frames = frames |> Enum.take(@max_frames) |> Enum.flat_map(&frame/1)

      if frames == [] do
        {:error, :invalid}
      else
        {:ok,
         %{
           page_key: key,
           seq: seq,
           path: path,
           viewport_w: dimension(params["w"]),
           viewport_h: dimension(params["h"]),
           frames: frames
         }}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  # A same-site path, and nothing more: the query string and fragment go (a
  # path never keeps one), a trailing slash goes (as the collector stores
  # page views, so the two compare equal), and anything a browser would
  # resolve to somewhere else is refused — `//host`, `/\\host`, control
  # characters, and `.`/`..` segments, plain or %-encoded (`/blog/../admin`
  # would load /admin).
  defp clean_path("/" <> _ = raw) do
    path = raw |> String.split(["?", "#"], parts: 2) |> hd()

    cond do
      String.starts_with?(path, "//") -> :error
      String.contains?(path, "\\") -> :error
      String.match?(path, ~r/[\x00-\x1f\x7f]/) -> :error
      dot_segment?(path) -> :error
      true -> {:ok, path |> trim_slash() |> PhoenixKitWebAnalytics.Tracking.truncate_utf8(2048)}
    end
  end

  defp clean_path(_path), do: :error

  defp dot_segment?(path) do
    path
    |> String.split("/")
    |> Enum.any?(&(String.downcase(&1) in [".", "..", "%2e", "%2e%2e", ".%2e", "%2e."]))
  end

  defp trim_slash("/"), do: "/"
  defp trim_slash(path), do: String.trim_trailing(path, "/")

  defp frame([t, type | rest]) when is_integer(t) and t >= 0 and type in @types do
    case args(type, rest) do
      nil -> []
      args -> [[min(t, 86_400_000), type | args]]
    end
  end

  defp frame(_frame), do: []

  defp args("m", [x, y]), do: coordinates([x, y])
  defp args("s", [x, y]), do: coordinates([x, y])
  defp args("r", [w, h]), do: coordinates([w, h])

  defp args("c", [x, y, selector]),
    do: with([_, _] = xy <- coordinates([x, y]), do: xy ++ [selector(selector)])

  defp args("h", [selector]), do: [selector(selector)]
  defp args("v", [shown]) when shown in [0, 1], do: [shown]
  defp args(_type, _args), do: nil

  defp coordinates(values) do
    if Enum.all?(values, &(is_number(&1) and abs(&1) <= @max_coordinate)),
      do: Enum.map(values, &round/1),
      else: nil
  end

  defp selector(value) when is_binary(value),
    do: PhoenixKitWebAnalytics.Tracking.truncate_utf8(value, @max_selector)

  defp selector(_value), do: ""

  defp dimension(value) when is_integer(value) and value > 0 and value <= @max_coordinate,
    do: value

  defp dimension(_value), do: nil

  # The visit is only known here, off the request: one whose hits carry a
  # bit the statistics leave out (the visitor signed in as an admin) isn't
  # recorded any further.
  defp insert(client, visitor_id, chunk) do
    now = DateTime.utc_now()
    site = client[:site]
    session_id = session_for(chunk.page_key, visitor_id, now, site)

    if TrafficFlags.excluded?(session_flags(session_id), Config.excluded_flags()),
      do: :excluded,
      else: insert_chunk(client, chunk, session_id, now)
  end

  # The visit's latest hit carries every bit the visit has (the collector
  # writes a new one back to the earlier hits).
  defp session_flags(session_id) do
    from(e in Event,
      where: e.session_id == ^session_id,
      order_by: [desc: e.inserted_at],
      limit: 1,
      select: e.traffic_flags
    )
    |> repo().one()
  end

  defp insert_chunk(client, chunk, session_id, now) do
    site = client[:site]

    %{
      session_id: session_id,
      page_key: chunk.page_key,
      seq: chunk.seq,
      path: chunk.path,
      site: site,
      viewport_w: chunk.viewport_w,
      viewport_h: chunk.viewport_h,
      frames: %{"v" => 1, "f" => chunk.frames},
      frame_count: length(chunk.frames),
      inserted_at: now
    }
    |> then(&struct(Recording, &1))
    |> repo().insert(on_conflict: :nothing, conflict_target: [:page_key, :seq])
  end

  # A page view's chunks stay in one visit: later chunks follow the first
  # one's, even when they arrive after the visit's inactivity window.
  defp session_for(page_key, visitor_id, now, site) do
    from(r in Recording, where: r.page_key == ^page_key, select: r.session_id, limit: 1)
    |> repo().one()
    |> case do
      nil -> Collector.resolve_session(visitor_id, Config.session_timeout_minutes(), now, site)
      session_id -> session_id
    end
  end

  defp visitor_id(client) do
    case Config.hash_salt() do
      nil -> nil
      salt -> Visitor.visitor_id(client[:ip], client[:user_agent], salt)
    end
  end

  @doc """
  Whether a visit has a recording.
  """
  @spec recorded?(String.t()) :: boolean()
  def recorded?(session_id) do
    case Ecto.UUID.cast(session_id) do
      {:ok, uuid} ->
        from(r in Recording, where: r.session_id == ^uuid, select: 1, limit: 1)
        |> repo().one()
        |> Kernel.==(1)

      :error ->
        false
    end
  rescue
    # The visit page asks on mount; a failed read hides the player, never
    # the page.
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning(
        "[WebAnalytics] could not check for a recording: #{Exception.message(error)}"
      )

      false
  end

  @doc """
  A visit's recording, page view by page view, oldest first:
  `[%{path, viewport_w, viewport_h, started_at, frames}]`, the frames of each
  page's chunks joined in order. Stops at #{@max_frames_per_visit} frames.
  """
  @spec for_session(String.t()) :: [map()]
  def for_session(session_id) do
    case Ecto.UUID.cast(session_id) do
      {:ok, uuid} -> load_session(uuid)
      :error -> []
    end
  end

  defp load_session(uuid) do
    from(r in Recording,
      where: r.session_id == ^uuid,
      order_by: [asc: r.inserted_at, asc: r.seq],
      select: %{
        page_key: r.page_key,
        seq: r.seq,
        path: r.path,
        viewport_w: r.viewport_w,
        viewport_h: r.viewport_h,
        frames: r.frames,
        frame_count: r.frame_count,
        inserted_at: r.inserted_at
      }
    )
    |> repo().all()
    |> take_frames(@max_frames_per_visit)
    |> Enum.group_by(& &1.page_key)
    |> Enum.map(&page/1)
    |> Enum.sort_by(& &1.started_at, DateTime)
  end

  defp take_frames(chunks, budget) do
    chunks
    |> Enum.reduce_while({[], budget}, fn chunk, {acc, left} ->
      if left <= 0,
        do: {:halt, {acc, left}},
        else: {:cont, {[chunk | acc], left - chunk.frame_count}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp page({_key, chunks}) do
    chunks = Enum.sort_by(chunks, & &1.seq)
    first = hd(chunks)

    %{
      path: first.path,
      viewport_w: first.viewport_w,
      viewport_h: first.viewport_h,
      # The page was shown this long before its first chunk arrived.
      started_at: DateTime.add(first.inserted_at, -first_offset(first), :millisecond),
      frames: Enum.flat_map(chunks, &frames_of/1)
    }
  end

  defp frames_of(%{frames: %{"f" => frames}}) when is_list(frames), do: frames
  defp frames_of(_chunk), do: []

  defp first_offset(chunk) do
    case frames_of(chunk) |> List.last() do
      [t | _] when is_integer(t) -> t
      _ -> 0
    end
  end

  @doc """
  `for_session/1` for the player, each page marked `loadable` when the player
  may load it behind the recording: a path this visit really requested (a
  page view the server recorded), not excluded from tracking. The path in a
  chunk comes from the visitor's browser, so it is never loaded on its word
  alone — an admin opening a replay must not be sent to a URL a visitor
  chose.
  """
  @spec replay(String.t()) :: [map()]
  def replay(session_id) do
    pages = for_session(session_id)
    viewed = viewed_paths(session_id)
    exclusions = Config.collection_config().exclusions

    Enum.map(pages, fn page ->
      Map.put(
        page,
        :loadable,
        page.path in viewed and not Config.excluded?(page.path, exclusions)
      )
    end)
  end

  defp viewed_paths(session_id) do
    case Ecto.UUID.cast(session_id) do
      {:ok, uuid} ->
        # Page views the server itself saw (the plug, a live navigation) —
        # never one the visitor's browser reported through the beacon.
        from(e in Event,
          where: e.session_id == ^uuid and e.event_type == "pageview",
          where: fragment("COALESCE(?->>'source', '') <> 'beacon'", e.metadata),
          distinct: true,
          select: e.path
        )
        |> repo().all()

      :error ->
        []
    end
  end

  @doc """
  Deletes recordings older than the retention setting, in batches. Returns
  the number deleted.
  """
  @spec prune() :: non_neg_integer()
  def prune do
    cutoff = DateTime.add(DateTime.utc_now(), -Config.recording_retention_days(), :day)
    prune_before(cutoff, 0, 0)
  rescue
    # Part of the retention pass, which must go on to the rollups.
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("[WebAnalytics] recording prune failed: #{Exception.message(error)}")
      0
  end

  defp prune_before(_cutoff, deleted, @max_delete_batches), do: deleted

  defp prune_before(cutoff, deleted, batches) do
    ids =
      from(r in Recording,
        where: r.inserted_at < ^cutoff,
        order_by: [asc: r.inserted_at],
        limit: @delete_batch,
        select: r.uuid
      )

    case from(r in Recording, where: r.uuid in subquery(ids)) |> repo().delete_all() do
      {0, _} -> deleted
      {count, _} -> prune_before(cutoff, deleted + count, batches + 1)
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
