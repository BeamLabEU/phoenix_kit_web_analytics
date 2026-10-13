defmodule PhoenixKitWebAnalytics.Consent do
  @moduledoc """
  Whether each kind of collection may happen for the visitor in front of us.

  What may be collected without asking differs from one country to the next,
  and from one site's reading of the law to another's, so the module takes no
  position. Each kind of collection has its own mode, set by the operator:

  | Mode | Collected when |
  |------|----------------|
  | `:always` | every time — the visitor is told, not asked (the default) |
  | `:consent` | the visitor said yes |
  | `:unless_objected` | the visitor has not said no, and the browser sends no objection |

  The kinds are `:measurement` (counting visits at all), `:profile` (what
  the `store_ip` / `store_user_agent` / `store_headers` / `store_network`
  settings keep), `:device` (device measurements) and `:recording` (session
  recordings). The last three describe a visitor, so they are only ever
  collected for one whose visits are counted: without `:measurement` there is
  nothing to attach them to.

  ## Where the answer comes from

    * **PhoenixKit's Legal module**, when it is installed and its banner is
      on: `PhoenixKit.Modules.Legal.Consent.status/2` reads the signed
      consent cookie.
    * **The host's own consent tool** otherwise:

          config :phoenix_kit_web_analytics, consent_source: {MyApp.Consent, :status}

      The function takes the `Plug.Conn` and the category and answers
      `:granted`, `:denied` or `:unknown`. When set it is asked instead of
      the Legal module.
    * **Nothing.** Then every visitor is `:unknown`: `:consent` collects
      nothing and `:unless_objected` collects for everyone who sends no
      browser objection. `source/0` says which of the three is in effect, so
      the settings page can warn.

  A source that fails answers `:denied`. One that raises, throws or exits,
  or returns anything but those three atoms, could not say whether the
  visitor refused — and under `:unless_objected` an "unknown" would collect
  from a visitor who did. So the failure is read as a no, and logged once
  per node, naming the source and never the visitor. A `consent_source` that
  is not a `{module, function}` pair is a failure of the same kind.

  A browser objection is `Sec-GPC: 1` or `DNT: 1`. It decides
  `:unless_objected` on the first request, with no cookie needed; a visitor
  who explicitly said yes in the banner is taken at their word over a browser
  default. (`web_analytics_respect_dnt` is a separate, blunter switch: while
  it is on, an objecting browser is not tracked in any mode.)

  ## When the answer applies

  The answer is read from the request, so it is as fresh as the last page
  load. A LiveView cannot see cookies; the plug notes the answer in the
  session for `PhoenixKitWebAnalytics.LiveHook`, where it holds until the
  next full page load. Keep Legal's reload-on-withdrawal option on; a host
  consent tool must also reload after changing an answer. A live navigation
  or reconnect alone does not refresh the note. The rules themselves are
  re-applied to that answer on each hit, so changing a setting takes effect
  on open pages too. Nothing collected before a yes is kept back for later:
  a hit that may not be stored is dropped (or counted without a visitor, see
  `web_analytics_without_consent`), never queued.

  The note is the only thing a LiveView knows about the visitor's answer, so
  a session without one is read as a visitor who objected and has not
  answered: nothing that waits for an answer is collected on a LiveView
  until the plug has written it. That needs the plug to run **after**
  `:fetch_session` (it never starts a session itself) on the pages that lead
  to a LiveView. While any rule waits for an answer the note is written for
  every visitor — it lives in the site's own session cookie, and
  `PhoenixKitWebAnalytics.DataCollection` declares it.
  """

  require Logger

  import Plug.Conn, only: [get_req_header: 2, get_session: 2, put_session: 3]

  alias PhoenixKitWebAnalytics.Config

  @legal PhoenixKit.Modules.Legal
  @legal_consent PhoenixKit.Modules.Legal.Consent
  @session_key "phoenix_kit_web_analytics_consent"
  @statuses [:granted, :denied, :unknown]
  @warned_key {__MODULE__, :source_failed_warned}
  @purposes [:measurement, :profile, :device, :recording]
  @all Map.new(@purposes, &{&1, true})
  @none Map.new(@purposes, &{&1, false})

  @type status :: :granted | :denied | :unknown
  @type answer :: {status(), objected? :: boolean()}
  @type permissions :: %{
          measurement: boolean(),
          profile: boolean(),
          device: boolean(),
          recording: boolean()
        }

  @doc "Everything allowed — what a hit is treated as when it says nothing."
  @spec all() :: permissions()
  def all, do: @all

  @doc "Nothing allowed."
  @spec none() :: permissions()
  def none, do: @none

  @doc "The session key the plug notes a visitor's answer under, for the LiveView hook."
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @doc """
  Whether any kind of collection waits for an answer. `false` is the default
  configuration, and then no request is looked at for one.
  """
  @spec needed?(Config.collection_config()) :: boolean()
  def needed?(%{consent: modes}), do: Enum.any?(modes, fn {_purpose, mode} -> mode != :always end)
  def needed?(_config), do: false

  @doc "Whether a mode lets something be collected, given the visitor's answer."
  @spec allows?(Config.consent_mode(), status(), boolean()) :: boolean()
  def allows?(:always, _status, _objected?), do: true
  def allows?(:consent, status, _objected?), do: status == :granted
  def allows?(:unless_objected, :granted, _objected?), do: true
  def allows?(:unless_objected, :denied, _objected?), do: false
  def allows?(:unless_objected, :unknown, objected?), do: not objected?

  @doc """
  What may be collected for a visitor who gave this answer.

  The three kinds that describe a visitor need `:measurement` as well as
  their own mode.
  """
  @spec permissions(Config.collection_config(), answer()) :: permissions()
  def permissions(%{consent: modes}, {status, objected?}) do
    measurement? = allows?(modes.measurement, status, objected?)

    %{
      measurement: measurement?,
      profile: measurement? and allows?(modes.profile, status, objected?),
      device: measurement? and allows?(modes.device, status, objected?),
      recording: measurement? and allows?(modes.recording, status, objected?)
    }
  end

  def permissions(_config, _answer), do: @all

  @doc """
  What may be collected for the visitor making this request.

  Never raises: a consent source that fails answers `:denied`.
  """
  @spec for_conn(Plug.Conn.t(), Config.collection_config()) :: permissions()
  def for_conn(conn, config) do
    if needed?(config), do: permissions(config, answer(conn, config)), else: @all
  end

  @doc "The visitor's answer as this request carries it."
  @spec answer(Plug.Conn.t(), Config.collection_config()) :: answer()
  def answer(conn, config), do: {status(conn, config.consent_category), objected?(conn)}

  @doc "Whether the browser itself objects: `Sec-GPC: 1` or `DNT: 1`."
  @spec objected?(Plug.Conn.t()) :: boolean()
  def objected?(conn),
    do: get_req_header(conn, "sec-gpc") == ["1"] or get_req_header(conn, "dnt") == ["1"]

  @doc """
  What the visitor decided about a consent category, from whichever source
  is in effect.

  Never raises, and fails closed: a source that raises, throws, exits or
  returns something that is not `:granted`, `:denied` or `:unknown` answers
  `:denied` (see the module doc). A source that cleanly says `:unknown` is
  taken at its word.
  """
  @spec status(Plug.Conn.t(), String.t()) :: status()
  def status(conn, category) do
    case configured() do
      # Set, but not a `{module, function}` pair: the host meant to name a
      # source, and falling back to another one would not be what it asked.
      {:invalid, value} -> failed("consent_source #{inspect(value)}", "is not {module, function}")
      _ -> ask(source(), conn, category)
    end
  end

  defp ask(:none, _conn, _category), do: :unknown

  # Everything is caught, not only exceptions: this runs in the plug's own
  # `call/2`, where a throw or an exit from the host's consent tool would
  # take the page down with it.
  defp ask(source, conn, category) do
    case answer_of(source, conn, category) do
      status when status in @statuses -> status
      _other -> failed(source_name(source), "returned something that is not an answer")
    end
  rescue
    error -> failed(source_name(source), "raised #{inspect(error.__struct__)}")
  catch
    kind, _reason -> failed(source_name(source), "ended with #{kind}")
  end

  defp answer_of({:host, {module, function}}, conn, category),
    do: apply(module, function, [conn, category])

  defp answer_of(:legal, conn, category), do: legal(@legal_consent, :status, [conn, category])

  defp source_name({:host, {module, function}}), do: "#{inspect(module)}.#{function}/2"
  defp source_name(:legal), do: "#{inspect(@legal_consent)}.status/2"

  # Once per node, like the collector's missing-supervisor warning: a source
  # that is down fails on every request. The text names the source and how
  # it failed — never the error's message or the request, either of which
  # could carry something about the visitor.
  defp failed(source, how) do
    unless :persistent_term.get(@warned_key, false) do
      :persistent_term.put(@warned_key, true)

      Logger.warning(
        "[WebAnalytics] the consent source #{source} #{how}. Its visitors are treated as " <>
          "having refused until it answers :granted, :denied or :unknown."
      )
    end

    :denied
  end

  @doc """
  Where answers come from right now: `{:host, {module, function}}`, `:legal`
  or `:none`.
  """
  @spec source() :: {:host, {module(), atom()}} | :legal | :none
  def source do
    case configured() do
      {:ok, pair} -> {:host, pair}
      _ -> if legal_asking?(), do: :legal, else: :none
    end
  end

  defp configured do
    case Application.get_env(:phoenix_kit_web_analytics, :consent_source) do
      nil -> :unset
      {module, function} when is_atom(module) and is_atom(function) -> {:ok, {module, function}}
      value -> {:invalid, value}
    end
  end

  defp legal_asking? do
    Code.ensure_loaded?(@legal_consent) and function_exported?(@legal_consent, :status, 2) and
      Code.ensure_loaded?(@legal) and legal(@legal, :enabled?, []) == true and
      legal(@legal, :consent_widget_enabled?, []) == true
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end

  # `apply/3` rather than a direct call: the Legal module lives in an
  # optional package, and both the compiler and dialyzer resolve a direct
  # call statically and report it undefined. `Code.ensure_loaded?/1` in
  # `legal_asking?/0` is the runtime check; this only shields the static pass
  # — the same idiom, for the same reason, as core's consent-config
  # controller.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp legal(module, function, args), do: apply(module, function, args)

  # ── the session note for the LiveView hook ────────────────────────────────

  @doc """
  Notes the visitor's answer in the session, when the host fetched one and
  the note would change. Never starts a session.
  """
  @spec remember(Plug.Conn.t(), answer()) :: Plug.Conn.t()
  def remember(conn, answer) do
    note = encode(answer)

    if conn.private[:plug_session_fetch] == :done and get_session(conn, @session_key) != note,
      do: put_session(conn, @session_key, note),
      else: conn
  end

  @doc """
  What may be collected on a LiveView, from the note the plug left in its
  session. Without a note nothing that waits for an answer is collected.
  """
  @spec for_session(map() | term(), Config.collection_config()) :: permissions()
  def for_session(session, config) do
    if needed?(config), do: permissions(config, noted(session)), else: @all
  end

  @doc false
  # Only the consent note and its category travel with a live hit, never
  # the host's whole session. A yes to an old category is no answer to a new
  # one. With no note, a rule introduced while the page is open fails closed.
  @spec refresh(map(), Config.collection_config()) :: map()
  def refresh(%{consent_context: %{session: session, category: category}} = hit, config) do
    answer = if category == config.consent_category, do: noted(session), else: {:unknown, true}
    Map.put(hit, :consent, permissions(config, answer))
  end

  def refresh(hit, _config), do: hit

  @doc """
  The answer noted in a LiveView session.

  A session without a note — the plug ran before `:fetch_session`, or never
  served the page — reads as objected and unanswered, `{:unknown, true}`:
  the visitor may well have refused, and nothing here can tell. So does a
  note this module did not write.
  """
  @spec noted(map() | term()) :: answer()
  def noted(%{@session_key => note}), do: decode(note)
  def noted(_session), do: {:unknown, true}

  defp encode({status, objected?}),
    do: Atom.to_string(status) <> if(objected?, do: ":objected", else: "")

  # Matched whole: a note is one of six strings, and anything else — a
  # prefix of one included — is not an answer.
  defp decode("granted"), do: {:granted, false}
  defp decode("granted:objected"), do: {:granted, true}
  defp decode("denied"), do: {:denied, false}
  defp decode("denied:objected"), do: {:denied, true}
  defp decode("unknown"), do: {:unknown, false}
  defp decode(_note), do: {:unknown, true}
end
