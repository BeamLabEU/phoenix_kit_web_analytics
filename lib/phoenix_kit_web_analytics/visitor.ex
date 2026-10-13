defmodule PhoenixKitWebAnalytics.Visitor do
  @moduledoc """
  Cookieless visitor identification.

  A visitor ID is

      Base16(SHA256(salt <> "|" <> ip <> "|" <> user_agent <> "|" <> period))

  truncated to 32 hex characters, where `period` is the day by default. That
  gives us "how many different people came today" without storing anything
  that identifies a person:

    * **No cookie, no local storage.** Nothing is written to the client, so
      there is nothing to consent to under the ePrivacy cookie rules and
      nothing for a client to clear or spoof.
    * **Not reversible.** SHA-256 of a secret salt plus the inputs. The salt
      lives in the host's settings table and is never sent to a client, so the
      hash can't be recomputed from a guessed IP.
    * **Not durable, by default.** The date is part of the input, so the same
      person on the same network gets a *different* ID tomorrow, and cross-day
      tracking of an individual through this ID is impossible by construction.
      Report visitors remain daily unique counts even with longer rotation.

  How long an ID lasts is the operator's choice
  (`web_analytics_visitor_rotation`): `:daily` (the default), `:weekly`,
  `:monthly`, or `:never` — the same ID for as long as the address, the
  browser and the salt stay the same. A longer period recognises a returning
  visitor across days; whether that needs the visitor's consent depends on
  the law the site answers to.

  The IP address is hash input here and nothing else. Whether it, or the raw
  User-Agent, is also *stored* is a separate set of settings, all off by
  default — see `PhoenixKitWebAnalytics.Profiles`.

  ## Same-day collisions

  Two people behind one NAT with byte-identical User-Agent strings hash to the
  same visitor. That undercounts visitors slightly on shared networks. The
  alternative (a cookie or a client-generated ID) is what this module exists to
  avoid, so the undercount is the intended trade.
  """

  @hash_length 32
  @rotations [:daily, :weekly, :monthly, :never]

  @type rotation :: :daily | :weekly | :monthly | :never

  @doc "The periods a visitor ID can last, shortest first."
  @spec rotations() :: [rotation()]
  def rotations, do: @rotations

  @doc """
  The part of the hash input that makes an ID expire: the day, the ISO week,
  the month, or nothing at all.

      iex> PhoenixKitWebAnalytics.Visitor.period(~D[2026-01-01], :daily)
      "2026-01-01"

      iex> PhoenixKitWebAnalytics.Visitor.period(~D[2026-01-01], :weekly)
      "2026-W01"

      iex> PhoenixKitWebAnalytics.Visitor.period(~D[2026-01-01], :monthly)
      "2026-01"

      iex> PhoenixKitWebAnalytics.Visitor.period(~D[2026-01-01], :never)
      "-"
  """
  @spec period(Date.t(), rotation()) :: String.t()
  def period(%Date{} = date, :weekly) do
    {year, week} = :calendar.iso_week_number(Date.to_erl(date))
    "#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  def period(%Date{} = date, :monthly),
    do: "#{date.year}-#{String.pad_leading(Integer.to_string(date.month), 2, "0")}"

  def period(%Date{}, :never), do: "-"
  def period(%Date{} = date, _daily), do: Date.to_iso8601(date)

  @doc """
  Computes the visitor ID for an IP + User-Agent pair.

  `ip` accepts an `:inet` address tuple (what `conn.remote_ip` gives) or an
  already-formatted string. `date` defaults to today in UTC and exists so the
  rotation is testable. `rotation` is how long the ID lasts (`period/2`);
  every caller passes the configured one, so a page view, its recording and
  its automation report agree on who the visitor is.

      iex> id = PhoenixKitWebAnalytics.Visitor.visitor_id({127, 0, 0, 1}, "UA", "salt", ~D[2026-01-01])
      iex> String.length(id)
      32
      iex> id == PhoenixKitWebAnalytics.Visitor.visitor_id({127, 0, 0, 1}, "UA", "salt", ~D[2026-01-02])
      false
      iex> week = PhoenixKitWebAnalytics.Visitor.visitor_id({127, 0, 0, 1}, "UA", "salt", ~D[2026-01-01], :weekly)
      iex> week == PhoenixKitWebAnalytics.Visitor.visitor_id({127, 0, 0, 1}, "UA", "salt", ~D[2026-01-02], :weekly)
      true
  """
  @spec visitor_id(
          tuple() | String.t() | nil,
          String.t() | nil,
          String.t(),
          Date.t() | nil,
          rotation()
        ) :: String.t()
  def visitor_id(ip, user_agent, salt, date \\ nil, rotation \\ :daily) do
    date = date || Date.utc_today()

    :sha256
    |> :crypto.hash(
      [
        salt,
        "|",
        format_ip(ip),
        "|",
        user_agent || "",
        "|",
        period(date, rotation)
      ]
      |> IO.iodata_to_binary()
    )
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_length)
  end

  @doc """
  Formats an IP for hashing.

  Anything unrecognised becomes `"unknown"` rather than raising — a request
  through a proxy that stripped the peer address still deserves to be counted.

      iex> PhoenixKitWebAnalytics.Visitor.format_ip({192, 168, 1, 1})
      "192.168.1.1"

      iex> PhoenixKitWebAnalytics.Visitor.format_ip(nil)
      "unknown"
  """
  @spec format_ip(tuple() | String.t() | nil) :: String.t()
  def format_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> "unknown"
      formatted -> to_string(formatted)
    end
  end

  def format_ip(ip) when is_binary(ip) and ip != "", do: ip
  def format_ip(_ip), do: "unknown"
end
