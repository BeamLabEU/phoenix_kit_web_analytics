# PhoenixKitWebAnalytics

Privacy-first web analytics for [PhoenixKit](https://hex.pm/packages/phoenix_kit) —
the numbers a hosted analytics product gives you, **without the script tag**.

Tracking happens server-side, in a plug. One line in your router:

```elixir
pipeline :browser do
  # … existing plugs …
  plug PhoenixKitWebAnalytics.Plug
end
```

That is the entire installation.

## Why this instead of a script tag

- **Nothing is added to your pages.** No bundle to download, no render-blocking
  request, no third-party domain, no extra bytes. Page weight and Core Web
  Vitals are exactly what they were before you installed it.
- **No cookies, no consent banner.** Visitors are identified by a salted hash of
  IP + User-Agent that rotates every day and is never stored in reversible
  form. No IP address is written to the database.
- **Ad blockers can't remove it.** There is no client-side request to block, so
  the numbers are your server's, not a script's.
- **The data is yours.** Two tables in your own database. Nothing leaves your
  infrastructure.

## What you get

Six admin pages under **Web Analytics** in the PhoenixKit sidebar:

| Page | What it shows |
|------|---------------|
| Overview | Visitors, page views, sessions, bounce rate, average session, average server response — each with change against the previous period — plus the traffic trend and the top four breakdowns |
| Pages | Every path ranked by views, and the slowest pages by average response time |
| Acquisition | Channels (direct / organic / social / referral / email / paid), referring sites, and UTM campaigns |
| Technology | Browsers, operating systems, device classes, languages, countries |
| Events | Custom events, plus a live feed of the most recent hits |
| Settings | Collection rules, retention, stored-data stats, and the installation checklist |

The admin charts are plain `div`s with percentage heights — no charting library
anywhere in this package.

## Installation

```elixir
# mix.exs
{:phoenix_kit_web_analytics, "~> 0.2"}
```

```bash
mix deps.get
mix phoenix_kit.update   # creates the two tables
```

Then add the plug (above), and enable **Web Analytics** on the admin Modules
page. Traffic starts appearing immediately.

### LiveView navigation

The plug sees HTTP requests, which covers the first load of a LiveView page but
not `push_patch` / `push_navigate` afterwards. To count those, add the hook to
your `live_session`:

```elixir
live_session :public,
  on_mount: [{PhoenixKitWebAnalytics.LiveHook, :track_navigation}] do
  live "/", HomeLive
  live "/pricing", PricingLive
end
```

The hook needs the same inputs the plug has, so your endpoint's socket must
expose them:

```elixir
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [:peer_data, :user_agent, session: @session_options]]
```

Without both keys the hook stays inert rather than recording visits under a
mismatched visitor hash — check this first if LiveView navigations don't show up.

### Behind a proxy or load balancer

`conn.remote_ip` feeds the visitor hash. Behind a proxy that's the proxy's
address, which collapses every visitor into one. Put a plug that rewrites
`remote_ip` from headers your infrastructure controls — such as
[`remote_ip`](https://hex.pm/packages/remote_ip) — **before** the tracking plug.

## Custom events

From server-side code, where the event is a fact your app already knows:

```elixir
PhoenixKitWebAnalytics.track_event("order.placed", %{
  path: "/checkout",
  metadata: %{"total_cents" => 4900},
  user_uuid: user.uuid
})
```

From the browser, if you need it, there's an optional ~300-byte inline snippet
(no file, no bundle). Enable the beacon in Settings, then:

```heex
<.beacon />

<button onclick="phoenixKitAnalytics('signup', {plan: 'pro'})">Sign up</button>
```

For pages served from a full-page CDN cache that never reaches your app,
`<.pixel cache_buster={@request_id} />` records the view with a 1×1 image.

Both endpoints are public and unauthenticated, which is why they're off by
default — leave them off unless you use them.

## Querying the data yourself

`PhoenixKitWebAnalytics.Reports` is a plain module:

```elixir
import PhoenixKitWebAnalytics.Reports

filter = filter(period: "30d")

overview(filter)
#=> %{pageviews: 18_204, visitors: 6_133, sessions: 7_802, bounce_rate: 41.2, …}

top_paths(filter, limit: 20)
#=> [%{label: "/pricing", pageviews: 2_104, visitors: 1_755}, …]
```

## How counting works

Stated explicitly, because it's what makes two analytics tools disagree:

- **Page views** — rows with `event_type = "pageview"`. Custom events are never
  page views.
- **Visitors** — `COUNT(DISTINCT visitor_id)`. The hash rotates daily, so one
  person browsing on three days counts as three visitors over a week. That's the
  honest consequence of not tracking people across days.
- **Sessions** — `COUNT(DISTINCT session_id)`, stitched server-side: a hit joins
  the visitor's previous session if it's within the inactivity window (30
  minutes by default), otherwise it starts a new one.
- **Bounce rate** — sessions with exactly one page view.
- **Average session** — last hit minus first hit, so single-page sessions
  contribute zero.

### What is skipped

Non-`GET` requests, non-2xx responses, anything that isn't `text/html`, paths
matching the exclusion patterns (`/admin*` by default), requests sending
`DNT: 1` or `Sec-GPC: 1`, and automated User-Agents. All configurable in
Settings.

## Privacy

There is no cookie, no local storage, and no IP address column. A visitor ID is

```
SHA256(daily_salt + IP + User-Agent + date)
```

truncated to 32 hex characters. It cannot be reversed to an IP, cannot be joined
across days, and the salt never leaves your server. The raw User-Agent string is
not stored either — only the browser/OS/device classification derived from it.

Two people behind one NAT with identical User-Agents hash to the same visitor.
That slightly undercounts on shared networks; the alternative is a cookie, which
is what this module exists to avoid.

Query strings are not stored. Campaign parameters (`utm_*`) are extracted into
their own columns first; everything else — session tokens, reset links, email
addresses — is discarded before the row is written.

Countries are only recorded if you configure a resolver
(`PhoenixKitWebAnalytics.Geo`) or run behind a CDN that sets a country header.
No IP database ships with this package.

## Data growth and retention

This is the one PhoenixKit table that grows with traffic rather than content.
An hourly background pass:

1. **rolls up** each completed day into per-site totals, then
2. **prunes** raw events past the retention window (365 days by default; `0`
   disables pruning), in batches, and only for days already rolled up.

So the long-range trend line is permanent while the raw row count stays bounded.
What is lost past the horizon is the ability to break an old day down by page or
referrer — reports fall back to rollups for the trend and don't present a
partial ranking as if it were complete.

## Performance

The request process does three cheap things: a method/path check, one ETS read
for settings, and `register_before_send/2`. Enrichment, the session-stitch
query, and the insert all happen in a supervised task after the response is on
its way out — no database work while the client waits.

The task supervisor has a `max_children` cap. Under a flood, hits are dropped
rather than queued: an analytics backlog must never become the reason your app
runs out of database connections.

## Configuration

Everything is a setting in your PhoenixKit settings table, editable from the
admin Settings tab with no redeploy:

| Key | Default | Meaning |
|-----|---------|---------|
| `web_analytics_enabled` | `false` | Master switch (the module toggle) |
| `web_analytics_respect_dnt` | `true` | Skip `DNT: 1` / `Sec-GPC: 1` requests |
| `web_analytics_track_bots` | `false` | Record automated traffic |
| `web_analytics_exclude_paths` | `/admin*` … | Path patterns to ignore (trailing `*` = prefix) |
| `web_analytics_session_timeout_minutes` | `30` | Inactivity gap that ends a session |
| `web_analytics_retention_days` | `365` | Age at which raw events are rolled up and deleted |
| `web_analytics_beacon_enabled` | `false` | Accept hits from the public beacon / pixel endpoints |

Application config (not settings):

```elixir
# An IP → location resolver; see PhoenixKitWebAnalytics.Geo
config :phoenix_kit_web_analytics, geo_resolver: MyApp.GeoIP

# Read X-Forwarded-For for the visitor hash. Only when something upstream is
# guaranteed to overwrite it — a `remote_ip` plug is the better fix.
config :phoenix_kit_web_analytics, trust_x_forwarded_for: true
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
versioned migration coordinator (`PhoenixKitWebAnalytics.Migrations`), UUIDv7
primary keys, prefix-safe for named-schema installs:

- `phoenix_kit_web_analytics_events` — one row per hit, append-only
- `phoenix_kit_web_analytics_daily_stats` — per-day, per-site rollups

## License

MIT
