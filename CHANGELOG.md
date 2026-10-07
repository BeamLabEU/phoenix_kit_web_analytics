# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## 0.6.0 - 2026-10-07

### ⚠️ Upgrade

- **Run `mix phoenix_kit.update`** — migration V08 adds `traffic_flags
  smallint NOT NULL DEFAULT 0` to the events table (a catalogue change, no
  table rewrite, no index, no backfill).
- **Rows stored before the upgrade are not marked.** Own traffic from before
  it stays in the reports, and in the rollups of the days already rolled up.
- **Your own traffic is now left out by default** — from every report, the
  rollups, "Right now", alerts and recordings — so the numbers drop by your
  team's visits from the day of the deploy. Each kind has a **Leave out**
  switch in Settings.
- **Visits before a staff member shows up are not marked afterwards.** A visit
  becomes a staff member's whole once they sign in during it, but earlier
  visits from the same address are not: no address is stored to match them.
- **Staff networks behind NAT.** A staff sign-in marks its network (an IPv4
  address, an IPv6 /64) for 24 hours by default; behind a mobile network,
  carrier-grade NAT or an office gateway, that leaves out everyone sharing
  the address. Count them back in, or set `web_analytics_admin_network_hours`
  to `0`.
- **Recording chunks stored before a visit was marked stay**; the visit is
  recorded no further from the moment it is.
- **A report counting any own traffic in reads raw events** (as bot traffic
  always has): the rollups hold only unmarked traffic, so days older than the
  raw-event retention show no data in that view.

### Added

- **Your own traffic, marked and left out** (`PhoenixKitWebAnalytics.TrafficFlags`,
  `PhoenixKitWebAnalytics.InternalTraffic`). Three marks, stored as bits on
  each event — never the address behind them:
  - **Internal network** — the address is in
    `config :phoenix_kit_web_analytics, internal_networks: [...]` (CIDR,
    IPv4/IPv6; app config, not a setting, so your addresses never reach the
    activity log). Settings shows how many are configured.
  - **Site staff** — the signed-in user holds a role in
    `web_analytics_internal_roles` (Owner, Admin by default), by the roles
    they really hold. A hit naming only a user is judged by a 5-minute cache
    of their roles, filled off the hit's path.
  - **Staff network** — the address's network had a staff sign-in (from
    core's session broadcast and the token's address) or a staff request (any
    path, excluded ones included) within `web_analytics_admin_network_hours`;
    in memory only, shared between nodes when new. Private and loopback
    addresses are never taken.
- A visit is marked whole: later hits inherit its marks, and a mark that
  first appears mid-visit is written back to its earlier hits, in the same
  transaction and under the same lock as the hit.
- Settings: a **Leave out** switch per mark (all on), the staff roles, the
  staff-network hours, and a note on NAT.
- Reports: **Own traffic** and **Bots** switches next to the period, kept in
  the URL; either reads raw events, with a note that days past the
  raw-event retention have no data there. The visit page names a visit's
  marks.
- "Right now" leaves out open pages and recent visits with a left-out mark.

### Changed

- Rollups hold only unmarked, non-bot traffic (the watermark is not reset:
  days already rolled up keep what they had).
- `Reports.filter/1` takes `flagged:` and carries the mask it leaves out
  (`excluded_flags`), so a cached report is keyed by it; `recent_sessions/2`
  takes `bots:` and `excluded_flags:` (bots were hard-coded out).
- Alerts and recordings skip marked traffic.
- The plug ignores requests with an `x-tidewave-diagnostic` header: Tidewave
  re-fetches each page after a live navigation in development, which counted
  every navigation twice.

### Fixed

- The test helper `LiveCase.fake_scope/1` built a scope whose roles core's
  own checks couldn't read (`Scope.owner?/1` was false for an "owner"); it
  now stores role names as core does.

## 0.5.0 - 2026-10-07

### ⚠️ Upgrade

- **Add `:x_headers` to the LiveView socket's `connect_info` first, then
  deploy** — on both transports:
  `connect_info: [:peer_data, :x_headers, :user_agent, session: @session_options]`.
  Without it, a socket whose peer is a private or loopback address — a
  reverse proxy, a container network, a LAN, `localhost` in development — can
  no longer name its visitor, and the hook records nothing for it (no live
  navigation, interaction or "Right now" entry) instead of recording the
  peer as the visitor. Settings warns while that happens, and the "no
  JavaScript" bot check pauses while such skips are at least 5 % of a node's
  live visits in the last 24 hours. The skip count lives in memory, so after
  a restart the node that runs the check leaves alone every visit that
  started before it had been up for 30 minutes.
