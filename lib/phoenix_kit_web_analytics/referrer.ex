defmodule PhoenixKitWebAnalytics.Referrer do
  @moduledoc """
  Turns a raw `Referer` header into a `{source, medium}` pair for reporting.

  `source` is a human-readable name ("Google", "Hacker News") when the host is
  recognised, otherwise the bare host ("example.com"). `medium` is one of
  `"none"`, `"organic"`, `"social"`, `"referral"`, `"internal"`, `"email"`.

  UTM parameters, when present, take precedence over the header — that's what
  `utm_medium` in a campaign URL means — but that resolution lives in
  `PhoenixKitWebAnalytics.Collector`, not here. This module only reads the
  referrer.

      iex> PhoenixKitWebAnalytics.Referrer.classify("https://www.google.com/search?q=x", "myapp.com")
      {"Google", "organic"}

      iex> PhoenixKitWebAnalytics.Referrer.classify(nil, "myapp.com")
      {nil, "none"}

      iex> PhoenixKitWebAnalytics.Referrer.classify("https://myapp.com/blog", "myapp.com")
      {nil, "internal"}
  """

  # These are ORDERED LISTS, not maps: the first match wins and several keys
  # overlap (mail.google.com is email, not search; t.co is X while t.me is
  # Telegram). A map would leave the winner up to term ordering.
  #
  # Webmail hosts come first for exactly that reason — a link out of Gmail is a
  # mail click, even though "google" is also in the host.
  @email [
    {"mail", "Email"},
    {"gmail", "Email"},
    {"outlook", "Email"},
    {"webmail", "Email"},
    {"roundcube", "Email"},
    {"zimbra", "Email"}
  ]

  @search_engines [
    {"google", "Google"},
    {"bing", "Bing"},
    {"duckduckgo", "DuckDuckGo"},
    {"yahoo", "Yahoo"},
    {"yandex", "Yandex"},
    {"baidu", "Baidu"},
    {"ecosia", "Ecosia"},
    {"startpage", "Startpage"},
    {"search.brave.com", "Brave Search"},
    {"qwant", "Qwant"},
    {"kagi", "Kagi"},
    {"perplexity", "Perplexity"},
    {"chatgpt", "ChatGPT"},
    {"openai", "ChatGPT"},
    {"claude.ai", "Claude"},
    {"gemini.google.com", "Gemini"},
    {"copilot.microsoft.com", "Copilot"}
  ]

  @social [
    {"news.ycombinator.com", "Hacker News"},
    {"lobste.rs", "Lobsters"},
    {"t.co", "X (Twitter)"},
    {"x.com", "X (Twitter)"},
    {"twitter", "X (Twitter)"},
    {"t.me", "Telegram"},
    {"telegram", "Telegram"},
    {"facebook", "Facebook"},
    {"fb.com", "Facebook"},
    {"instagram", "Instagram"},
    {"linkedin", "LinkedIn"},
    {"lnkd.in", "LinkedIn"},
    {"reddit", "Reddit"},
    {"youtube", "YouTube"},
    {"youtu.be", "YouTube"},
    {"tiktok", "TikTok"},
    {"pinterest", "Pinterest"},
    {"mastodon", "Mastodon"},
    {"bsky.app", "Bluesky"},
    {"threads", "Threads"},
    {"whatsapp", "WhatsApp"},
    {"discord", "Discord"},
    {"slack", "Slack"},
    {"vk.com", "VK"},
    {"tumblr", "Tumblr"},
    {"quora", "Quora"},
    {"medium.com", "Medium"},
    {"substack", "Substack"},
    {"producthunt", "Product Hunt"},
    {"github", "GitHub"},
    {"stackoverflow", "Stack Overflow"}
  ]

  @doc """
  Classifies a referrer against the current request host.

  Passing the request host is what makes internal navigation distinguishable
  from an inbound referral — without it, every in-site link click would inflate
  the referrers report.
  """
  @spec classify(String.t() | nil, String.t() | nil) :: {String.t() | nil, String.t()}
  def classify(referrer, site_host \\ nil)

  def classify(nil, _site_host), do: {nil, "none"}
  def classify("", _site_host), do: {nil, "none"}

  def classify(referrer, site_host) when is_binary(referrer) do
    case host_of(referrer) do
      nil -> {nil, "none"}
      host -> classify_host(host, site_host)
    end
  end

  def classify(_referrer, _site_host), do: {nil, "none"}

  @doc """
  The bare host of a referrer URL, with any leading `www.` removed.

      iex> PhoenixKitWebAnalytics.Referrer.host_of("https://www.Example.com/a/b?c=1")
      "example.com"
  """
  @spec host_of(String.t() | nil) :: String.t() | nil
  def host_of(nil), do: nil

  def host_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> normalize_host(host)
      _ -> nil
    end
  end

  def host_of(_url), do: nil

  @doc """
  Lowercases a host and drops a leading `www.`, so `myapp.com` and
  `WWW.MyApp.com` compare equal.
  """
  @spec normalize_host(String.t() | nil) :: String.t() | nil
  def normalize_host(nil), do: nil

  def normalize_host(host) when is_binary(host),
    do: host |> String.downcase() |> String.replace_prefix("www.", "")

  def normalize_host(_host), do: nil

  # ── internals ─────────────────────────────────────────────────────────────

  defp classify_host(host, site_host) do
    if host == normalize_host(site_host) do
      {nil, "internal"}
    else
      lookup(host)
    end
  end

  defp lookup(host) do
    labels = String.split(host, ".")

    cond do
      name = match(@email, host, labels) -> {name, "email"}
      name = match(@search_engines, host, labels) -> {name, "organic"}
      name = match(@social, host, labels) -> {name, "social"}
      true -> {host, "referral"}
    end
  end

  # Match on domain labels rather than substrings, so "notgoogle.com" and
  # "mybing.example" aren't credited to a search engine. A key containing a dot
  # is matched as a whole domain (exactly, or as a suffix after a dot).
  defp match(table, host, labels) do
    Enum.find_value(table, fn {key, name} -> if matches?(key, host, labels), do: name end)
  end

  defp matches?(key, host, labels) do
    if domain_key?(key) do
      host == key or String.ends_with?(host, "." <> key)
    else
      key in labels
    end
  end

  defp domain_key?(key), do: String.contains?(key, ".")
end
