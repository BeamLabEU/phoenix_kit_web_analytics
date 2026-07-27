defmodule PhoenixKitWebAnalytics.Visitor do
  @moduledoc """
  Cookieless visitor identification.

  A visitor ID is

      Base16(SHA256(daily_salt <> "|" <> ip <> "|" <> user_agent <> "|" <> date))

  truncated to 32 hex characters. That gives us "how many different people came
  today" without storing anything that identifies a person:

    * **No cookie, no local storage.** Nothing is written to the client, so
      there is nothing to consent to under the ePrivacy cookie rules and
      nothing for a client to clear or spoof.
    * **Not reversible.** SHA-256 of a secret salt plus the inputs. The salt
      lives in the host's settings table and is never sent to a client, so the
      hash can't be recomputed from a guessed IP.
    * **Not durable.** The date is part of the input, so the same person on the
      same network gets a *different* ID tomorrow. Cross-day tracking of an
      individual is impossible by construction — which is also why
      `PhoenixKitWebAnalytics.Schemas.DailyStat` documents `visitors` as a
      per-day figure that must not be summed.

  The IP address is used only as hash input; it is never persisted. See
  `PhoenixKitWebAnalytics.Schemas.Event` — there is no IP column.

  ## Same-day collisions

  Two people behind one NAT with byte-identical User-Agent strings hash to the
  same visitor. That undercounts visitors slightly on shared networks. The
  alternative (a cookie or a client-generated ID) is what this module exists to
  avoid, so the undercount is the intended trade.
  """

  @hash_length 32

  @doc """
  Computes today's visitor ID for an IP + User-Agent pair.

  `ip` accepts an `:inet` address tuple (what `conn.remote_ip` gives) or an
  already-formatted string. `date` defaults to today in UTC and exists so the
  rotation is testable.

      iex> id = PhoenixKitWebAnalytics.Visitor.visitor_id({127, 0, 0, 1}, "UA", "salt", ~D[2026-01-01])
      iex> String.length(id)
      32
      iex> id == PhoenixKitWebAnalytics.Visitor.visitor_id({127, 0, 0, 1}, "UA", "salt", ~D[2026-01-02])
      false
  """
  @spec visitor_id(tuple() | String.t() | nil, String.t() | nil, String.t(), Date.t() | nil) ::
          String.t()
  def visitor_id(ip, user_agent, salt, date \\ nil) do
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
        Date.to_iso8601(date)
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
