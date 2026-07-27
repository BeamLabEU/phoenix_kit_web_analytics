defmodule PhoenixKitWebAnalytics.UserAgent do
  @moduledoc """
  A deliberately small User-Agent classifier: browser, OS, device class, and
  "does this look automated".

  ## Why not a UA-parsing library

  Full parsers ship a regex database of thousands of entries and refresh it on
  a release cadence. This module recognises the families that actually show up
  in aggregate reports and labels everything else `"Other"` — which is the
  honest answer for a long tail that would otherwise be a hundred one-row
  entries in the browsers table. No dependency, no database to keep current,
  and the parse is a handful of regex matches on a string we already have.

  ## What it deliberately does not do

  This is classification, not fingerprinting. Nothing here is combined with
  anything else to make a durable identifier: `visitor_id` is built from a
  daily-rotating salted hash (see `PhoenixKitWebAnalytics.Visitor`), and the
  raw User-Agent string is never stored.

      iex> PhoenixKitWebAnalytics.UserAgent.parse("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36").browser
      "Chrome"

      iex> PhoenixKitWebAnalytics.UserAgent.parse("Googlebot/2.1 (+http://www.google.com/bot.html)").bot?
      true
  """

  @type t :: %{
          browser: String.t(),
          browser_version: String.t() | nil,
          os: String.t(),
          os_version: String.t() | nil,
          device_type: String.t(),
          bot?: boolean()
        }

  # Ordered: the first match wins, so more specific families come first.
  # Edge/Opera/Samsung all claim "Chrome", and Chrome claims "Safari".
  @browsers [
    {"Edge", ~r{Edge?[/ ](\d+[\d.]*)}},
    {"Opera", ~r{(?:OPR|Opera)[/ ](\d+[\d.]*)}},
    {"Vivaldi", ~r{Vivaldi/(\d+[\d.]*)}},
    {"Brave", ~r{Brave/(\d+[\d.]*)}},
    {"Samsung Internet", ~r{SamsungBrowser/(\d+[\d.]*)}},
    {"Yandex Browser", ~r{YaBrowser/(\d+[\d.]*)}},
    {"Firefox", ~r{(?:Firefox|FxiOS)/(\d+[\d.]*)}},
    {"Chrome", ~r{(?:Chrome|CriOS|Chromium)/(\d+[\d.]*)}},
    {"Safari", ~r{Version/(\d+[\d.]*).*Safari}},
    {"Internet Explorer", ~r{(?:MSIE |rv:)(\d+[\d.]*).*Trident}}
  ]

  @operating_systems [
    {"Windows", ~r{Windows NT (\d+[\d.]*)}},
    {"Android", ~r{Android (\d+[\d.]*)}},
    {"iOS", ~r{(?:iPhone|iPad|iPod).*OS (\d+[\d_]*)}},
    {"macOS", ~r{Mac OS X (\d+[\d_.]*)}},
    {"Chrome OS", ~r{CrOS \S+ (\d+[\d.]*)}},
    {"Ubuntu", ~r{Ubuntu}},
    {"Linux", ~r{Linux}},
    {"FreeBSD", ~r{FreeBSD}}
  ]

  # Substring markers (already downcased) rather than one giant regex: cheaper,
  # and easier to extend without re-reasoning about alternation order.
  @bot_markers ~w(
    bot crawl spider slurp scrap fetcher curl wget python-requests go-http-client
    java/ okhttp libwww-perl httpclient axios node-fetch headless phantomjs
    lighthouse pagespeed gtmetrix pingdom uptime monitor statuscake
    facebookexternalhit whatsapp telegrambot twitterbot linkedinbot slackbot
    discordbot embedly quora preview feedly rss-parser semrush ahrefs mj12
    dotbot dataprovider zgrab masscan censys expanse
  )

  @unknown %{
    browser: "Unknown",
    browser_version: nil,
    os: "Unknown",
    os_version: nil,
    device_type: "unknown",
    bot?: false
  }

  @doc """
  Parses a User-Agent header.

  An empty or missing header yields all-`"Unknown"` with `bot?: false` — a
  client that sends no UA is unusual but not necessarily automated, and
  guessing "bot" there would silently drop real traffic.
  """
  @spec parse(String.t() | nil) :: t()
  def parse(nil), do: @unknown
  def parse(""), do: @unknown

  def parse(user_agent) when is_binary(user_agent) do
    downcased = String.downcase(user_agent)

    if bot?(downcased) do
      %{@unknown | browser: "Bot", os: "Bot", device_type: "bot", bot?: true}
    else
      {browser, browser_version} = match_first(@browsers, user_agent)
      {os, os_version} = match_first(@operating_systems, user_agent)

      %{
        browser: browser,
        browser_version: browser_version,
        os: os,
        os_version: normalize_os_version(os_version),
        device_type: device_type(user_agent, downcased),
        bot?: false
      }
    end
  end

  def parse(_user_agent), do: @unknown

  @doc """
  Whether the User-Agent looks automated.

  Accepts the raw header; matching is case-insensitive.
  """
  @spec bot?(String.t() | nil) :: boolean()
  def bot?(nil), do: false

  def bot?(user_agent) when is_binary(user_agent) do
    downcased = String.downcase(user_agent)
    Enum.any?(@bot_markers, &String.contains?(downcased, &1))
  end

  def bot?(_user_agent), do: false

  # ── internals ─────────────────────────────────────────────────────────────

  defp match_first(patterns, user_agent) do
    Enum.find_value(patterns, {"Other", nil}, fn {name, regex} ->
      case Regex.run(regex, user_agent) do
        [_full, version | _] -> {name, version}
        [_full] -> {name, nil}
        nil -> nil
      end
    end)
  end

  # Apple reports "10_15_7"; report it the way people write it.
  defp normalize_os_version(nil), do: nil
  defp normalize_os_version(version), do: String.replace(version, "_", ".")

  defp device_type(user_agent, downcased) do
    cond do
      String.contains?(user_agent, "iPad") -> "tablet"
      String.contains?(downcased, "tablet") -> "tablet"
      android_tablet?(user_agent) -> "tablet"
      String.contains?(downcased, "mobi") -> "mobile"
      String.contains?(user_agent, "iPhone") -> "mobile"
      String.contains?(user_agent, "iPod") -> "mobile"
      true -> "desktop"
    end
  end

  # Android phones carry "Mobile" in the token list; Android tablets omit it.
  defp android_tablet?(user_agent) do
    String.contains?(user_agent, "Android") and not String.contains?(user_agent, "Mobile")
  end
end
