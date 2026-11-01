defmodule PhoenixKitWebAnalytics.IpHealth do
  @moduledoc """
  Whether the module can tell visitors apart by address — judged from the
  traffic itself.

  Most installs sit behind a reverse proxy. One that doesn't append
  `X-Forwarded-For` makes every visitor resolve to the proxy's own private
  address, and then every visitor ID, every visit, every internal-network
  match and every rate limit collapses into one "visitor". Nothing fails;
  the numbers are just wrong.

  So `PhoenixKitWebAnalytics.Plug` samples each page view it hands to the
  collector — the last 200 of them, on this node, in memory only: whether
  the peer was a private or loopback address, whether a forwarded header
  came with it, whether the client address the module resolved is private,
  and a hash of that address keyed with a per-node secret (only to count
  distinct ones). No address is kept, nothing is written to the database or the
  settings, and a restart starts over.

  `report/0` (and `PhoenixKitWebAnalytics.ip_health/0`) sums the sample up;
  the Settings page shows its warning. The `:status`:

    * `:not_enough` — fewer than 20 page views sampled yet.
    * `:one_internal` — nearly every visitor (90 %) resolves to a private or
      loopback address, and at most two distinct ones: the proxy in front
      of the app is the "visitor". Make it append `X-Forwarded-For`
      (nginx: `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`,
      Caddy and most load balancers do it by default).
    * `:one_address` — at least 50 page views and every one from the same
      public address: a CDN or a proxy with a public address in front of the
      app, whose headers are not read. Put a plug that rewrites `remote_ip`
      — [`remote_ip`](https://hex.pm/packages/remote_ip) — before the
      tracking plug, or, on PhoenixKit 2.64 and later, list the proxy in
      `config :phoenix_kit, :trusted_proxies` (a public peer's forwarded
      header is then read by core's rule).
    * `:ok` — visitors come from many addresses.

  A site with only its developer on it reads the same way — `:one_internal`
  on `localhost`, `:one_address` once deployed; the warning says "looks
  like", and goes away as real traffic arrives.
  """

  alias PhoenixKitWebAnalytics.Ring
  alias PhoenixKitWebAnalytics.Tracking

  @ring :ip_health
  @size 200
  @min_sample 20
  @min_single 50
  @internal_share 0.9

  @type status :: :not_enough | :one_internal | :one_address | :ok
  @type report :: %{
          status: status(),
          sample: non_neg_integer(),
          private_peers: non_neg_integer(),
          forwarded: non_neg_integer(),
          private_clients: non_neg_integer(),
          distinct_clients: non_neg_integer()
        }

  @doc """
  Notes one tracked request, whose client address the module resolved to
  `client_ip`. Cheap (one counter, one insert); never raises.
  """
  @spec sample(Plug.Conn.t(), :inet.ip_address() | nil) :: :ok
  def sample(%Plug.Conn{} = conn, client_ip) do
    Ring.push(@ring, @size, {
      Tracking.local_address?(conn.remote_ip),
      forwarded?(conn),
      Tracking.local_address?(client_ip),
      :erlang.phash2({node_secret(), client_ip})
    })
  rescue
    _ -> :ok
  end

  @doc "The sample summed up, with its verdict — see the moduledoc."
  @spec report() :: report()
  def report do
    entries = Ring.list(@ring, @size)
    n = length(entries)

    counts = %{
      sample: n,
      private_peers: Enum.count(entries, &elem(&1, 0)),
      forwarded: Enum.count(entries, &elem(&1, 1)),
      private_clients: Enum.count(entries, &elem(&1, 2)),
      distinct_clients: entries |> Enum.uniq_by(&elem(&1, 3)) |> length()
    }

    Map.put(counts, :status, status(counts))
  end

  @doc false
  # For tests.
  @spec reset() :: :ok
  def reset, do: Ring.clear(@ring)

  defp status(%{sample: n}) when n < @min_sample, do: :not_enough

  defp status(%{sample: n, private_clients: private, distinct_clients: distinct})
       when private >= n * @internal_share and distinct <= 2,
       do: :one_internal

  defp status(%{sample: n, distinct_clients: 1}) when n >= @min_single, do: :one_address
  defp status(_counts), do: :ok

  # Keyed with a secret of this node's (never stored, gone on restart), so a
  # sampled hash can't be turned back into an IPv4 address by trying them all.
  defp node_secret do
    case :persistent_term.get({__MODULE__, :secret}, nil) do
      nil ->
        secret = :crypto.strong_rand_bytes(16)
        :persistent_term.put({__MODULE__, :secret}, secret)
        secret

      secret ->
        secret
    end
  end

  defp forwarded?(conn) do
    Enum.any?(conn.req_headers, fn {name, _} -> name in ["x-forwarded-for", "x-real-ip"] end)
  end
end
