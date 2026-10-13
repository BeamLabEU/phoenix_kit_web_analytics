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

  A browser objection is `Sec-GPC: 1` or `DNT: 1`. It decides
  `:unless_objected` on the first request, with no cookie needed; a visitor
  who explicitly said yes in the banner is taken at their word over a browser
  default. (`web_analytics_respect_dnt` is a separate, blunter switch: while
  it is on, an objecting browser is not tracked in any mode.)

  ## When the answer applies

  The answer is read from the request, so it is as fresh as the last page
  load. A LiveView cannot see cookies; the plug notes the answer in the
  session for `PhoenixKitWebAnalytics.LiveHook`, where it holds until the
  next full page load. Nothing collected before a yes is kept back for later:
  a hit that may not be stored is dropped (or counted without a visitor, see
  `web_analytics_without_consent`), never queued.
  """

  import Plug.Conn, only: [get_req_header: 2, get_session: 2, put_session: 3]

  alias PhoenixKitWebAnalytics.Config

  @legal PhoenixKit.Modules.Legal
  @legal_consent PhoenixKit.Modules.Legal.Consent
  @session_key "phoenix_kit_web_analytics_consent"
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

  Never raises: a consent source that fails answers `:unknown`.
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

  @doc "What the visitor decided about a consent category, from whichever source is in effect."
  @spec status(Plug.Conn.t(), String.t()) :: status()
  def status(conn, category) do
    case source() do
      {:host, {module, function}} -> clean(apply(module, function, [conn, category]))
      :legal -> clean(legal(@legal_consent, :status, [conn, category]))
      :none -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  @doc """
  Where answers come from right now: `{:host, {module, function}}`, `:legal`
  or `:none`.
  """
  @spec source() :: {:host, {module(), atom()}} | :legal | :none
  def source do
    case Application.get_env(:phoenix_kit_web_analytics, :consent_source) do
      {module, function} when is_atom(module) and is_atom(function) ->
        {:host, {module, function}}

      _ ->
        if legal_asking?(), do: :legal, else: :none
    end
  end

  defp legal_asking? do
    Code.ensure_loaded?(@legal_consent) and function_exported?(@legal_consent, :status, 2) and
      Code.ensure_loaded?(@legal) and legal(@legal, :enabled?, []) == true and
      legal(@legal, :consent_widget_enabled?, []) == true
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # `apply/3` rather than a direct call: the Legal module lives in an
  # optional package, and both the compiler and dialyzer resolve a direct
  # call statically and report it undefined. `Code.ensure_loaded?/1` in
  # `legal_asking?/0` is the runtime check; this only shields the static pass
  # — the same idiom, for the same reason, as core's consent-config
  # controller.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp legal(module, function, args), do: apply(module, function, args)

  defp clean(status) when status in [:granted, :denied], do: status
  defp clean(_status), do: :unknown

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
  session. Without a note the visitor has given no answer.
  """
  @spec for_session(map() | term(), Config.collection_config()) :: permissions()
  def for_session(session, config) do
    if needed?(config), do: permissions(config, noted(session)), else: @all
  end

  @doc "The answer noted in a LiveView session; unknown and unobjecting without one."
  @spec noted(map() | term()) :: answer()
  def noted(%{@session_key => note}), do: decode(note)
  def noted(_session), do: {:unknown, false}

  defp encode({status, objected?}),
    do: Atom.to_string(status) <> if(objected?, do: ":objected", else: "")

  defp decode("granted" <> rest), do: {:granted, rest == ":objected"}
  defp decode("denied" <> rest), do: {:denied, rest == ":objected"}
  defp decode("unknown:objected"), do: {:unknown, true}
  defp decode(_note), do: {:unknown, false}
end
