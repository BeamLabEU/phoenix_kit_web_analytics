defmodule PhoenixKitWebAnalytics.Geo do
  @moduledoc """
  Optional behaviour for resolving a request IP to a coarse location.

  **No IP database ships with this package** — they are large, licensed, and
  need regular refreshing, none of which belongs in a Hex dependency. Country
  reporting is therefore off until a host wires up a resolver:

      # config/config.exs
      config :phoenix_kit_web_analytics, geo_resolver: MyApp.GeoIP

      defmodule MyApp.GeoIP do
        @behaviour PhoenixKitWebAnalytics.Geo

        @impl true
        def resolve(ip) do
          case :locus.lookup(:city, ip) do
            {:ok, entry} ->
              %{
                country_code: get_in(entry, ["country", "iso_code"]),
                region: entry |> get_in(["subdivisions"]) |> List.first() |> get_in(["names", "en"]),
                city: get_in(entry, ["city", "names", "en"])
              }

            _ ->
              :error
          end
        end
      end

  Many deployments get this for free from the edge instead — Cloudflare's
  `CF-IPCountry`, Fastly's `Fastly-Geo-Country` — in which case a resolver
  isn't needed at all: see `PhoenixKitWebAnalytics.Plug`, which reads those
  headers when they are present and skips the resolver entirely.

  ## Contract

  `resolve/1` receives an `:inet` address tuple and must return a map with
  `:country_code` (ISO 3166-1 alpha-2), `:region`, and `:city` — any of which
  may be `nil` — or `:error` when the IP can't be located. It is called from a
  background task, never from the request process, but it must still be fast
  and must never raise: `PhoenixKitWebAnalytics.Collector` rescues failures and
  stores the event without location rather than losing it.
  """

  @type location :: %{
          country_code: String.t() | nil,
          region: String.t() | nil,
          city: String.t() | nil
        }

  @callback resolve(:inet.ip_address()) :: location() | :error

  @empty %{country_code: nil, region: nil, city: nil}

  @doc """
  Resolves `ip` through the configured resolver.

  Returns an all-`nil` location when no resolver is configured, the IP is
  unusable, or the resolver fails — the caller stores the event either way.
  """
  @spec resolve(tuple() | nil) :: location()
  def resolve(ip) when is_tuple(ip) do
    case PhoenixKitWebAnalytics.Config.geo_resolver() do
      nil -> @empty
      resolver -> apply_resolver(resolver, ip)
    end
  end

  def resolve(_ip), do: @empty

  @doc "An all-`nil` location, for callers that need the empty shape."
  @spec empty() :: location()
  def empty, do: @empty

  defp apply_resolver(resolver, ip) do
    case resolver.resolve(ip) do
      %{} = location -> Map.merge(@empty, Map.take(location, [:country_code, :region, :city]))
      _ -> @empty
    end
  rescue
    _ -> @empty
  catch
    :exit, _ -> @empty
  end
end
