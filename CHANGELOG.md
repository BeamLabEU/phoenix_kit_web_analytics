# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## 0.2.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## [0.2.0] - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

### Fixed

- **This is the first release of this package to actually reach Hex.** Its
  package `files:` list named a `priv` directory that does not exist, and
  `mix hex.build` refuses to build a package whose declared files are missing
  ("Missing files: priv") — so every publish attempt had failed before reaching
  the registry. The entry is dropped; add it back if `priv/` ever gains content.
- **The dashboard no longer fails to compile against core 2.0.** Core 2.0 added
  `PhoenixKitWeb.Components.Core.Chart.bar_chart/1`, which every LiveView imports
  via `use PhoenixKitWeb, :live_view`. That collided with this package's own
  same-arity `bar_chart/1`, making the unqualified call in the dashboard
  ambiguous and failing the build. The local component is renamed
  **`traffic_chart/1`**; core's is a generic SVG chart keyed on `id`/`data`,
  while this one is bucket-aware and takes `series`/`metric`/`bucket`, so they
  are not interchangeable and the local one is kept. Rendered output is
  unchanged. Callers using `PhoenixKitWebAnalytics.Web.Components.bar_chart/1`
  directly must rename the call.

## [0.1.0] - 2026-07-26

Initial release.

### Collection

- `PhoenixKitWebAnalytics.Plug` — server-side page view tracking. One line in
  the host's `:browser` pipeline; nothing is added to rendered pages. Writes
  happen in a supervised task after the response is sent, with a `max_children`
  cap that drops rather than queues under load.
- `PhoenixKitWebAnalytics.LiveHook` — an `on_mount` hook that counts LiveView
  `push_patch` / `push_navigate` navigation. Stays inert unless the endpoint
  socket exposes `:peer_data` and `:user_agent`, rather than recording hits
  under a mismatched visitor hash.
- Cookieless visitor identification: a daily-rotating salted SHA-256 of
  IP + User-Agent, truncated to 32 hex characters. No IP is stored.
- Server-side session stitching on an inactivity window (30 minutes by
  default) — no session cookie.
- Built-in User-Agent classification (browser, OS, device class, bot
  detection) and referrer classification into channels, with no external
  dependency or IP database.
- Campaign parameters (`utm_*`) are extracted into their own columns; the rest
  of the query string is never stored.
- Skips non-`GET` requests, non-2xx and non-HTML responses, excluded paths,
  `DNT` / `Sec-GPC` opt-outs, and bots.
- Optional public collection endpoints, off by default: a ~300-byte inline
  beacon snippet for browser-side custom events and a 1×1 pixel for
  CDN-cached pages. `PhoenixKitWebAnalytics.Web.BeaconPayload` enforces the
  trust boundary — a payload controls content, never identity or origin.
- `PhoenixKitWebAnalytics.track_event/2` for server-side custom events.
- `PhoenixKitWebAnalytics.Geo` behaviour for optional country resolution, plus
  automatic use of CDN country headers (Cloudflare, Vercel, Fastly) when
  present.

### Reports

- `PhoenixKitWebAnalytics.Reports` — overview totals with period-over-period
  comparison, trend series (hour / day / month buckets), top pages, slowest
  pages by response time, referrers, channels, UTM campaigns and sources,
  browsers, operating systems, devices, countries, languages, custom events,
  a recent-hits feed, and live visitor count.
- Six admin pages: Overview, Pages, Acquisition, Technology, Events, Settings.
  Charts are CSS-only — no charting library ships with this package.
- Period and site filters live in the URL, so a filtered report can be
  bookmarked and shared.

### Storage

- Module-owned versioned migrations (`PhoenixKitWebAnalytics.Migrations`),
  applied by `mix phoenix_kit.update`, with `COMMENT ON TABLE` version
  tracking and full `--prefix` (named-schema) support.
- `phoenix_kit_web_analytics_events` (append-only hits) and
  `phoenix_kit_web_analytics_daily_stats` (per-day, per-site rollups), both
  with UUIDv7 primary keys.
- `PhoenixKitWebAnalytics.Retention` — hourly rollup of completed days and
  batched pruning of raw events past the retention window (365 days by
  default). Pruning never runs ahead of the rollup that preserves the trend
  line; `daily_timeseries/1` falls back to rollups for pruned days.

[0.1.0]: https://github.com/BeamLabEU/phoenix_kit_web_analytics/releases/tag/0.1.0