- **`X-Forwarded-For` from a private or loopback peer is now trusted with no
  configuration, and its LAST entry is taken** — the one the proxy appended,
  as PhoenixKit core reads it for a login; `X-Real-IP` only when there is no
  readable `X-Forwarded-For`. Before, the FIRST entry was read, and only with
  `trust_x_forwarded_for: true`. The proxy must therefore set or append
  `X-Forwarded-For` itself: one that only sets `X-Real-IP` (nginx with just
  `proxy_set_header X-Real-IP`) passes a visitor's own header through, and
  the visitor can name any address. The same holds on an intranet where
  visitors have private addresses and reach the app directly.
- **Had `trust_x_forwarded_for: true` behind a CDN or a proxy with a public
  address** (a CDN in front of the origin)? Add a `RemoteIp` plug
  ([`remote_ip`](https://hex.pm/packages/remote_ip)) before
  `PhoenixKitWebAnalytics.Plug`: a public peer's headers are ignored now, so
  without it every visitor is one of the CDN's addresses. Behind a chain (a
  CDN in front of a load balancer) the last entry is the CDN's, so `RemoteIp`
  is needed there as well.
- **LiveView behind a CDN and a load balancer:** `RemoteIp` fixes the plug
  but not the socket, which reads `:x_headers` by the rule above and sees
  the CDN's edge. Page load and live connection then hash to different
  visitors, and every LiveView visit is flagged a "no JavaScript" bot after
  30 minutes. On such a site switch **Spot bots by behaviour** off
  (`web_analytics_detect_bots`). With `trust_x_forwarded_for: true` and
  `:x_headers`, 0.4.0 read the first entry for both and didn't have this
  problem.
- **Expect more visitors and fewer bots from the day of the deploy.** Behind a
  proxy every visitor used to hash to the proxy's address: visitors sharing a
  browser were merged into one, and the merged "visitor" was often flagged
  `rate` (too many page views a minute). Visits recorded before the deploy are
  not recounted.

### Fixed

- **Behind a reverse proxy every visitor was the proxy.** The plug, the beacon
  and the LiveView hook read the client address by core's rule
  (`PhoenixKit.Utils.IpAddress.client_address/1` /
  `client_address_from_socket/1`, whose answer is taken for a public peer):
  behind a private or loopback peer, the last `X-Forwarded-For` entry across
  all its lines, then `X-Real-IP`. The headers are read by the module itself
  there, because a core that can't parse a port (2.55 and earlier) passes
  over such an `X-Forwarded-For` and answers with `X-Real-IP`, which a
  visitor can send. A port the proxy appended is dropped from `a.b.c.d:port`
  and `[v6]:port` (Caddy's `{remote}`); a bare IPv6 address is never cut
  (`2001:db8::1:443` is an address). `::ffff:a.b.c.d` is read as IPv4. A
  public peer is the visitor and its forwarded headers are ignored.

### Changed

- The `connect_info` snippets (README, Settings, `LiveHook` docs) list
  `:x_headers`. The README has a "Behind a reverse proxy" section, including
  the proxy-side fix for Caddy (`{remote_host}`, or no `header_up` at all).

### Deprecated

- `config :phoenix_kit_web_analytics, trust_x_forwarded_for:` has no effect.
  `true` is warned about once as the module starts; `false` is ignored.

## 0.4.0 - 2026-10-07

### ⚠️ Upgrade

- **Run `mix phoenix_kit.update` in the host** — migration V07 adds two
  nullable columns to `phoenix_kit_web_analytics_events` and two partial
  indexes. On a large events table, build the indexes `CONCURRENTLY` first (see
  the `PhoenixKitWebAnalytics.Migrations` docs) and the migration skips them.
- Rows written before the upgrade are not reclassified: earlier ad visits keep
  the channel they were recorded under ("direct", or "organic" when Google's
  Referer came along). An alert channel filter that leaves out "paid" will no
  longer alert on auto-tagged ad visits.

### Added

- **Ad-click identifiers are kept.** `gclid`, `gbraid`, `wbraid` (Google),
  `msclkid` (Microsoft Ads), `fbclid` (Meta), `ttclid` (TikTok) and `li_fat_id`
  (LinkedIn) are read off the landing URL alongside `utm_*`; the first one
  present goes into the new `click_id` column and its parameter name into
  `click_param` (Google's conversion upload takes `gclid`, `gbraid` and
  `wbraid` in separate fields). Previously everything but the five `utm_*`
  keys was discarded, so the identifier needed to report a conversion back to
  the ad platform was lost on arrival. See the README's Privacy section.
- `Web.BeaconPayload.utm_params/1` (public) now returns ad-click identifiers
  alongside `utm_*`; the name is kept.

### Fixed

- **An auto-tagged ad visit was recorded as "direct".** Auto-tagging adds a
  click identifier, not `utm_medium=cpc`, and an ad click often arrives without
  a referrer, so the Acquisition report showed no paid traffic at all. A visit
  carrying an ad-only click identifier is now recorded under the `paid`
  channel, with the platform (named as for a referrer: "Google", "Bing", …) as
  its source unless `utm_source` names one. `fbclid` is the exception: Meta
  appends it to organic and Instagram clicks too, so it never overrides the
  referrer and only counts as `social` when nothing else classifies the visit.
  An internal page view stays internal when the identifier rides along on the
  link (Google's `url_passthrough`). The Paid channel's help text on the
  Overview and Sources pages says so.
- A campaign parameter that isn't valid UTF-8 (`?utm_source=%FF`) made the
  insert fail and the hit was lost; the value is now dropped and the hit kept.

## 0.3.0 - 2026-10-01

### ⚠️ Upgrade

- **Run `mix phoenix_kit.update` in the host** — migrations V02–V06 add the
  session, rollup and recording columns/tables (each step is lock-light; the
  session-start backfill runs in batches from the retention pass, never in the
  migration). Requires `phoenix_kit ~> 2.38`.
- **The visitor-hash secret moved to `web_analytics_hash_secret`** (see Fixed).
  A new one is generated on first use, so visitor IDs restart once. The old
  `web_analytics_hash_salt` row is no longer read and can be deleted; earlier
  `setting.changed` activity entries for it hold the old value in plaintext —
  purge them.

### Added

- **Server-side tracking**: a LiveView `on_mount` hook records live navigations,
  interactions (allow-listed params only) and exits straight from the socket;
  `LivePresence` powers the new **Right now** page.
- **Sessions** and a per-session timeline; Pages, Acquisition, Technology and
  Events reports rebuilt on shared dimensions.
- **Optional client script** (via `js_sources/0`): outbound/download clicks,
  scroll depth, exits from non-LiveView pages. No cookies or storage.
- **Optional session recordings** with a replay player on the visit page
  (coordinates and element positions only — never text or form values).
- **Behavioural bot signals** (automation flag, page-view speed, no JavaScript).
- **Daily rollups** (`daily_stats`, `daily_dims`) read together with raw events,
  a single-flight report cache, and hourly retention that never prunes past the
  rollup watermark.
- **Website activity alerts** (new visitors, tracked events, sign-ups) routed
  through core's notifications.
- `Admin` module: every operator mutation is logged to `PhoenixKit.Activity`.
- Estonian and Russian translations.

### Fixed

- **The visitor-hash salt was written in plaintext to the permanent activity
  log** (and again on every rotation), because core only withholds values of
  keys whose name marks a secret. The key is now `web_analytics_hash_secret`.
- Rollup-backed reports (`overview`, `timeseries`, `sites`) raised on a database
  error instead of degrading to empty results.
- Monthly chart buckets vanished when the database session time zone was east
  of UTC.
- One-time tokens in core's route paths (`/users/reset-password/:token`,
  `/users/confirm/:token`, magic-link, QR-login, confirm-email, access links)
  were stored, shown in the Pages report and put into alert text; they are now
  stored as `:token`.
- Excluded paths and declared bots appeared under "Right now" and wrote leave
  events.
- "Tracked events" alerts were forgeable and uncapped; alert text could carry a
  visitor-crafted `utm_source` sentence; crawlers alerted with bot tracking on.
  Event alerts now have their own hourly cap, visitor-side text is cleaned, and
  bots never alert.
- A page that only saw interactions listed as a zero-view top page until its
  day was rolled up.
- The rollup watermark was written once per rolled day (one permanent
  `setting.changed` entry each); it is now written once per pass.
- A NUL byte in a path, campaign parameter or event value lost the whole hit.
- The body-size limits on the beacon and recording endpoints only applied to
  `text/plain`; a JSON body over the limit is now dropped too.
- Settings errors named six fields in English only; 23 empty `en` strings filled.

## 0.2.3 - 2026-09-07

### Fixed

- **0.2.0–0.2.2 fail to compile on Elixir 1.18.4 / OTP 28** with `cannot escape #Reference<...>` in `UserAgent`: a compiled regex nested inside a `{name, ~r//}` list module attribute can't be injected into `parse/1`'s body on that combination. `@browsers` / `@operating_systems` are now private functions instead of attributes; behaviour is unchanged. (#1, thanks @timujinne)
- Pages report crashed once a period had 100+ ranked paths: the "showing the top N paths" note referenced `@page_limit` inside the template, where `@name` is always an assign, never the module attribute of the same name — now assigned in `mount/3`.

## 0.2.2 - 2026-09-07

### Fixed

- Removed duplicate page headings across Web Analytics admin pages (Dashboard, Events, Pages, Acquisition, Technology, Settings) — each repeated the page title already shown in the top breadcrumb bar.

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
