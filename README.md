# PhoenixKitWebAnalytics

Web analytics for [PhoenixKit](https://hex.pm/packages/phoenix_kit) sites — who
comes to the site, where from, what they do, and when they leave — recorded by
your own server, in your own database.

A Phoenix app already sees nearly everything a hosted analytics script
reports: every page request passes through the router, and on LiveView pages
every click, form submit and navigation arrives over the socket. This module
records it there, server-side:

```elixir
pipeline :browser do
  # … existing plugs, after :fetch_session …
  plug PhoenixKitWebAnalytics.Plug
end

live_session :public,
  on_mount: [{PhoenixKitWebAnalytics.LiveHook, :track_navigation}] do
  # …
end
```

An optional client script (shipped with the module, switched off until you
enable it) adds only what a server cannot see: outbound and download clicks,
scroll depth, and exits from pages without a LiveView.

## Why server-side

- **Nothing to download.** The plug and the LiveView hook add no bytes to a
  page; Core Web Vitals are what they were.
- **No cookies, no consent banner.** Visitors are identified by a salted hash
  of IP + User-Agent + date. No IP address, no raw User-Agent and no query
  string is written to the database. (An ad platform's click identifier is
  kept when a visit arrives with one — see [Privacy](#privacy).)
- **Ad blockers can't remove it.** The numbers are your server's.
- **The data is yours.** Four tables in your own database; nothing leaves
  your infrastructure.

## What gets recorded

| What | How | Needs |
|------|-----|-------|
| Page views | Every HTML response (the plug); every LiveView navigation (the hook) | the plug; the hook for LiveView |
| Interactions | Every event a LiveView handles — `phx-click`, `phx-submit`, … — by name. Form typing and form contents are never recorded | the hook |
| Exits and time on page | When a LiveView process ends (tab closed, navigated away, connection lost) | the hook |
| Who is online now | The open LiveView processes, live | the hook |
| Outbound / download / contact clicks, plain buttons, `data-analytics` elements | Browser click listener | client script |
| Scroll depth; exits from non-LiveView pages | Browser scroll and page-hide listeners | client script |
| Custom events | `PhoenixKitWebAnalytics.track_event/2` on the server; `phoenixKitAnalytics(name, props)` in the browser | — / client script |
| Session recordings (optional, off by default) | Pointer movement, clicks, hovers and scrolling per page view — coordinates and element positions only, never text, typing or form values; replayed on the visit page | client script + **Record visits** |

Signed-in users are attributed by their account on every hit, so a person's
visits can be followed across the site (Sessions → a user's visits).

## Admin pages

Under **Web Analytics** in the PhoenixKit sidebar:

| Page | What it shows |
|------|---------------|
| Overview | Visitors, page views, sessions, bounce rate, session length and time on page, with change against the previous period; the trend; top pages, referrers, channels, devices, what visitors do, exit pages |
| Right now | Every page open this moment, for how long, by whom (signed-in name or anonymous), on what; visits active in the last five minutes |
| Sessions | Every visit: who, landing → exit page, pages, actions, duration, source, client. Opens a **visit timeline** — everything that visitor did, in order — with the **recording player** when the visit was recorded, and why it counts as a bot's when it does |
| Pages | Every path with views, time on page and exits; a path opens the overview filtered to it; slowest pages by server response time |
| Acquisition | Channels (direct / search / social / referral / email / paid), referring sites, UTM campaigns |
| Technology | Browsers, operating systems, devices, languages, countries |
| Events | What visitors do (interactions), custom events, and a live feed of every hit |
| Settings | Collection rules, bot detection, retention, interaction and client-script switches, session recordings, alerts, stored-data stats, installation checklist |

Charts are core's server-rendered SVG components — no charting library, no
JavaScript in the admin either.

## Installation

```elixir
# mix.exs
{:phoenix_kit_web_analytics, "~> 0.2"}
```

```bash
mix deps.get
mix phoenix_kit.update   # creates / upgrades the module's tables
```

Then enable **Web Analytics** on the admin Modules page, and:

1. **The plug** in your browser pipeline, after `:fetch_session` (above).
   Where exactly doesn't matter otherwise: who is signed in (for
   [Your own traffic](#your-own-traffic)) is read as the response is sent,
   after the rest of the pipeline and the controller have run. PhoenixKit's
   own routes — the admin panel among them — pipe through your `:browser`
   first and only then load the user (`:phoenix_kit_auto_setup`) and, for
   the admin, the scope; the plug still sees them. Where only the user is
   loaded (no scope), their roles come from a five-minute cache, looked up
   off the request on a miss: the first such request after a cold start
   doesn't mark the staff network, the next one does.
2. **The hook** in each public `live_session`, after whatever mounts the
   current user, so signed-in visitors are attributed:

   ```elixir
   live_session :public,
     on_mount: [
       {PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope},
       {PhoenixKitWebAnalytics.LiveHook, :track_navigation}
     ] do
   ```

3. **`connect_info`** on the LiveView socket, **on both transports** — the
   hook needs the address and browser to hash the visitor the same way the
   plug does, and LiveView falls back to long polling when a websocket can't
   be opened (corporate proxies, flaky networks):

   ```elixir
   socket "/live", Phoenix.LiveView.Socket,
     websocket: [connect_info: [:peer_data, :x_headers, :user_agent, session: @session_options]],
     longpoll: [connect_info: [:peer_data, :x_headers, :user_agent, session: @session_options]]
   ```

   Without `:peer_data` and `:user_agent` the hook stays inert rather than
   recording visitors it would hash wrongly. `:x_headers` carries the
   forwarded address behind a reverse proxy; without it a socket with a
   private or loopback peer (a proxy, a container network, `localhost` in
   development) is skipped, and Settings warns about it.

4. **Behind a reverse proxy** on the same box or network (nginx, Caddy,
   Traefik, a container network) nothing more is needed: the visitor's
   address is read from the forwarded headers — see
   [Behind a reverse proxy](#behind-a-reverse-proxy). Behind a **chain**
   (a CDN in front of a load balancer), put a plug that rewrites `remote_ip`
   from headers your infrastructure controls — such as
   [`remote_ip`](https://hex.pm/packages/remote_ip) — **before** the tracking
   plug, or every visitor collapses into the CDN's addresses.
5. **Optional: pages Chrome serves from its prefetch cache.** When Chrome
   prefetches or prerenders a page (Speculation Rules — Google's search
   results do it) and the visitor then opens it, no second request reaches
   the plug; the prefetch itself is stored flagged as a bot's (see
   [Bots](#bots)). To count the visit, send a few extra LiveSocket connect
   params from your `assets/js/app.js` and connect only once a prerendered
   page is shown — the snippet is in the "Recovering a visitor served from
   a prefetch cache" section of `PhoenixKitWebAnalytics.LiveHook`. Only
   LiveView pages are recovered this way: a controller-rendered page served
   from the prefetch cache is not counted.

The client script ships through the module's `js_sources/0`, so a host set up
by `mix phoenix_kit.install` loads it with no change; switch **Accept the
client script** on in Settings to have its reports stored.

## Alerts

The module registers a **Website activity** notification type with PhoenixKit,
with three sub-types — **new visitors**, **new sign-ups** (every registration
path) and **tracked events** (names you list in Settings). Alerts go to
everyone who can open Web Analytics; each person picks, on their notification
settings page, whether they arrive in-app, by email or on Telegram, and can
switch a type to an hourly or daily digest.

Visitor alerts are off by default and have filters, because one per visitor is
a flood on any real site: only certain channels, only certain landing pages,
skip signed-in users, and an hourly cap (the next alert says how many were
held back). Alert text never contains an email address or anything a visitor
typed.

## Custom events

From server-side code, where the event is a fact your app already knows:

```elixir
PhoenixKitWebAnalytics.track_event("order.placed", %{
  path: "/checkout",
  metadata: %{"total_cents" => 4900},
  user_uuid: user.uuid
})
```

From the browser, with the client script enabled (or the `<.beacon />`
component — `import PhoenixKitWebAnalytics.Web.Beacon` in the layout that
renders it):

```heex
<button onclick="phoenixKitAnalytics('signup', {plan: 'pro'})">Sign up</button>
```

Any element can be named for click tracking with `data-analytics="name"`.

For pages served from a full-page CDN cache that never reaches your app,
`<.pixel path={@path} cache_buster={@request_id} />` records the view with a
1×1 image (switch **Accept the beacon and pixel** on).

## Querying the data yourself

`PhoenixKitWebAnalytics.Reports` is a plain module:

```elixir
import PhoenixKitWebAnalytics.Reports

filter = filter(period: "30d")

overview(filter)
#=> %{pageviews: 18_204, visitors: 6_133, sessions: 7_802, bounce_rate: 41.2, …}

top_paths(filter, limit: 20)
sessions(filter, user_uuid: user.uuid)     # one person's visits
session_timeline(session_id)               # one visit, replayed
```

## How counting works

Stated explicitly, because it's what makes two analytics tools disagree:

- **Page views** — HTML responses and LiveView navigations. A LiveView
  reconnect is not a page view, and neither is a patch that only changes the
  query string.
- **Visitors** — distinct visitor hashes among page views. The hash includes
  the date, so one person browsing on three days counts as three visitors over
  a week — the honest consequence of not tracking people across days.
- **Sessions** — stitched server-side: a hit joins the visitor's previous
  session on the same site if it's within the inactivity window (30 minutes by
  default), otherwise it starts a new one. A session needs a page view.
- **Bounce rate** — sessions with exactly one page view.
- **Session length** — first hit to last, exits included, so a single page
  read for three minutes is a three-minute session.
- **Time on page** — from exits: how long the page was open (LiveView) or
  visible (client script).

### What is skipped

Non-`GET` requests, non-2xx responses, anything that isn't `text/html`, paths
matching the exclusion patterns (`/admin*` by default), visitors sending
`DNT: 1` or `Sec-GPC: 1` (on every path, LiveView and client script
included), and bots. All configurable in Settings. Tidewave's development
re-fetch of a page (an `x-tidewave-diagnostic` header) is never a page view.
A browser's speculative prefetch is stored, but as a bot's (see [Bots](#bots)).

### Bots

A bot that names itself (Googlebot, link previews, uptime monitors, `curl`,
headless browsers …) is recognised by its User-Agent. One posing as a normal
browser is caught by what it does (`PhoenixKitWebAnalytics.BotSignals`, on by
default — **Spot bots by behaviour**):

- **automation** — the client script reports `navigator.webdriver`, which
  Selenium, Puppeteer and Playwright set;
- **speed** — more than 30 page views a minute from one visitor;
- **no JavaScript** — a LiveView page whose live connection never came (no
  exit, click or live navigation from that visitor all day), judged after
  30 minutes. Only pages running the hook count, and the check pauses while
  the hook is skipping LiveView visits behind a proxy (see
  [Behind a reverse proxy](#behind-a-reverse-proxy)).

A flagged visit is marked as a bot's with the reason (shown on the visit
page), so every report drops it; later hits of the visit inherit the flag. A
"no JavaScript" verdict can be wrong, so that visit's later hits are kept
(flagged) and the flag lifts itself if the visit's JavaScript shows up after
all — a tab left open without a click until it closes.

A **speculative prefetch** — a page Chrome or Edge fetches or prerenders
before anyone clicks it (`Sec-Purpose: prefetch…`, or the legacy
`Purpose: prefetch`) — is stored flagged `"prefetch"` whatever **Record bot
traffic** says, so it shows only with the reports' **Bots** switch on. It is
kept apart from the visitor's own visit, even when Chrome sends it from the
visitor's browser. A `<link rel=prefetch>` (`Sec-Fetch-Dest: empty`) isn't
flagged: Chrome serves the later click on it from its cache without asking
again, so that request is counted as the page view. How the visit behind a
prefetch is still counted is step 5 of [Installation](#installation).

### Your own traffic

Visits by the site's own people are real traffic, but not the audience. They
are **stored with a mark and left out** — of every report, the rollups,
"Right now", alerts and recordings — rather than dropped, so a switch turned
back brings them back. Three marks (`traffic_flags` on each event, bits of
`PhoenixKitWebAnalytics.TrafficFlags`; a hit can carry several):

| Mark | Set when |
|------|----------|
| **Internal network** | the visitor's address is in one of the networks in `config :phoenix_kit_web_analytics, internal_networks: [...]` |
| **Site staff** | the signed-in user holds a staff role (`web_analytics_internal_roles`: Owner and Admin by default) — the roles they really hold, whichever one they are acting as |
| **Staff network** | the visitor's network (an IPv4 address, an IPv6 /64) had a staff member signed in or active within `web_analytics_admin_network_hours` (24 by default) |

The internal networks are app config, not a setting — every settings change
is a permanent activity-log entry, and this one would be your own addresses:

```elixir
# config/runtime.exs
config :phoenix_kit_web_analytics,
  internal_networks: ["203.0.113.0/24", "2001:db8:1234::/48"]
```

A **visit is marked whole**: its later hits inherit its marks, and a mark
that appears mid-visit — an anonymous visitor signs in as an admin — is
written back to the visit's earlier hits. Visits *before* that, from the
same address, are not: no address is stored, so there is nothing to match
them against. A visit long enough to reach back past a day already rolled
up for good (more than three hours after that day ended) has its earlier
hits marked, but that day's rollup keeps counting them: until retention
prunes the day's raw events, a report counting own traffic in and one
leaving it out can differ for that day by those hits.

A staff network is learnt from a staff sign-in (the address the session was
issued to — so an admin who only ever works in the admin panel, which is
never tracked, still counts) and from a staff member's own requests on any
path, and is shared between nodes. It is kept in memory only. **Behind a
mobile network, carrier-grade NAT or an office gateway, one address is many
people**: a sign-in from a phone leaves out everyone sharing that address
for those hours. Count staff networks back in from Settings, or set the
hours to `0` to stop marking them. The hours are read when a network is
judged, so shortening them applies to the networks already learnt.

In Settings, each mark has its own **Leave out** switch (all on by default);
on a report, **Own traffic** shows everything for that view, and **Bots**
shows bot traffic. The rollups hold only unmarked, non-bot traffic, so a
report that counts any mark in — by a switch in either place — reads its
period from raw events: days older than the raw-event retention then show no
data rather than their totals.

## Privacy

There is no cookie, no local storage, no IP address column and no raw
User-Agent. A visitor ID is

```
SHA256(salt + IP + User-Agent + date)
```

truncated to 32 hex characters. It can't be joined across days. The salt is a
secret stored in your settings table: someone with access to the database
could recompute the hash for an IP and browser they already know, so treat
database access accordingly.

Query strings are not stored — not in paths and not in referrers. Campaign
parameters (`utm_*`) and an ad platform's click identifier (`gclid`, `gbraid`,
`wbraid`, `msclkid`, `fbclid`, `ttclid`, `li_fat_id`) are extracted into their
own columns first; everything else is discarded before the row is written. An
interaction keeps only the event's name and the short values of parameters
you allow-list (`tab`, `view`, `step` … by default) — never form contents.

A **click identifier** (`click_id`) is issued by the ad platform, not by this
module. It is pseudonymous rather than anonymous: it joins the rows of the
visit it arrived with (and a later visit that reopens the same landing URL),
and the platform can tie it to its own user. It is stored so the visit is
attributed to the ad, and so a host can report a conversion back to the
platform against it. The module itself never sends it anywhere. Whether such
a report is allowed — consent, your privacy notice — is the host's call. Like
every event column, it is deleted by the retention pass.

A **signed-in** visitor's hits carry their account id, which is what lets you
follow a user's visits; anonymous visitors stay anonymous.

**Session recordings** are off unless switched on, and record coordinates and
short element selectors (`main > form.signup > button`) — never text,
keystrokes, form values or page content. Visitors asking not to be tracked,
bots and excluded paths are never recorded. The player loads the recorded page
as it looks today, in a sandboxed frame with scripts off, and only a page the
server itself saw that visit request — never a path the visitor's browser
merely claims. Recordings are deleted after 30 days by default.

The **own-traffic marks** are a few bits on the event — never the address
that set them. The internal networks are your app's config; staff networks
are held in memory, by their network key, for their hours, and never written
to the database or the settings.

Countries are only recorded if you configure a resolver
(`PhoenixKitWebAnalytics.Geo`) or run behind a CDN that sets a country header.
No IP database ships with this package.

## Data growth and retention

This is the one PhoenixKit table that grows with traffic rather than content.
An hourly background pass:

1. **rolls up** each completed day into per-site totals and per-day
   breakdowns (pages, sources, devices, events … — the 5,000 most visited
   values per breakdown and day; tracked with a "rolled up through" date, and
   re-rolled in the three hours after the day ends to catch late hits), then
2. **prunes** raw events past the retention window (365 days by default; `0`
   disables pruning), in batches, and never past the last rolled-up day, and
   recordings past theirs (30 days by default).

One pass runs at a time across all nodes (a database lock), "Run now" in
Settings included.

Reports read finished days from those rollups and only today from raw events,
so a year's report costs about what a day's does, and pruned days keep their
breakdowns. Every list pages (visits, pages, open pages, a visit's timeline),
and report results are cached for 30 seconds so a busy day's raw slice is
aggregated at most once per interval.

## Performance

The request process does a method/path check, one ETS read for settings, and
`register_before_send/2`. Enrichment, session stitching and the insert happen
in a supervised task after the response is on its way out. The task
supervisor is capped (20 concurrent writes by default,
`config :phoenix_kit_web_analytics, max_concurrent_writes: n`); under a flood
hits are dropped rather than queued, so analytics never exhausts your database
pool. LiveView interactions cost one `attach_hook` call and a message.

## Configuration

Settings (editable from the admin Settings page, no redeploy):

| Key | Default | Meaning |
|-----|---------|---------|
| `web_analytics_enabled` | `false` | Master switch (the module toggle) |
| `web_analytics_respect_dnt` | `true` | Skip visitors sending `DNT` / `Sec-GPC` |
| `web_analytics_track_bots` | `false` | Record automated traffic |
| `web_analytics_detect_bots` | `true` | Also spot bots by behaviour (automation flag, speed, no JavaScript) |
| `web_analytics_exclude_paths` | `/admin*` … | Path patterns to ignore (trailing `*` = prefix) |
| `web_analytics_session_timeout_minutes` | `30` | Inactivity gap that ends a session |
| `web_analytics_retention_days` | `365` | Age at which raw events are rolled up and deleted |
| `web_analytics_track_interactions` | `true` | Record LiveView events as interactions |
| `web_analytics_ignore_events` | `validate` | LiveView event names never recorded |
| `web_analytics_event_params` | `tab, view, section, step, sort, filter, period` | Event parameters whose short values are kept |
| `web_analytics_client_script` | `false` | Store the client script's clicks, scroll depth and exits |
| `web_analytics_beacon_enabled` | `false` | Accept page views from the beacon / pixel endpoints |
| `web_analytics_recording` | `false` | Record visits (pointer, clicks, hovers, scrolling) for replay |
| `web_analytics_recording_sample` | `100` | Percent of visitors recorded, decided per visitor per day |
| `web_analytics_recording_retention_days` | `30` | Age at which recordings are deleted |
| `web_analytics_exclude_internal_network` | `true` | Leave internal-network traffic out of the statistics |
| `web_analytics_exclude_admin` | `true` | Leave the site staff's visits out of the statistics |
| `web_analytics_exclude_admin_network` | `true` | Leave visits from staff networks out of the statistics |
| `web_analytics_internal_roles` | `Owner, Admin` | Roles whose holders are site staff (comma-separated; `-`, an emptied field, is no one) |
| `web_analytics_admin_network_hours` | `24` | How long a staff sign-in marks its network (`0` = never) |
| `web_analytics_alert_signups` | `true` | Alert on new accounts |
| `web_analytics_alert_visitors` | `false` | Alert on new visits (filtered by the keys below) |
| `web_analytics_alert_channels` | all | Channels a visitor alert fires for |
| `web_analytics_alert_paths` | any | Landing pages a visitor alert fires for |
| `web_analytics_alert_skip_users` | `true` | No visitor alerts for signed-in users |
| `web_analytics_alert_max_per_hour` | `20` | Visitor alert cap (`0` = none) |
| `web_analytics_alert_events` | none | Event / interaction names that alert |

Application config:

```elixir
# An IP → location resolver; see PhoenixKitWebAnalytics.Geo
config :phoenix_kit_web_analytics, geo_resolver: MyApp.GeoIP

# Your own networks (offices, VPN): their visits are marked and left out of
# the statistics — see "Your own traffic". CIDR, IPv4 or IPv6.
config :phoenix_kit_web_analytics, internal_networks: ["203.0.113.0/24"]

# Concurrent background writes before hits are dropped.
config :phoenix_kit_web_analytics, max_concurrent_writes: 20

# How long report results are cached (ms); 0 turns the cache off.
config :phoenix_kit_web_analytics, report_cache_ms: 30_000

# Page views a minute from one visitor before it counts as a bot.
config :phoenix_kit_web_analytics, bot_pageviews_per_minute: 30

# Right now: how long a closed page waits for its reconnect before its exit
# is recorded, and how long a reloaded page's late-closing old connection is
# hidden before it counts as a second tab (ms).
config :phoenix_kit_web_analytics, presence_reconnect_grace_ms: 10_000
config :phoenix_kit_web_analytics, presence_supersede_ms: 30_000
```

`trust_x_forwarded_for` is deprecated and does nothing (a warning is logged
at start while it is set): the forwarded header from a private peer is always
read — see [Behind a reverse proxy](#behind-a-reverse-proxy).

The collection endpoints read `text/plain` bodies (what `navigator.sendBeacon`
sends) themselves, capped at 16 KB (128 KB for a recording chunk). A body sent
as JSON is parsed by your endpoint's `Plug.Parsers` first, under its own
`:length` limit — keep that limit modest on a public site.

## Behind a reverse proxy

The address is visitor-hash input only — it is never stored. The plug, the
beacon and the LiveView hook read it the way PhoenixKit reads it for a login
(`PhoenixKit.Utils.IpAddress`):

- a public peer address is the visitor, and forwarded headers from it are
  ignored (anyone can send them);
- a private or loopback peer (`10/8`, `172.16/12`, `192.168/16`,
  `127/8`, `::1`, `fc00::/7`) is a proxy, and the visitor is the **last**
  entry of `X-Forwarded-For` — the one that proxy appended; a visitor can
  send their own header, but can't control what the proxy adds after it —
  then `X-Real-IP` when there is no readable `X-Forwarded-For`;
- `::ffff:a.b.c.d` counts as the IPv4 address it carries.

**Forwarded headers from a private peer are trusted with no configuration,**
so the proxy must set or append `X-Forwarded-For` itself. One that only sets
`X-Real-IP` — nginx with just `proxy_set_header X-Real-IP $remote_addr` —
passes the visitor's own `X-Forwarded-For` through untouched, and a visitor
can name any address; add
`proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`. The same
holds on an intranet where visitors have private addresses themselves and
reach the app directly: each of them can send the header.

A proxy or CDN with a **public** address in front of the app (a CDN
forwarding to the origin) is a public peer: its headers are ignored and
every visitor counts as one of its edge addresses. Rewrite `remote_ip` with
a `RemoteIp` plug — see [Behind a CDN and a load
balancer](#behind-a-cdn-and-a-load-balancer).

### Behind a reverse proxy that appends the port (e.g. Caddy `{remote}`)

Some proxy configurations forward `203.0.113.7:51234` instead of
`203.0.113.7` — Caddy with `header_up X-Forwarded-For {remote}` does. Such a
value is read too: an IPv4 address followed by `:port`, and a bracketed IPv6
address with or without one (`[2001:db8::7]:443`), lose the port. A bare IPv6
address is never cut — `2001:db8::1:443` is a valid address.

For LiveView, list `:x_headers` in the socket's `connect_info` (on both
transports, see Installation). Without it, a socket with a private or
loopback peer — a proxy, a container network, localhost in development —
has no way to name its visitor, so the hook records nothing for it — no
live navigation, interaction or "Right now" entry — and counts the skip;
Settings then warns, and the "no JavaScript" bot check pauses so the missed
visits aren't taken for bots. **Add `:x_headers` to the endpoint first,
then deploy 0.5.0 or later.**

The cleaner fix is on the proxy: forward the address without the port. In
Caddy that is `{remote_host}` instead of `{remote}`, or no
`header_up X-Forwarded-For` / `X-Real-IP` lines at all — Caddy 2.5 and later
sets `X-Forwarded-For` itself, without a port:

```caddyfile
reverse_proxy app:4000 {
  header_up X-Real-IP {remote_host}
}
```

### Behind a CDN and a load balancer

With more than one proxy in front, the last `X-Forwarded-For` entry is the
nearest proxy's view of its client — the CDN, not the visitor. Rewrite
`remote_ip` before the tracking plug with a plug that walks the chain over
the proxies you trust — [`remote_ip`](https://hex.pm/packages/remote_ip):

```elixir
plug RemoteIp, proxies: ["198.51.100.0/24"]
plug PhoenixKitWebAnalytics.Plug
```

A public `remote_ip` is taken as is.

**Limitation: LiveView behind such a chain.** A LiveView socket doesn't go
through plugs, so its address still comes from `:x_headers` by the rule
above — the CDN's edge, not the visitor. The page load and the live
connection then hash to different visitors: live navigations and
interactions count as separate visitors, and the page load, seeing no live
connection from its own visitor, is flagged a "no JavaScript" bot after 30
minutes (nothing was skipped, so the check doesn't pause). Until the socket
can walk the chain too, switch **Spot bots by behaviour** off in Settings
(`web_analytics_detect_bots`) on such a site.

## Excluding specific requests

```elixir
conn |> PhoenixKitWebAnalytics.Plug.skip() |> render("preview.html")
```

or, at install time:

```elixir
plug PhoenixKitWebAnalytics.Plug, exclude: ["/healthz", "/internal*"]
```

`exclude:` applies to the plug's page views. The LiveView hook can't see plug
options, so a LiveView page to leave out entirely goes in the
`web_analytics_exclude_paths` setting, which both honour.

## Database

Four tables, created by `mix phoenix_kit.update` through the module's own
versioned migration chain (`PhoenixKitWebAnalytics.Migrations`, V01–V08),
UUIDv7 primary keys, prefix-safe for named-schema installs:

- `phoenix_kit_web_analytics_events` — one row per hit, append-only
- `phoenix_kit_web_analytics_daily_stats` — per-day, per-site totals
- `phoenix_kit_web_analytics_daily_dims` — per-day breakdowns (V04)
- `phoenix_kit_web_analytics_recordings` — session-recording chunks (V06)

On a busy install with a large events table, build V03's, V05's and V07's
indexes `CONCURRENTLY` before upgrading — the migration then skips them; the
statements are in the `PhoenixKitWebAnalytics.Migrations` docs.

## Translations

Every string goes through the module's own gettext backend
(`PhoenixKitWebAnalytics.Gettext`), with English, Estonian and Russian
catalogues in `priv/gettext`.

## License

MIT
