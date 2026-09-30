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
  string is written to the database.
- **Ad blockers can't remove it.** The numbers are your server's.
- **The data is yours.** Two tables in your own database; nothing leaves your
  infrastructure.

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

Signed-in users are attributed by their account on every hit, so a person's
visits can be followed across the site (Sessions → a user's visits).

## Admin pages

Under **Web Analytics** in the PhoenixKit sidebar:

| Page | What it shows |
|------|---------------|
| Overview | Visitors, page views, sessions, bounce rate, session length and time on page, with change against the previous period; the trend; top pages, referrers, channels, devices, what visitors do, exit pages |
| Right now | Every page open this moment, for how long, by whom (signed-in name or anonymous), on what; visits active in the last five minutes |
| Sessions | Every visit: who, landing → exit page, pages, actions, duration, source, client. Opens a **visit timeline** — everything that visitor did, in order |
| Pages | Every path with views, time on page and exits; a path opens the overview filtered to it; slowest pages by server response time |
| Acquisition | Channels (direct / search / social / referral / email / paid), referring sites, UTM campaigns |
| Technology | Browsers, operating systems, devices, languages, countries |
| Events | What visitors do (interactions), custom events, and a live feed of every hit |
| Settings | Collection rules, retention, interaction and client-script switches, alerts, stored-data stats, installation checklist |

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
     websocket: [connect_info: [:peer_data, :user_agent, session: @session_options]],
     longpoll: [connect_info: [:peer_data, :user_agent, session: @session_options]]
   ```

   Without both keys the hook stays inert rather than recording visitors it
   would hash wrongly.

4. **Behind a proxy or load balancer**, put a plug that rewrites `remote_ip`
   from headers your infrastructure controls — such as
   [`remote_ip`](https://hex.pm/packages/remote_ip) — **before** the tracking
   plug, or every visitor collapses into one.

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
component):

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
included), and automated User-Agents. All configurable in Settings.

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
parameters (`utm_*`) are extracted into their own columns first; everything
else is discarded before the row is written. An interaction keeps only the
event's name and the short values of parameters you allow-list (`tab`, `view`,
`step` … by default) — never form contents.

A **signed-in** visitor's hits carry their account id, which is what lets you
follow a user's visits; anonymous visitors stay anonymous.

Countries are only recorded if you configure a resolver
(`PhoenixKitWebAnalytics.Geo`) or run behind a CDN that sets a country header.
No IP database ships with this package.

## Data growth and retention

This is the one PhoenixKit table that grows with traffic rather than content.
An hourly background pass:

1. **rolls up** each completed day into per-site totals (tracked with a
   "rolled up through" date, re-rolling the last two days to catch late
   hits), then
2. **prunes** raw events past the retention window (365 days by default; `0`
   disables pruning), in batches, and never past the last rolled-up day.

So the long-range trend line is permanent while the raw row count stays
bounded.

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
| `web_analytics_exclude_paths` | `/admin*` … | Path patterns to ignore (trailing `*` = prefix) |
| `web_analytics_session_timeout_minutes` | `30` | Inactivity gap that ends a session |
| `web_analytics_retention_days` | `365` | Age at which raw events are rolled up and deleted |
| `web_analytics_track_interactions` | `true` | Record LiveView events as interactions |
| `web_analytics_ignore_events` | `validate` | LiveView event names never recorded |
| `web_analytics_event_params` | `tab, view, section, step, sort, filter, period` | Event parameters whose short values are kept |
| `web_analytics_client_script` | `false` | Store the client script's clicks, scroll depth and exits |
| `web_analytics_beacon_enabled` | `false` | Accept page views from the beacon / pixel endpoints |
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

# Read X-Forwarded-For for the visitor hash (plug, beacon and LiveView). Only
# when something upstream is guaranteed to overwrite it — a `remote_ip` plug
# is the better fix. For LiveView, also list :x_headers in connect_info.
config :phoenix_kit_web_analytics, trust_x_forwarded_for: true

# Concurrent background writes before hits are dropped.
config :phoenix_kit_web_analytics, max_concurrent_writes: 20
```

## Excluding specific requests

```elixir
conn |> PhoenixKitWebAnalytics.Plug.skip() |> render("preview.html")
```

or, at install time:

```elixir
plug PhoenixKitWebAnalytics.Plug, exclude: ["/healthz", "/internal*"]
```

## Database

Two tables, created by `mix phoenix_kit.update` through the module's own
versioned migration chain (`PhoenixKitWebAnalytics.Migrations`), UUIDv7
primary keys, prefix-safe for named-schema installs:

- `phoenix_kit_web_analytics_events` — one row per hit, append-only
  (V01; V02 adds `engaged_ms`, `scroll_depth`, `target` and a
  `(session_id, inserted_at)` index)
- `phoenix_kit_web_analytics_daily_stats` — per-day, per-site rollups

## Translations

Every string goes through the module's own gettext backend
(`PhoenixKitWebAnalytics.Gettext`), with English, Estonian and Russian
catalogues in `priv/gettext`.

## License

MIT
