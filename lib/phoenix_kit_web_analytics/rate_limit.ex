defmodule PhoenixKitWebAnalytics.RateLimit do
  @moduledoc """
  Opt-in rate limits for a host's public routes, counted per visitor **and**
  per network, on core's Hammer backend.

  Nothing is limited until the host installs `PhoenixKitWebAnalytics.RateLimit.Plug`
  with rules — the rules live in code, next to the routes they protect:

      pipeline :public do
        plug PhoenixKitWebAnalytics.Plug
        plug PhoenixKitWebAnalytics.RateLimit.Plug,
          rules: [
            [name: :search, paths: ["/search", "/api/search*"], methods: ["GET"], limit: 60],
            [name: :all, paths: ["/catalog*"], limit: 300, window_ms: 60_000],
            # No paths: never counted by the plug, only charged from code.
            [name: :ai_search, limit: 20, window_ms: 60_000]
          ]
      end

  and, for work that is expensive only sometimes — a cache miss:

      case PhoenixKitWebAnalytics.RateLimit.charge(conn, :ai_search) do
        :ok -> run_the_expensive_thing()
        {:error, denial} -> PhoenixKitWebAnalytics.RateLimit.deny(conn, denial)
      end

  ## Rules

    * `:name` — an atom, the rule's name in keys, reports and `charge/3`.
      One name, one rule: `charge/3` finds a rule by name, so two plugs
      defining the same name differently are warned about at registration
    * `:paths` — patterns matched like `PhoenixKitWebAnalytics.Config.excluded?/2`:
      a literal path or a trailing-`*` prefix, also past a leading locale
      segment (`/et/search` for `/search`). Empty (the default): the plug
      never counts the rule; only `charge/3` does.
    * `:methods` — e.g. `["GET"]`; every method when left out
    * `:limit` — requests (cost units) per visitor per window
    * `:window_ms` — the window, fixed and aligned to the clock (60 s by default)
    * `:network_limit` — per network per window; 4× `:limit` by default

  A request a rule matches costs one unit in **both** of its buckets, and both
  must have room. The visitor ID includes the User-Agent, so a client that
  changes its User-Agent per request is a new "visitor" each time — the
  network bucket is what holds it. The visitor is
  `PhoenixKitWebAnalytics.visitor/1` (the analytics' own visitor ID; a hash
  of the address and User-Agent with a per-node secret when the salt can't be
  read), the network `PhoenixKit.Utils.IpAddress.network/1` (an IPv4
  address, an IPv6 `/64`). Keys are `"wa:rl:<rule>:v:<visitor>"` and
  `"wa:rl:<rule>:n:<network>"` in core's Hammer table
  (`PhoenixKit.Users.RateLimiter.Backend`), so counters are **per node**.

  A bot score never enters into it: what is counted is requests, and a
  score is evidence, never a verdict.

  ## Who is never limited

    * the site's internal networks — the `web_analytics_internal_networks_secret`
      setting and `config :phoenix_kit_web_analytics, internal_networks: […]`
    * staff, by the same role rule as the analytics (`web_analytics_internal_roles`)
      — only visible to the plug when it runs after the user is loaded;
      `charge/3` from a controller sees them
    * a loopback client asking for `localhost` (development) — the client
      address the module resolves, so a request a local proxy forwards is
      never "local" whatever its `Host` — unless the plug is given
      `exempt_local: false`
    * a request carrying the bypass token in its `x-rate-limit-bypass` header:

          # config/runtime.exs — app config, never a setting
          config :phoenix_kit_web_analytics, :rate_limit,
            bypass_token: System.fetch_env!("RATE_LIMIT_BYPASS"),   # 16+ bytes
            bypass_header: "x-rate-limit-bypass"

    * whatever the plug's `exempt: {Mod, :fun, args}` answers `true` for
      (called as `Mod.fun(conn, ...args)`)

  ## Blocked networks

  The `web_analytics_blocked_networks_secret` setting (Settings, one network
  or address per line, nothing wider than `/8` or `/16`) is answered `403` by
  the plug, on every path it sees. It is an operator's explicit decision:
  nothing is ever added to it automatically.

  ## On, log only, off

  `web_analytics_rate_limit` (Settings) is `on` by default — installing the
  plug with rules is the opt-in. `log_only` counts and records every denial
  but lets the request through, for tuning limits on real traffic — every
  rule a request matches is counted, not only up to the first one over its
  limit; `charge/3` then answers `:ok`. `off` skips everything, the blocklist
  included. The blocklist is enforced in `log_only` too: it is not a limit
  to tune.

  ## A refusal

  `429` with `retry-after` (whole seconds, rounded up) and
  `ratelimit-limit` / `ratelimit-remaining` / `ratelimit-reset`, like core's
  API. The body is JSON — `{"error":"rate_limited","retry_after":N}` — for a
  request that accepts JSON or whose path has an `api` / `_api` segment, and
  a small HTML page otherwise (`format: :json | :html` on the plug forces
  one). `on_deny: {Mod, :fun, args}` renders the host's own:
  `Mod.fun(conn, denial, ...args)` returns the conn, which is then halted.
  A callback that raises, throws, exits or returns a conn with no response gets the
  built-in refusal instead; a conn already sent is only halted.

  ## What is kept

  Nothing in the database and nothing in a setting. Per node, in memory
  (`PhoenixKitWebAnalytics.Ring`): the last 500 denials — time, rule,
  which bucket, the network (the whole one only when `web_analytics_store_ip`
  is `full`, else its `/24` or `/48`), the first 8 characters of the visitor
  ID, method and path (never a query string) — and a count of allowed and
  refused requests per rule since the node started. The Rate limits page
  shows them. Each denial also emits
  `[:phoenix_kit_web_analytics, :rate_limit, :deny]` (measurements
  `%{count: 1, retry_after_ms: ms}`, metadata `%{rule, scope, mode, path}`),
  and each blocklist refusal `[:phoenix_kit_web_analytics, :rate_limit, :block]`.

  ## Never the reason a request fails

  Everything here rescues. With the Hammer table missing or anything else
  going wrong the request is allowed (fail open), logged at most once every
  ten minutes.
  """

  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  require Logger

  alias PhoenixKit.Users.RateLimiter.Backend
  alias PhoenixKitWebAnalytics.Collector
  alias PhoenixKitWebAnalytics.Config
  alias PhoenixKitWebAnalytics.InternalTraffic
  alias PhoenixKitWebAnalytics.Profiles
  alias PhoenixKitWebAnalytics.RequestVisitor
  alias PhoenixKitWebAnalytics.Ring
  alias PhoenixKitWebAnalytics.Tracking

  @registry_key {__MODULE__, :rules}
  @warned_key {__MODULE__, :failed_open_at}
  @secret_key {__MODULE__, :node_secret}
  @state_key :phoenix_kit_web_analytics_rate_limit
  @denials :rate_limit_denials
  @denials_size 500
  @network_factor 4
  @default_window_ms 60_000
  @warn_every_ms :timer.minutes(10)
  @default_bypass_header "x-rate-limit-bypass"
  @local_hosts ["localhost", "127.0.0.1", "::1", "[::1]"]

  @type rule :: %{
          name: atom(),
          paths: [String.t()],
          methods: [String.t()] | :any,
          limit: pos_integer(),
          window_ms: pos_integer(),
          network_limit: pos_integer()
        }

  @type denial :: %{
          rule: atom(),
          scope: :visitor | :network,
          retry_after_ms: pos_integer(),
          limit: pos_integer()
        }

  # ── rules ─────────────────────────────────────────────────────────────────

  @doc """
  Reads one rule (a keyword list or a map) — see "Rules". Raises
  `ArgumentError` on a malformed one: rules are code, read when the plug is
  initialised.
  """
  @spec normalize_rule(keyword() | map()) :: rule()
  def normalize_rule(rule) when is_list(rule), do: rule |> Map.new() |> normalize_rule()

  def normalize_rule(%{} = rule) do
    name = Map.get(rule, :name)
    limit = Map.get(rule, :limit)
    window = Map.get(rule, :window_ms, @default_window_ms)

    unless is_atom(name) and not is_nil(name),
      do: raise(ArgumentError, "a rate-limit rule needs an atom :name, got: #{inspect(name)}")

    for {key, value} <- [limit: limit, window_ms: window] do
      unless is_integer(value) and value > 0,
        do: raise(ArgumentError, "rate-limit rule #{name}: #{key} must be a positive integer")
    end

    network_limit = Map.get(rule, :network_limit, limit * @network_factor)

    unless is_integer(network_limit) and network_limit > 0,
      do:
        raise(ArgumentError, "rate-limit rule #{name}: network_limit must be a positive integer")

    %{
      name: name,
      paths: rule |> Map.get(:paths, []) |> List.wrap() |> Enum.map(&to_string/1),
      methods: methods(Map.get(rule, :methods, :any)),
      limit: limit,
      window_ms: window,
      network_limit: network_limit
    }
  end

  defp methods(:any), do: :any

  defp methods(methods),
    do: methods |> List.wrap() |> Enum.map(&(&1 |> to_string() |> String.upcase()))

  @doc false
  # Called by the plug on its first request: plug options are often built
  # at compile time, when nothing can be registered yet. One persistent term
  # read per request after that.
  @spec ensure_registered(%{id: term(), rules: [rule()]}) :: :ok
  def ensure_registered(%{id: id, rules: rules}) do
    unless :persistent_term.get({__MODULE__, :registered, id}, false) do
      # One registration at a time on this node: the registry is a
      # read-modify-write, and concurrent first requests of different plugs
      # would otherwise drop each other's rules.
      :global.trans({{__MODULE__, :register}, self()}, fn -> register(id, rules) end, [node()])
    end

    :ok
  end

  defp register(id, rules) do
    unless :persistent_term.get({__MODULE__, :registered, id}, false) do
      current = :persistent_term.get(@registry_key, %{})
      Enum.each(rules, &warn_redefined(&1, current))
      :persistent_term.put(@registry_key, Enum.reduce(rules, current, &Map.put(&2, &1.name, &1)))
      :persistent_term.put({__MODULE__, :registered, id}, true)
    end
  end

  # Each plug enforces its own rules, but `charge/3` looks a rule up by name:
  # two plugs that define one name differently would charge whichever
  # registered last.
  defp warn_redefined(%{name: name} = rule, current) do
    case current do
      %{^name => ^rule} ->
        :ok

      %{^name => _other} ->
        Logger.warning(
          "[WebAnalytics] rate-limit rule #{inspect(name)} is defined differently by two plugs; " <>
            "charge/3 uses the one registered last. Give each rule its own name."
        )

      _ ->
        :ok
    end
  end

  @doc """
  Every rule known on this node: the ones installed plugs registered (on
  their first request) and the ones in `config :phoenix_kit_web_analytics,
  :rate_limit, rules: […]`, by name.
  """
  @spec rules() :: %{atom() => rule()}
  def rules do
    configured =
      case Application.get_env(:phoenix_kit_web_analytics, :rate_limit, [])[:rules] do
        rules when is_list(rules) -> Map.new(rules, &{&1[:name], normalize_rule(&1)})
        _ -> %{}
      end

    Map.merge(configured, :persistent_term.get(@registry_key, %{}))
  rescue
    _ -> :persistent_term.get(@registry_key, %{})
  end

  # ── charging from code ────────────────────────────────────────────────────

  @doc """
  Charges `cost` units of rule `name` to the request's visitor and network.

  `:ok`, or `{:error, %{rule: name, scope: :visitor | :network,
  retry_after_ms: ms, limit: n}}` when either bucket is full. Always `:ok`
  when rate limiting is off or `log_only` (a denial is then still recorded),
  for an exempt request, an unknown rule, or when anything fails.

  `subject` is the conn — or `PhoenixKitWebAnalytics.visitor/1`'s map, kept
  from a request, where there is no conn (a LiveView); only the internal
  networks exempt a map.
  """
  @spec charge(Plug.Conn.t() | map(), atom(), pos_integer()) :: :ok | {:error, denial()}
  def charge(subject, name, cost \\ 1) when is_integer(cost) and cost > 0,
    do: run(subject, name, cost, :charge)

  @doc """
  Whether `cost` more units of rule `name` would fit — `charge/3` without
  charging, and without recording anything.
  """
  @spec check(Plug.Conn.t() | map(), atom(), pos_integer()) :: :ok | {:error, denial()}
  def check(subject, name, cost \\ 1) when is_integer(cost) and cost > 0,
    do: run(subject, name, cost, :peek)

  defp run(subject, name, cost, how) do
    config = Config.collection_config()

    with mode when mode != :off <- config.rate_limit,
         %{} = rule <- Map.get(rules(), name),
         false <- exempt_subject?(subject, config) do
      visitor = visitor_of(subject, config)
      subject |> count_and_note(rule, visitor, cost, how) |> answer(mode, config)
    else
      _ -> :ok
    end
  rescue
    error ->
      fail_open(error)
      :ok
  catch
    kind, reason ->
      fail_open({kind, reason})
      :ok
  end

  defp count_and_note(subject, rule, visitor, cost, how) do
    case count(rule, visitor, subject, cost, how) do
      :ok ->
        if how == :charge, do: Ring.bump({:rate_limit, rule.name, :allowed})
        :ok

      {:error, denial} ->
        {:denied, subject, visitor, denial, how}
    end
  end

  defp answer(:ok, _mode, _config), do: :ok

  defp answer({:denied, subject, visitor, denial, how}, mode, config) do
    if how == :charge, do: note_denial(subject, visitor, denial, mode, config)
    if mode == :on, do: {:error, denial}, else: :ok
  end

  # ── the plug's work ───────────────────────────────────────────────────────

  @doc false
  # `PhoenixKitWebAnalytics.RateLimit.Plug.call/2`.
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, opts) do
    config = Config.collection_config()

    case config.rate_limit do
      :off ->
        conn

      mode ->
        ensure_registered(opts)
        conn = RequestVisitor.put(conn, config)
        visitor = RequestVisitor.get(conn)

        cond do
          bypass?(conn) ->
            put_state(conn, true)

          blocked?(visitor.ip, config) ->
            block(conn, visitor, mode, config, opts)

          exempt_conn?(conn, visitor.ip, config, opts) ->
            put_state(conn, true)

          true ->
            conn |> put_state(false) |> apply_rules(visitor, mode, config, opts)
        end
    end
  rescue
    error ->
      fail_open(error)
      conn
  catch
    kind, reason ->
      fail_open({kind, reason})
      conn
  end

  # `on` stops at the first rule that refuses. `log_only` lets the request
  # through anyway, so it goes on counting every rule — otherwise a tight
  # rule would hide what a looser one beside it would do, which is what
  # log-only exists to show.
  defp apply_rules(conn, visitor, mode, config, opts) do
    denial =
      opts.rules
      |> Enum.filter(&matches?(&1, conn))
      |> Enum.reduce_while(nil, fn rule, first ->
        case count(rule, visitor, conn, 1, :charge) do
          :ok ->
            Ring.bump({:rate_limit, rule.name, :allowed})
            {:cont, first}

          {:error, denial} when mode == :on ->
            {:halt, denial}

          {:error, denial} ->
            note_denial(conn, visitor, denial, mode, config)
            {:cont, first || denial}
        end
      end)

    cond do
      is_nil(denial) ->
        conn

      mode == :on ->
        note_denial(conn, visitor, denial, mode, config)
        deny(conn, denial, opts)

      true ->
        conn
    end
  end

  defp matches?(%{paths: []}, _conn), do: false

  defp matches?(rule, conn) do
    (rule.methods == :any or conn.method in rule.methods) and
      Config.excluded?(conn.request_path, rule.paths)
  end

  defp put_state(conn, exempt?), do: Plug.Conn.put_private(conn, @state_key, %{exempt?: exempt?})

  # ── counting ──────────────────────────────────────────────────────────────

  # The network's room is looked at first and charged last, as core's API
  # does: a request the visitor's own bucket refuses doesn't use up what the
  # visitor's neighbours behind the same address have left.
  defp count(rule, visitor, subject, cost, how) do
    vkey = "wa:rl:#{rule.name}:v:" <> visitor_key(visitor, subject)
    nkey = "wa:rl:#{rule.name}:n:" <> (visitor.network || "unknown")
    window = rule.window_ms

    cond do
      Backend.get(nkey, window) + cost > rule.network_limit ->
        denied(rule, :network, window_left(window), rule.network_limit)

      how == :peek ->
        if Backend.get(vkey, window) + cost > rule.limit,
          do: denied(rule, :visitor, window_left(window), rule.limit),
          else: :ok

      true ->
        with {:visitor, {:allow, _}} <- {:visitor, Backend.hit(vkey, window, rule.limit, cost)},
             {:network, {:allow, _}} <-
               {:network, Backend.hit(nkey, window, rule.network_limit, cost)} do
          :ok
        else
          {:visitor, {:deny, ms}} -> denied(rule, :visitor, ms, rule.limit)
          {:network, {:deny, ms}} -> denied(rule, :network, ms, rule.network_limit)
        end
    end
  end

  defp denied(rule, scope, ms, limit),
    do: {:error, %{rule: rule.name, scope: scope, retry_after_ms: max(ms, 1), limit: limit}}

  defp window_left(window), do: window - rem(System.system_time(:millisecond), window)

  # The analytics' visitor ID; without a salt, the same inputs hashed with a
  # secret of this node's (never stored, gone on restart).
  defp visitor_key(%{visitor_id: id}, _subject) when is_binary(id), do: id

  defp visitor_key(visitor, %Plug.Conn{} = conn) do
    ua = Tracking.first_header(conn, "user-agent") || ""

    :crypto.hash(:sha256, [node_secret(), "|", inspect(visitor.ip), "|", ua])
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp visitor_key(visitor, _subject), do: "net:" <> (visitor.network || "unknown")

  defp node_secret do
    case :persistent_term.get(@secret_key, nil) do
      nil ->
        secret = :crypto.strong_rand_bytes(32)
        :persistent_term.put(@secret_key, secret)
        secret

      secret ->
        secret
    end
  end

  defp visitor_of(%Plug.Conn{} = conn, config), do: RequestVisitor.get(conn, config)

  defp visitor_of(%{} = visitor, _config) do
    %{
      visitor_id: visitor[:visitor_id],
      ip: visitor[:ip],
      network: visitor[:network],
      prefetch?: false
    }
  end

  # ── exemptions ────────────────────────────────────────────────────────────

  # A conn the plug already judged keeps that answer.
  # A conn the plug found exempt stays exempt. One it didn't may since have
  # loaded its user (the plug ran before authentication), so staff are
  # looked for again.
  defp exempt_subject?(%Plug.Conn{private: %{@state_key => %{exempt?: true}}}, _config),
    do: true

  defp exempt_subject?(%Plug.Conn{private: %{@state_key => %{exempt?: false}}} = conn, config),
    do: staff?(conn, RequestVisitor.get(conn, config).ip, config)

  defp exempt_subject?(%Plug.Conn{} = conn, config) do
    ip = RequestVisitor.get(conn, config).ip
    bypass?(conn) or exempt_conn?(conn, ip, config, %{exempt_local: true, exempt: nil})
  end

  defp exempt_subject?(%{} = visitor, config), do: internal?(visitor[:ip], config)

  defp exempt_conn?(conn, ip, config, opts) do
    (Map.get(opts, :exempt_local, true) and local_request?(conn, ip)) or
      internal?(ip, config) or
      staff?(conn, ip, config) or
      host_exempt?(conn, Map.get(opts, :exempt))
  end

  # Matched without the tracking switch: the networks are the operator's
  # whether or not visits are being counted.
  defp internal?(ip, config) when is_tuple(ip),
    do: InternalTraffic.listed?(ip, config.internal_networks, :internal_networks)

  defp internal?(_ip, _config), do: false

  defp staff?(conn, ip, config) do
    case Tracking.current_user_uuid(conn.assigns) do
      nil ->
        false

      uuid ->
        hit = %{roles: Tracking.current_roles(conn.assigns), user_uuid: uuid, ip: ip}
        InternalTraffic.staff_hit?(hit, config)
    end
  end

  # The resolved client, not the peer: behind a proxy on the same machine
  # the peer is always loopback and the Host header is the client's to
  # choose, so `Host: localhost` from anywhere would skip every limit. The
  # proxy's appended X-Forwarded-For names the real client; in development
  # there is no forwarded header and the client is the loopback peer.
  defp local_request?(%Plug.Conn{remote_ip: peer, host: host}, client) do
    loopback?(peer) and loopback?(client) and
      (host in @local_hosts or String.ends_with?(host, ".localhost"))
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_ip), do: false

  defp host_exempt?(conn, {module, function, args}) when is_atom(module) and is_atom(function),
    do: apply(module, function, [conn | List.wrap(args)]) == true

  defp host_exempt?(_conn, _exempt), do: false

  defp bypass?(conn) do
    settings = Application.get_env(:phoenix_kit_web_analytics, :rate_limit, [])

    case settings[:bypass_token] do
      token when is_binary(token) and byte_size(token) >= 16 ->
        header = settings[:bypass_header] || @default_bypass_header

        case Tracking.first_header(conn, header) do
          nil -> false
          given -> Plug.Crypto.secure_compare(given, token)
        end

      _ ->
        false
    end
  end

  # ── blocked networks ──────────────────────────────────────────────────────

  defp blocked?(ip, %{blocked_networks: [_ | _] = entries}) when is_tuple(ip),
    do: InternalTraffic.listed?(ip, entries, :blocked_networks)

  defp blocked?(_ip, _config), do: false

  defp block(conn, visitor, mode, config, opts) do
    Ring.bump({:rate_limit, :blocked, :refused})

    record(conn, visitor, config, %{
      rule: :blocked,
      scope: :network,
      action: :blocked,
      retry_after_ms: nil
    })

    :telemetry.execute(
      [:phoenix_kit_web_analytics, :rate_limit, :block],
      %{count: 1},
      %{mode: mode, path: path_of(conn)}
    )

    conn
    |> respond(403, opts, %{"error" => "forbidden"}, gettext("Access denied"), [])
    |> Plug.Conn.halt()
  end

  # ── refusals ──────────────────────────────────────────────────────────────

  @doc """
  Answers a request `charge/3` refused: `429` with `retry-after` and the
  `ratelimit-*` headers, JSON or HTML as described in the moduledoc (or
  the `on_deny:` given), halted.
  """
  @spec deny(Plug.Conn.t(), denial(), keyword() | map()) :: Plug.Conn.t()
  def deny(conn, denial, opts \\ %{})

  def deny(conn, denial, opts) when is_list(opts), do: deny(conn, denial, Map.new(opts))

  def deny(%Plug.Conn{state: state} = conn, _denial, _opts) when state in [:sent, :chunked],
    do: Plug.Conn.halt(conn)

  def deny(conn, denial, opts) do
    case Map.get(opts, :on_deny) do
      {module, function, args} -> host_deny(conn, denial, opts, {module, function, args})
      _ -> built_in_deny(conn, denial, opts)
    end
  end

  # The host's refusal, or the built-in one when it fails or returns a conn
  # that answers nothing: a refused request must never go on unanswered.
  defp host_deny(conn, denial, opts, {module, function, args}) do
    case apply(module, function, [conn, denial | List.wrap(args)]) do
      %Plug.Conn{state: :unset} -> built_in_deny(conn, denial, opts)
      %Plug.Conn{} = denied -> Plug.Conn.halt(denied)
      _other -> built_in_deny(conn, denial, opts)
    end
  rescue
    error ->
      Logger.warning("[WebAnalytics] rate-limit on_deny raised: #{Exception.message(error)}")
      built_in_deny(conn, denial, opts)
  catch
    kind, _reason ->
      Logger.warning("[WebAnalytics] rate-limit on_deny failed (#{kind})")
      built_in_deny(conn, denial, opts)
  end

  defp built_in_deny(conn, %{retry_after_ms: ms} = denial, opts) do
    seconds = max(div(ms + 999, 1000), 1)

    headers = [
      {"retry-after", Integer.to_string(seconds)},
      {"ratelimit-limit", Integer.to_string(denial.limit)},
      {"ratelimit-remaining", "0"},
      {"ratelimit-reset", Integer.to_string(seconds)}
    ]

    conn
    |> respond(
      429,
      opts,
      %{"error" => "rate_limited", "retry_after" => seconds},
      gettext("Too many requests"),
      [gettext("Please wait %{seconds} seconds and try again.", seconds: seconds)],
      headers
    )
    |> Plug.Conn.halt()
  end

  defp respond(conn, status, opts, json, title, lines, headers \\ []) do
    conn =
      Enum.reduce(headers, conn, fn {k, v}, conn -> Plug.Conn.put_resp_header(conn, k, v) end)

    conn = Plug.Conn.put_resp_header(conn, "cache-control", "no-store")

    if json?(conn, Map.get(opts, :format, :auto)) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(json))
    else
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(status, html(title, lines))
    end
  end

  defp json?(_conn, :json), do: true
  defp json?(_conn, :html), do: false

  defp json?(conn, _auto) do
    accepts_json?(conn) or
      conn.request_path |> String.split("/") |> Enum.any?(&(&1 in ["api", "_api"]))
  end

  defp accepts_json?(conn) do
    case Tracking.first_header(conn, "accept") do
      nil -> false
      accept -> String.contains?(accept, "json") and not String.contains?(accept, "text/html")
    end
  end

  defp html(title, lines) do
    title = title |> Plug.HTML.html_escape() |> IO.iodata_to_binary()
    body = Enum.map_join(lines, "", &"<p>#{Plug.HTML.html_escape(&1)}</p>")

    "<!doctype html><html><head><meta charset=\"utf-8\"><title>#{title}</title></head>" <>
      "<body><h1>#{title}</h1>#{body}</body></html>"
  end

  # ── what is kept ──────────────────────────────────────────────────────────

  defp note_denial(subject, visitor, denial, mode, config) do
    action = if mode == :on, do: :refused, else: :logged
    Ring.bump({:rate_limit, denial.rule, action})
    record(subject, visitor, config, Map.put(denial, :action, action))

    :telemetry.execute(
      [:phoenix_kit_web_analytics, :rate_limit, :deny],
      %{count: 1, retry_after_ms: denial.retry_after_ms},
      %{rule: denial.rule, scope: denial.scope, mode: mode, path: path_of(subject)}
    )
  end

  defp record(subject, visitor, config, denial) do
    Ring.push(@denials, @denials_size, %{
      at: DateTime.utc_now() |> DateTime.truncate(:second),
      rule: denial.rule,
      scope: denial.scope,
      action: denial.action,
      retry_after_ms: denial[:retry_after_ms],
      network: shown_network(visitor, config.store_ip),
      visitor: visitor.visitor_id && String.slice(visitor.visitor_id, 0, 8),
      method: method_of(subject),
      path: path_of(subject)
    })
  end

  # The whole network key only where the operator keeps whole addresses;
  # otherwise its /24 or /48.
  defp shown_network(%{network: network}, :full), do: network
  defp shown_network(%{ip: ip}, _mode), do: Profiles.stored_ip(ip, :truncated)

  # Without a query string (`request_path` has none) and with a one-time
  # token in a path (a password-reset link) redacted, as a stored path is.
  defp path_of(%Plug.Conn{request_path: path}), do: Collector.clean_path(path)
  defp path_of(_subject), do: nil

  defp method_of(%Plug.Conn{method: method}), do: method
  defp method_of(_subject), do: nil

  @doc """
  What the Rate limits page shows: the mode, every known rule with this
  node's counts since it started (`allowed`, `refused`, `logged`), the
  blocklist refusals, and the recent denials, newest first.
  """
  @spec status() :: map()
  def status do
    rules =
      rules()
      |> Map.values()
      |> Enum.sort_by(& &1.name)
      |> Enum.map(fn rule ->
        Map.merge(rule, %{
          allowed: Ring.count({:rate_limit, rule.name, :allowed}),
          refused: Ring.count({:rate_limit, rule.name, :refused}),
          logged: Ring.count({:rate_limit, rule.name, :logged})
        })
      end)

    %{
      mode: Config.collection_config().rate_limit,
      rules: rules,
      blocked: Ring.count({:rate_limit, :blocked, :refused}),
      denials: Ring.list(@denials, @denials_size),
      backend?: backend?()
    }
  end

  @doc "How many denials are kept in memory per node."
  @spec denials_kept() :: pos_integer()
  def denials_kept, do: @denials_size

  defp backend? do
    is_pid(Process.whereis(Backend)) or :ets.whereis(Backend) != :undefined
  rescue
    _ -> false
  end

  defp fail_open(reason) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@warned_key, nil) do
      last when is_integer(last) and now - last < @warn_every_ms ->
        :ok

      _ ->
        :persistent_term.put(@warned_key, now)

        Logger.warning(
          "[WebAnalytics] rate limit not applied (allowing the request): #{describe(reason)}"
        )
    end
  rescue
    _ -> :ok
  end

  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(reason), do: inspect(reason, limit: 5)
end
