defmodule PhoenixKitWebAnalytics.BotScore do
  @moduledoc """
  How much a visitor looks like a bot, and why.

  `is_bot` on an event is a verdict: the visit is dropped from every report.
  This is the evidence behind and beside it — a list of **reasons**, each
  with a weight, and their sum as a **score**. Nothing is dropped or blocked
  because of a score; it is there to be looked at (the Bots page) and to
  decide by.

  A reason is one observable fact, never a guess about intent:

  | Reason | Weight | What was seen |
  |--------|-------:|---------------|
  | `declared_bot` | 100 | the User-Agent says it is a crawler, a library or a monitor |
  | `webdriver` | 90 | the browser reported it was under automation |
  | `no_user_agent` | 70 | no User-Agent at all |
  | `rate` | 70 | more page views a minute than a person reads |
  | `no_js` | 50 | LiveView pages that never connected |
  | `platform_mismatch` | 50 | the device says one system, the User-Agent another |
  | `hosting_network` | 40 | the address belongs to a hosting provider |
  | `software_renderer` | 40 | graphics drawn in software, as headless browsers do |
  | `no_screen` | 40 | a screen or window with no size |
  | `no_languages` | 40 | a browser with no language set |
  | `mobile_from_hosting` | 30 | a phone's User-Agent from a hosting provider |
  | `old_http` | 30 | HTTP/1.0 |
  | `stale_browser` | 30 | a browser version about two years out of date, or Safari before 16 |
  | `touch_mismatch` | 30 | a phone's User-Agent on a device without touch |
  | `no_accept_language` | 25 | no `Accept-Language` header |
  | `no_fetch_metadata` | 25 | a current browser's User-Agent without `Sec-Fetch-*` (HTTPS only) |
  | `no_client_hints` | 20 | a Chromium User-Agent without `Sec-CH-UA` (HTTPS only) |
  | `no_accept` | 15 | no `Accept` header |

  `score/1` is the sum, and `level/1` reads it: 60 and over is `:likely`, 30
  and over `:suspicious`, below that `:low`. The sum is not capped where it is stored,
  so a reason can be added or taken away without the rest being known;
  `percent/1` caps it for display.

  ## Where the reasons come from

  Three sources, each of which owns its reasons and replaces only those when
  it reports again (`merge/3`):

    * `:request` — the User-Agent, the request headers and the network, read
      when a visit starts. Headers and network only when they are kept (see
      `PhoenixKitWebAnalytics.Profiles`): what isn't collected can't count.
    * `:signals` — what the client script measured.
    * `:behaviour` — `PhoenixKitWebAnalytics.BotSignals`' verdicts.
  """

  alias PhoenixKitWebAnalytics.UserAgent

  @weights %{
    "declared_bot" => 100,
    "webdriver" => 90,
    "no_user_agent" => 70,
    "rate" => 70,
    "no_js" => 50,
    "platform_mismatch" => 50,
    "hosting_network" => 40,
    "software_renderer" => 40,
    "no_screen" => 40,
    "no_languages" => 40,
    "mobile_from_hosting" => 30,
    "old_http" => 30,
    "stale_browser" => 30,
    "touch_mismatch" => 30,
    "no_accept_language" => 25,
    "no_fetch_metadata" => 25,
    "no_client_hints" => 20,
    "no_accept" => 15
  }

  @owned %{
    request: ~w(declared_bot no_user_agent hosting_network mobile_from_hosting old_http
         stale_browser no_accept_language no_fetch_metadata no_client_hints no_accept),
    signals: ~w(platform_mismatch software_renderer no_screen no_languages touch_mismatch),
    behaviour: ~w(webdriver rate no_js)
  }

  @likely 60
  @suspicious 30

  @software_renderers ~w(swiftshader llvmpipe softpipe)

  # Chrome (and Edge, which follows its numbers) and Firefox ship a major
  # version every four weeks: the current one is estimated from a known
  # release instead of a list that would need updating. Browsers update
  # themselves, so one this far behind is a script's frozen User-Agent far
  # more often than a person's.
  @release_anchors %{
    "Chrome" => {120, ~D[2023-12-05]},
    "Edge" => {120, ~D[2023-12-07]},
    "Firefox" => {120, ~D[2023-11-21]}
  }
  @release_days 28
  @stale_releases 24
  # Safari moves once a year; before 16 (2022) is out of date.
  @oldest_safari 16

  @type reason :: String.t()
  @type source :: :request | :signals | :behaviour
  @type level :: :likely | :suspicious | :low

  @doc "Every reason with its weight."
  @spec weights() :: %{reason() => pos_integer()}
  def weights, do: @weights

  @doc "A reason's weight; `0` for one this module doesn't know."
  @spec weight(reason()) :: non_neg_integer()
  def weight(reason), do: Map.get(@weights, reason, 0)

  @doc "The reasons a source owns."
  @spec owned(source()) :: [reason()]
  def owned(source), do: Map.fetch!(@owned, source)

  @doc """
  The reasons read from one kind of stored data (a `Profiles.forget/1`
  kind) — what stops being true to say once that data is forgotten. Finer
  than `owned/1`: the request's reasons come from three kinds of data, and
  forgetting the headers says nothing about the network.

  The User-Agent's reasons aren't here: it is read on every hit whether or
  not it is kept, so forgetting the stored copy changes nothing.
  """
  @spec derived_from(atom()) :: [reason()]
  def derived_from(:headers),
    do: ~w(old_http no_accept_language no_fetch_metadata no_client_hints no_accept)

  def derived_from(:network), do: ~w(hosting_network mobile_from_hosting)
  def derived_from(:signals), do: owned(:signals)
  def derived_from(_kind), do: []

  @doc "The sum of the reasons' weights — what is stored."
  @spec score([reason()]) :: non_neg_integer()
  def score(reasons) when is_list(reasons),
    do: reasons |> Enum.uniq() |> Enum.reduce(0, &(weight(&1) + &2))

  @doc "A stored score as shown: 0–100."
  @spec percent(integer() | nil) :: 0..100
  def percent(score) when is_integer(score), do: score |> max(0) |> min(100)
  def percent(_score), do: 0

  @doc "The score a level starts at."
  @spec threshold(:likely | :suspicious) :: pos_integer()
  def threshold(:likely), do: @likely
  def threshold(:suspicious), do: @suspicious

  @doc "What a score amounts to."
  @spec level(integer() | nil) :: level()
  def level(score) when is_integer(score) and score >= @likely, do: :likely
  def level(score) when is_integer(score) and score >= @suspicious, do: :suspicious
  def level(_score), do: :low

  @doc """
  `current` with `source`'s reasons replaced by `found`: the reasons other
  sources reported stay. Sorted heaviest first.

      iex> PhoenixKitWebAnalytics.BotScore.merge(["rate", "no_accept"], :request, ["old_http"])
      ["rate", "old_http"]
  """
  @spec merge([reason()], source(), [reason()]) :: [reason()]
  def merge(current, source, found) do
    mine = owned(source)

    (current || [])
    |> Enum.reject(&(&1 in mine))
    |> Kernel.++(Enum.filter(found, &(&1 in mine)))
    |> sort()
  end

  @doc "Reasons without repeats, heaviest first (then by name)."
  @spec sort([reason()]) :: [reason()]
  def sort(reasons), do: reasons |> Enum.uniq() |> Enum.sort_by(&{-weight(&1), &1})

  @doc """
  What a visit's first request says. `evidence`:

    * `:user_agent` — the raw header (always at hand, kept or not)
    * `:headers` — the header profile `Profiles.request_headers/2` builds, or
      `nil` when headers aren't kept (then nothing is read from them)
    * `:hosting` — `true` when the network is a hosting provider's
    * `:today` — the date browser versions are judged at (today by default)
  """
  @spec request_reasons(map()) :: [reason()]
  def request_reasons(evidence) do
    ua = evidence[:user_agent]
    parsed = UserAgent.parse(ua)
    hosting? = evidence[:hosting] == true
    mobile? = parsed.device_type in ["mobile", "tablet"]

    [
      {"declared_bot", UserAgent.bot?(ua)},
      {"no_user_agent", ua in [nil, ""]},
      {"hosting_network", hosting?},
      {"mobile_from_hosting", hosting? and mobile?},
      {"stale_browser", stale_browser?(parsed, evidence[:today] || judged_on())}
      | header_reasons(evidence[:headers], parsed)
    ]
    |> found()
  end

  @doc """
  What the client script's measurements say, given the User-Agent they came
  with. Takes the validated map (`Profiles.signals/1`).
  """
  @spec signal_reasons(map(), String.t() | nil) :: [reason()]
  def signal_reasons(signals, user_agent) when is_map(signals) do
    parsed = UserAgent.parse(user_agent)

    found([
      {"platform_mismatch", platform_mismatch?(signals["plat"], parsed.os)},
      {"software_renderer", software_renderer?(signals["gr"])},
      {"no_screen", no_screen?(signals)},
      {"no_languages", signals["langs"] == []},
      {"touch_mismatch", parsed.device_type == "mobile" and signals["tp"] == 0}
    ])
  end

  def signal_reasons(_signals, _user_agent), do: []

  # ── internals ─────────────────────────────────────────────────────────────

  defp found(checks), do: for({reason, true} <- checks, do: reason)

  defp header_reasons(%{"names" => names} = headers, parsed) when is_list(names) do
    https? = headers["scheme"] == "https"
    major = major(parsed.browser_version)

    [
      {"old_http", headers["http"] == "HTTP/1.0"},
      {"no_accept_language", "accept-language" not in names},
      {"no_accept", "accept" not in names},
      # Browsers send both only to a secure origin, so a plain-HTTP site
      # can't expect them.
      {"no_fetch_metadata",
       https? and sends_fetch_metadata?(parsed.browser, major) and
         not Enum.any?(names, &String.starts_with?(&1, "sec-fetch-"))},
      {"no_client_hints",
       https? and chromium?(parsed.browser) and major >= 90 and "sec-ch-ua" not in names}
    ]
  end

  defp header_reasons(_headers, _parsed), do: []

  # The day browser versions are judged at. A suite whose fixtures carry
  # fixed User-Agents pins it (`config :phoenix_kit_web_analytics,
  # :browser_versions_as_of, ~D[...]`), or every fixture would go stale.
  defp judged_on,
    do:
      Application.get_env(:phoenix_kit_web_analytics, :browser_versions_as_of) || Date.utc_today()

  defp stale_browser?(%{browser: "Safari", browser_version: version}, _today)
       when is_binary(version),
       do: major(version) in 1..(@oldest_safari - 1)

  defp stale_browser?(%{browser: browser, browser_version: version}, today)
       when is_binary(version) do
    case @release_anchors do
      %{^browser => {anchor_version, anchor_date}} ->
        current = anchor_version + div(Date.diff(today, anchor_date), @release_days)
        major(version) in 1..(current - @stale_releases)//1

      _ ->
        false
    end
  end

  defp stale_browser?(_parsed, _today), do: false

  defp chromium?(browser),
    do: browser in ["Chrome", "Edge", "Opera", "Vivaldi", "Brave", "Samsung Internet"]

  defp sends_fetch_metadata?(browser, major) do
    (chromium?(browser) and major >= 80) or (browser == "Firefox" and major >= 90) or
      (browser == "Safari" and major >= 17)
  end

  defp major(version) when is_binary(version) do
    case Integer.parse(version) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp major(_version), do: 0

  # `navigator.platform` against the system the User-Agent names. Only the
  # clear contradictions: an unknown on either side says nothing.
  defp platform_mismatch?(platform, os) when is_binary(platform) do
    family = platform_family(platform)
    expected = os_family(os)

    family != nil and expected != nil and family != expected
  end

  defp platform_mismatch?(_platform, _os), do: false

  defp platform_family("Win" <> _), do: :windows
  defp platform_family("Mac" <> _), do: :apple
  defp platform_family(platform) when platform in ["iPhone", "iPad", "iPod"], do: :apple
  defp platform_family("Linux" <> _), do: :linux
  defp platform_family(_platform), do: nil

  defp os_family("Windows"), do: :windows
  # An iPad asking for the desktop site calls itself a Mac.
  defp os_family(os) when os in ["macOS", "iOS"], do: :apple
  # Android's platform is "Linux armv8l".
  defp os_family(os) when os in ["Android", "Linux", "Ubuntu", "Chrome OS"], do: :linux
  defp os_family(_os), do: nil

  defp software_renderer?(renderer) when is_binary(renderer) do
    downcased = String.downcase(renderer)
    Enum.any?(@software_renderers, &String.contains?(downcased, &1))
  end

  defp software_renderer?(_renderer), do: false

  defp no_screen?(signals) do
    Enum.any?(["sw", "sh", "ow", "oh"], &(signals[&1] == 0))
  end
end
