defmodule PhoenixKitWebAnalytics.TrafficFlags do
  @moduledoc """
  The bits of an event's `traffic_flags` — traffic that is real but isn't
  the audience: the site's own people and their networks.

  A flagged hit is stored like any other; reports leave it out unless the
  settings count that kind in, or a report is switched to show it
  (`PhoenixKitWebAnalytics.Reports.filter/1`). Nothing is deleted, so a
  switch flipped back brings the hits back. Rollups only ever hold unflagged
  traffic.

  | Flag | Bit | Set when |
  |------|-----|----------|
  | `internal_network` | 1 | the client address is in a network listed in `config :phoenix_kit_web_analytics, internal_networks: […]` |
  | `admin` | 2 | the signed-in user holds a role listed in `web_analytics_internal_roles` |
  | `admin_network` | 4 | the client's network (an IPv4 address, an IPv6 /64) had such a user signed in within `web_analytics_admin_network_hours` |

  Bits 8, 16 and 32 are reserved for the suspicious-traffic signals planned
  next (`honeypot`, `headless`, `datacenter`).

  A visit is flagged whole: a hit inherits its session's bits, and a bit
  that first appears mid-visit is written back to the visit's earlier hits
  (`PhoenixKitWebAnalytics.Collector`). How the bits are worked out lives in
  `PhoenixKitWebAnalytics.InternalTraffic`.
  """

  import Bitwise

  use Gettext, backend: PhoenixKitWebAnalytics.Gettext

  @flags [internal_network: 1, admin: 2, admin_network: 4]
  @all Enum.reduce(@flags, 0, fn {_name, bit}, acc -> acc ||| bit end)

  @type name :: :internal_network | :admin | :admin_network

  @doc "Every defined flag, `{name, bit}`, in display order."
  @spec flags() :: [{name(), pos_integer()}]
  def flags, do: @flags

  @doc "Every defined flag's name."
  @spec names() :: [name()]
  def names, do: Keyword.keys(@flags)

  @doc "The bit of one flag."
  @spec bit(name()) :: pos_integer()
  def bit(name), do: Keyword.fetch!(@flags, name)

  @doc "Every defined bit at once — the mask that leaves out all flagged traffic."
  @spec all() :: pos_integer()
  def all, do: @all

  @doc """
  The names of the bits set in `flags`.

      iex> PhoenixKitWebAnalytics.TrafficFlags.names_in(6)
      [:admin, :admin_network]
  """
  @spec names_in(integer() | nil) :: [name()]
  def names_in(flags) when is_integer(flags),
    do: for({name, bit} <- @flags, (flags &&& bit) != 0, do: name)

  def names_in(_flags), do: []

  @doc """
  Whether a hit with `flags` is left out under `mask` — any of its bits
  among the masked ones.
  """
  @spec excluded?(integer() | nil, integer()) :: boolean()
  def excluded?(flags, mask) when is_integer(flags) and is_integer(mask),
    do: (flags &&& mask) != 0

  def excluded?(_flags, _mask), do: false

  @doc """
  The mask of the bits to leave out, from the names to leave out.

      iex> PhoenixKitWebAnalytics.TrafficFlags.mask([:internal_network, :admin_network])
      5
  """
  @spec mask([name()]) :: non_neg_integer()
  def mask(names) when is_list(names),
    do: Enum.reduce(names, 0, fn name, acc -> acc ||| bit(name) end)

  @doc "The label shown for a flag."
  @spec label(name()) :: String.t()
  def label(:internal_network), do: gettext("Internal network")
  def label(:admin), do: gettext("Site staff")
  def label(:admin_network), do: gettext("Staff network")
end
