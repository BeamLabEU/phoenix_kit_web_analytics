defmodule PhoenixKitWebAnalytics.RateLimitTest do
  @moduledoc """
  `RateLimit.Plug` and `RateLimit.charge/3`: per visitor and per network,
  the exemptions, the blocklist, log-only, failing open, and what is kept.
  """

  use PhoenixKitWebAnalytics.DataCase, async: false

  import Plug.Test, only: [conn: 2]

  alias PhoenixKitWebAnalytics.Admin
  alias PhoenixKitWebAnalytics.RateLimit
  alias PhoenixKitWebAnalytics.RateLimit.Plug, as: LimitPlug
  alias PhoenixKitWebAnalytics.Ring

  @firefox "Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0"

  setup do
    start_supervised!(PhoenixKit.Users.RateLimiter.Backend)
    start_supervised!(Ring)
    enable_tracking()
    assert is_binary(PhoenixKitWebAnalytics.Config.hash_salt())
    clear_settings_cache()
    on_exit(fn -> Application.delete_env(:phoenix_kit_web_analytics, :rate_limit) end)
    :ok
  end

  defp opts(rules, extra \\ []), do: LimitPlug.init([rules: rules] ++ extra)

  defp request(path, opts, attrs \\ []) do
    method = Keyword.get(attrs, :method, :get)
    ip = Keyword.get(attrs, :ip, {203, 0, 113, 5})
    ua = Keyword.get(attrs, :ua, @firefox)

    method
    |> conn(path)
    |> Map.put(:remote_ip, ip)
    |> Map.put(:host, Keyword.get(attrs, :host, "example.com"))
    |> Plug.Conn.put_req_header("user-agent", ua)
    |> then(fn conn ->
      Enum.reduce(Keyword.get(attrs, :headers, []), conn, fn {k, v}, conn ->
        Plug.Conn.put_req_header(conn, k, v)
      end)
    end)
    |> LimitPlug.call(opts)
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  describe "the plug" do
    test "allows a visitor under the limit and refuses them over it" do
      opts = opts([[name: :t_visitor, paths: ["/search*"], limit: 2, network_limit: 100]])

      refute request("/search", opts).halted
      refute request("/search?q=x", opts).halted
      denied = request("/search", opts)

      assert denied.halted
      assert denied.status == 429
      assert String.to_integer(header(denied, "retry-after")) in 1..60
      assert header(denied, "ratelimit-limit") == "2"
      assert header(denied, "ratelimit-remaining") == "0"
      assert header(denied, "ratelimit-reset") == header(denied, "retry-after")
      assert header(denied, "content-type") =~ "text/html"
      assert denied.resp_body =~ "Too many requests"

      # Another path the rule doesn't cover is not counted.
      refute request("/about", opts).halted
    end

    test "counts per network too: a fresh User-Agent per request doesn't help" do
      opts = opts([[name: :t_network, paths: ["/search"], limit: 10, network_limit: 3]])

      for n <- 1..3, do: refute(request("/search", opts, ua: "agent #{n}").halted)
      denied = request("/search", opts, ua: "agent 4")

      assert denied.status == 429
      assert header(denied, "ratelimit-limit") == "3"
      assert [%{rule: :t_network, scope: :network}] = RateLimit.status().denials

      # Another network still has its own room.
      refute request("/search", opts, ua: "agent 5", ip: {198, 51, 100, 9}).halted
    end

    test "the network limit defaults to four times the visitor's" do
      assert [%{limit: 5, network_limit: 20}] = opts([[name: :t_x, limit: 5]]).rules
    end

    test "answers JSON on an API path or to a client that asks for it" do
      opts = opts([[name: :t_json, paths: ["/bank/_api/*", "/feed"], limit: 1]])

      request("/bank/_api/ai/search", opts)
      denied = request("/bank/_api/ai/search", opts)

      assert header(denied, "content-type") =~ "application/json"
      assert %{"error" => "rate_limited", "retry_after" => n} = Jason.decode!(denied.resp_body)
      assert is_integer(n) and n >= 1

      request("/feed", opts, ip: {198, 51, 100, 1}, headers: [{"accept", "application/json"}])

      denied =
        request("/feed", opts, ip: {198, 51, 100, 1}, headers: [{"accept", "application/json"}])

      assert header(denied, "content-type") =~ "application/json"
    end

    test "only the listed methods are counted" do
      opts = opts([[name: :t_methods, paths: ["/form"], methods: ["get"], limit: 1]])

      for _ <- 1..3, do: refute(request("/form", opts, method: :post).halted)
      refute request("/form", opts).halted
      assert request("/form", opts).halted
    end

    test "on_deny renders the host's own refusal" do
      opts =
        opts([[name: :t_on_deny, paths: ["/x"], limit: 1]],
          on_deny: {__MODULE__, :teapot, ["extra"]}
        )

      request("/x", opts)
      denied = request("/x", opts)

      assert denied.halted
      assert denied.status == 418
      assert denied.resp_body == "t_on_deny extra"
    end

    test "a locale prefix is the same page" do
      opts = opts([[name: :t_locale, paths: ["/search"], limit: 1]])

      refute request("/search", opts).halted
      assert request("/et/search", opts).halted
    end
  end

  def teapot(conn, denial, extra),
    do: Plug.Conn.send_resp(conn, 418, "#{denial.rule} #{extra}")

  def always_exempt(_conn), do: true

  describe "exemptions" do
    test "the internal networks are never limited" do
      enable_tracking(%{"web_analytics_internal_networks_secret" => "203.0.113.0/24"})
      opts = opts([[name: :t_internal, paths: ["/x"], limit: 1]])

      for _ <- 1..3, do: refute(request("/x", opts).halted)
      assert request("/x", opts, ip: {198, 51, 100, 2}) |> Map.get(:halted) == false
      assert request("/x", opts, ip: {198, 51, 100, 2}).halted
    end

    test "the bypass token from app config, compared in constant time" do
      Application.put_env(:phoenix_kit_web_analytics, :rate_limit,
        bypass_token: "a-long-enough-test-token"
      )

      opts = opts([[name: :t_bypass, paths: ["/x"], limit: 1]])
      good = [headers: [{"x-rate-limit-bypass", "a-long-enough-test-token"}]]
      bad = [headers: [{"x-rate-limit-bypass", "a-long-enough-test-tokem"}]]

      for _ <- 1..3, do: refute(request("/x", opts, good).halted)
      refute request("/x", opts, bad).halted
      assert request("/x", opts, bad).halted
    end

    test "a token shorter than 16 bytes never bypasses" do
      Application.put_env(:phoenix_kit_web_analytics, :rate_limit, bypass_token: "short")
      opts = opts([[name: :t_short, paths: ["/x"], limit: 1]])
      given = [headers: [{"x-rate-limit-bypass", "short"}]]

      refute request("/x", opts, given).halted
      assert request("/x", opts, given).halted
    end

    test "a loopback peer asking for localhost, unless turned off" do
      local = [ip: {127, 0, 0, 1}, host: "localhost"]
      opts = opts([[name: :t_local, paths: ["/x"], limit: 1]])
      for _ <- 1..3, do: refute(request("/x", opts, local).halted)

      strict = opts([[name: :t_local_strict, paths: ["/x"], limit: 1]], exempt_local: false)
      refute request("/x", strict, local).halted
      assert request("/x", strict, local).halted

      # A proxy on the same box serving the public host is not "local".
      proxied = opts([[name: :t_local_proxied, paths: ["/x"], limit: 1]])
      refute request("/x", proxied, ip: {127, 0, 0, 1}).halted
      assert request("/x", proxied, ip: {127, 0, 0, 1}).halted
    end

    test "the host's exempt function" do
      opts =
        opts([[name: :t_exempt, paths: ["/x"], limit: 1]],
          exempt: {__MODULE__, :always_exempt, []}
        )

      for _ <- 1..3, do: refute(request("/x", opts).halted)
    end
  end

  describe "the blocklist" do
    test "a blocked network is refused with 403 on every path" do
      enable_tracking(%{"web_analytics_blocked_networks_secret" => "198.51.100.0/24\n192.0.2.7"})
      opts = opts([])

      blocked = request("/anything", opts, ip: {198, 51, 100, 77})
      assert blocked.halted
      assert blocked.status == 403

      assert request("/anything", opts, ip: {192, 0, 2, 7}).status == 403
      refute request("/anything", opts, ip: {192, 0, 2, 8}).halted
      assert [%{rule: :blocked, action: :blocked}, _] = RateLimit.status().denials
    end

    test "Settings refuses a network too wide to block, and a line that isn't one" do
      assert {:error, [:blocked_networks_wide]} =
               Admin.save_settings(%{"blocked_networks" => "10.0.0.0/4"})

      assert {:error, [:blocked_networks]} =
               Admin.save_settings(%{"blocked_networks" => "not a network"})

      assert {:ok, _} = Admin.save_settings(%{"blocked_networks" => "198.51.100.0/24"})
    end
  end

  describe "modes" do
    test "log only counts and records, and lets everything through" do
      enable_tracking(%{"web_analytics_rate_limit" => "log_only"})
      opts = opts([[name: :t_log, paths: ["/x"], limit: 1]])

      for _ <- 1..3, do: refute(request("/x?secret=1", opts).halted)

      status = RateLimit.status()
      assert status.mode == :log_only
      assert %{allowed: 1, logged: 2, refused: 0} = Enum.find(status.rules, &(&1.name == :t_log))
      assert [%{action: :logged, path: "/x"}, %{action: :logged}] = status.denials
      refute inspect(status.denials) =~ "secret"
    end

    test "off skips everything, the blocklist included" do
      enable_tracking(%{
        "web_analytics_rate_limit" => "off",
        "web_analytics_blocked_networks_secret" => "203.0.113.0/24"
      })

      opts = opts([[name: :t_off, paths: ["/x"], limit: 1]])
      for _ <- 1..3, do: refute(request("/x", opts).halted)
      assert RateLimit.status().denials == []
    end

    @tag capture_log: true
    test "fails open, without raising, when the counters aren't there" do
      stop_supervised!(PhoenixKit.Users.RateLimiter.Backend)
      opts = opts([[name: :t_open, paths: ["/x"], limit: 1]])

      for _ <- 1..3, do: refute(request("/x", opts).halted)
      assert RateLimit.charge(request("/y", opts), :t_open) == :ok
    end
  end

  describe "charge/3 and check/3" do
    test "charge from code; check peeks without charging" do
      opts = opts([[name: :t_ai, limit: 2, window_ms: 60_000]])
      conn = request("/bank/all", opts)
      # No paths: the plug itself never counted it.
      refute conn.halted

      assert RateLimit.check(conn, :t_ai) == :ok
      assert RateLimit.check(conn, :t_ai) == :ok
      assert RateLimit.charge(conn, :t_ai) == :ok
      assert RateLimit.charge(conn, :t_ai) == :ok

      assert {:error, %{rule: :t_ai, scope: :visitor, limit: 2, retry_after_ms: ms}} =
               RateLimit.check(conn, :t_ai)

      assert ms in 1..60_000
      assert {:error, %{scope: :visitor} = denial} = RateLimit.charge(conn, :t_ai, 1)

      denied = RateLimit.deny(conn, denial)
      assert denied.status == 429 and denied.halted
      assert [%{rule: :t_ai, action: :refused}] = RateLimit.status().denials
    end

    test "a cost charges that many units" do
      conn = request("/", opts([[name: :t_cost, limit: 5]]))

      assert RateLimit.charge(conn, :t_cost, 4) == :ok
      assert {:error, _} = RateLimit.charge(conn, :t_cost, 2)
    end

    test "rules from app config are known without a plug; an unknown rule is :ok" do
      Application.put_env(:phoenix_kit_web_analytics, :rate_limit,
        rules: [[name: :t_configured, limit: 1]]
      )

      conn = conn(:get, "/") |> Map.put(:remote_ip, {203, 0, 113, 9})

      assert RateLimit.charge(conn, :t_configured) == :ok
      assert {:error, _} = RateLimit.charge(conn, :t_configured)
      assert RateLimit.charge(conn, :t_nobody_defined) == :ok
    end

    test "a visitor map works where there is no conn" do
      conn = request("/", opts([[name: :t_map, limit: 1]]))
      visitor = PhoenixKitWebAnalytics.visitor(conn)

      assert RateLimit.charge(visitor, :t_map) == :ok
      assert {:error, _} = RateLimit.charge(visitor, :t_map)
    end

    test "an exempt request stays exempt for charge/3" do
      enable_tracking(%{"web_analytics_internal_networks_secret" => "203.0.113.0/24"})
      conn = request("/", opts([[name: :t_charge_exempt, limit: 1]]))

      for _ <- 1..3, do: assert(RateLimit.charge(conn, :t_charge_exempt) == :ok)
    end

    test "log only answers :ok and records" do
      enable_tracking(%{"web_analytics_rate_limit" => "log_only"})
      conn = request("/", opts([[name: :t_charge_log, limit: 1]]))

      assert RateLimit.charge(conn, :t_charge_log) == :ok
      assert RateLimit.charge(conn, :t_charge_log) == :ok
      assert [%{action: :logged}] = RateLimit.status().denials
    end
  end

  describe "what is kept" do
    test "a denial shows the network's /24 unless whole addresses are kept" do
      opts = opts([[name: :t_mask, paths: ["/x"], limit: 1]])
      request("/x", opts)
      request("/x", opts)

      assert [%{network: "203.0.113.0/24", visitor: prefix, method: "GET"}] =
               RateLimit.status().denials

      assert byte_size(prefix) == 8

      Ring.clear(:rate_limit_denials)
      enable_tracking(%{"web_analytics_store_ip" => "full"})
      request("/x", opts)

      assert [%{network: "203.0.113.5"}] = RateLimit.status().denials
    end

    test "a one-time token in a refused path is not kept" do
      opts = opts([[name: :t_token, paths: ["/users/*"], limit: 1]])
      request("/users/reset-password/SFMyNTY.secret-token", opts)
      request("/users/reset-password/SFMyNTY.secret-token", opts)

      assert [%{path: "/users/reset-password/:token"}] = RateLimit.status().denials
    end

    test "a denial emits telemetry" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "rate-limit-test",
        [:phoenix_kit_web_analytics, :rate_limit, :deny],
        fn _event, measurements, metadata, _ -> send(parent, {ref, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("rate-limit-test") end)

      opts = opts([[name: :t_telemetry, paths: ["/x"], limit: 1]])
      request("/x", opts)
      request("/x", opts)

      assert_received {^ref, %{count: 1, retry_after_ms: _},
                       %{rule: :t_telemetry, scope: :visitor, mode: :on, path: "/x"}}
    end
  end
end

defmodule PhoenixKitWebAnalytics.Web.RateLimitsLiveTest do
  @moduledoc """
  The Rate limits page and the rate-limit section of Settings.
  """

  use PhoenixKitWebAnalytics.LiveCase, async: false

  alias PhoenixKitWebAnalytics.RateLimit.Plug, as: LimitPlug
  alias PhoenixKitWebAnalytics.Ring

  setup do
    start_supervised!(PhoenixKit.Users.RateLimiter.Backend)
    start_supervised!(Ring)
    enable_tracking()
    :ok
  end

  defp hit(opts, path) do
    Plug.Test.conn(:get, path)
    |> Map.put(:remote_ip, {203, 0, 113, 5})
    |> Map.put(:host, "example.com")
    |> LimitPlug.call(opts)
  end

  test "shows the rules, their counts and the latest refusals", %{conn: conn} do
    opts = LimitPlug.init(rules: [[name: :page_search, paths: ["/search"], limit: 1]])
    hit(opts, "/search")
    hit(opts, "/search")

    {:ok, view, html} = live(conn, "/admin/web-analytics/rate-limits")

    assert html =~ "Rate limits are on"
    rules = view |> element("#rate-limit-rules") |> render()
    assert rules =~ "page_search"
    assert rules =~ "/search"

    denials = view |> element("#rate-limit-denials") |> render()
    assert denials =~ "203.0.113.0/24"
    assert denials =~ "GET /search"
    refute denials =~ "203.0.113.5"
  end

  test "an empty page when nothing is installed or refused", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/web-analytics/rate-limits")
    assert html =~ "Nothing has been refused."
  end

  test "Settings saves the mode and the blocked networks", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/web-analytics/settings")
    assert html =~ "Blocked networks"

    view
    |> form("#web-analytics-settings", %{
      "rate_limit" => "log_only",
      "blocked_networks" => "198.51.100.0/24"
    })
    |> render_submit()

    clear_settings_cache()
    config = PhoenixKitWebAnalytics.Config.collection_config()
    assert config.rate_limit == :log_only
    assert config.blocked_networks == ["198.51.100.0/24"]
  end
end
