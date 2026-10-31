defmodule PhoenixKitWebAnalytics.RateLimit.Plug do
  @moduledoc """
  Limits the requests of a pipeline by rules — see
  `PhoenixKitWebAnalytics.RateLimit` for the rules, the exemptions, the
  blocklist and what a refusal looks like.

      plug PhoenixKitWebAnalytics.RateLimit.Plug,
        rules: [
          [name: :search, paths: ["/search"], methods: ["GET"], limit: 60, window_ms: 60_000],
          [name: :all, paths: ["/catalog*"], limit: 300, network_limit: 1_200]
        ]

  ## Options

    * `:rules` — the rules (required to limit anything)
    * `:exempt_local` — leave a loopback peer asking for `localhost` alone
      (default `true`)
    * `:exempt` — `{Mod, :fun, args}`; `Mod.fun(conn, ...args)` returning
      `true` leaves the request alone
    * `:on_deny` — `{Mod, :fun, args}`; `Mod.fun(conn, denial, ...args)`
      renders the refusal (the conn is halted after)
    * `:format` — `:auto` (default), `:json` or `:html` for the built-in
      refusal

  Put it after `PhoenixKitWebAnalytics.Plug` or before, as you like; put it
  after the plugs that load the user if staff are to be left alone. It
  computes the visitor once (`PhoenixKitWebAnalytics.put_visitor/1`), so
  later code — `RateLimit.charge/3` included — reuses it.

  Cost to a request: one cached settings read, one SHA-256, and for each
  matching rule two ETS counter reads/updates.
  """

  @behaviour Plug

  alias PhoenixKitWebAnalytics.RateLimit

  @impl Plug
  def init(opts) do
    rules = opts |> Keyword.get(:rules, []) |> Enum.map(&RateLimit.normalize_rule/1)

    %{
      id: :erlang.phash2(rules),
      rules: rules,
      exempt_local: Keyword.get(opts, :exempt_local, true),
      exempt: mfa(opts, :exempt),
      on_deny: mfa(opts, :on_deny),
      format: Keyword.get(opts, :format, :auto)
    }
  end

  @impl Plug
  def call(conn, opts), do: RateLimit.call(conn, opts)

  defp mfa(opts, key) do
    case Keyword.get(opts, key) do
      nil ->
        nil

      {module, function, args} = mfa
      when is_atom(module) and is_atom(function) and is_list(args) ->
        mfa

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} #{key}: expected {Module, :function, args}, got: #{inspect(other)}"
    end
  end
end
