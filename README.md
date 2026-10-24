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
- **No cookies, and by default nothing to ask consent for.** Visitors are
  identified by a salted hash of IP + User-Agent + date. Out of the box no IP
  address, no raw User-Agent and no query string is written to the database.
  (An ad platform's click identifier is kept when a visit arrives with one —
  see [Privacy](#privacy).) Keeping more is a setting, one kind of data at a
  time — see [What is kept about a visitor](#what-is-kept-about-a-visitor).
- **Ad blockers can't remove it.** The numbers are your server's.
- **The data is yours.** Five tables in your own database; nothing leaves
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
| Device measurements and a device hash (optional, off by default) | Screen, time zone, languages, processor, graphics card, fonts, canvas and audio rendering — once per page load, only when asked | client script + **Keep device measurements** |
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
| Bots | Visitors by how much they look automated and why; grouped by network, subnet, address, device or User-Agent; the likely bots of a grouping as a list to block by |
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

   A `live_session` you don't write takes the hook another way: PhoenixKit's
   own pages through `extra_live_session_on_mount`, a library's (LiveDashboard,
   for one) through its own `on_mount:` option, and a `live` route outside any
   `live_session` has to be wrapped in one first. Settings and the dashboard
   warn about tracked pages whose `live_session` lacks the hook; pages you
   don't want tracked go in Settings → Excluded paths instead.

   ```elixir
   config :phoenix_kit,
     extra_live_session_on_mount: [{PhoenixKitWebAnalytics.LiveHook, :track_navigation}]
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

Inside a request, pass the conn: the event then takes the visitor's address,
User-Agent and site from it, so it joins that visitor's visit, and it follows
the visitor's answer under the [consent rules](#when-it-is-collected-consent):

```elixir
PhoenixKitWebAnalytics.track_event("order.placed", %{conn: conn, path: "/checkout"})
```

`track_pageview/1` takes `:conn` the same way. **A hit with neither `:conn`
nor `:consent` is stored on your word** — the module asks nothing of the
visitor for it. Passing `:ip` or `:user_agent` by hand while a rule waits for
an answer stores an event and a profile for a visitor who may have refused.

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
- **Visitors** — daily unique visitor hashes among page views, added across
  the period. One visitor on three days counts as three under every
  `web_analytics_visitor_rotation`. The "right now" figure counts unique IDs
  within its short window.
- **Sessions** — stitched server-side: a hit joins the visitor's previous
  session on the same site if it's within the inactivity window (30 minutes by
  default), otherwise it starts a new one. A session needs a page view.
  Report totals count each UTC day's portion of a visit separately; the visit
  list and timeline show the full visit.
- **Bounce rate** — daily visit portions with exactly one page view.
- **Session length** — first hit to last within each daily visit portion,
  exits included, so a single page read for three minutes on the same day is
  a three-minute session.
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

#### Bot score and the Bots page

A flag is a verdict: the visit leaves the reports. Beside it, every visitor
something is kept about (see
[What is kept about a visitor](#what-is-kept-about-a-visitor)) carries a
**bot score** — the sum of the weights of the reasons found — and the
reasons themselves. Nothing is dropped, flagged or blocked because of a
score; it is there to look at and decide by.

| Source | Reasons (weight) |
|--------|------------------|
| The request, when a visit starts | says it is a bot (100) · no User-Agent (70) · hosting provider's network (40) · a phone's User-Agent from a hosting provider (30) · HTTP/1.0 (30) · no `Accept-Language` (25) · a current browser's User-Agent without `Sec-Fetch-*` (25, HTTPS only) · a Chromium User-Agent without `Sec-CH-UA` (20, HTTPS only) · no `Accept` (15) |
| The device, when the client script reports | device and User-Agent name different systems (50) · graphics drawn in software (40) · a screen or window with no size (40) · no browser language (40) · a phone's User-Agent without touch (30) |
| Behaviour (the three checks above) | automation (90) · speed (70) · no JavaScript (50) |

60 and over reads as *likely a bot*, 30 and over as *suspicious*. Header
reasons need **Keep request headers**, network reasons **Keep the network's
owner** and a resolver that knows it, device reasons **Keep device
measurements**: what isn't collected can't count.

**Web Analytics → Bots** lists those visitors, the likeliest first, with
their reasons, and groups them by what several share — network, subnet,
address, device, User-Agent. A group opens its visitors; the address-shaped
groupings offer their likely bots as a plain list to paste into a firewall
or a CDN rule. Declared bots only appear with **Record bot traffic** on —
otherwise they are dropped before anything is kept.

### Your own traffic

Visits by the site's own people are real traffic, but not the audience. They
are **stored with a mark and left out** — of every report, the rollups,
"Right now", alerts and recordings — rather than dropped, so a switch turned
back brings them back. Three marks (`traffic_flags` on each event, bits of
`PhoenixKitWebAnalytics.TrafficFlags`; a hit can carry several):

| Mark | Set when |
|------|----------|
| **Internal network** | the visitor's address is in one of the networks in the **Internal networks** field of Settings or in `config :phoenix_kit_web_analytics, internal_networks: [...]` |
| **Site staff** | the signed-in user holds a staff role (`web_analytics_internal_roles`: Owner and Admin by default) — the roles they really hold, whichever one they are acting as |
| **Staff network** | the visitor's network (an IPv4 address, an IPv6 /64) had a staff member signed in or active within `web_analytics_admin_network_hours` (24 by default) |

The internal networks come from two places, and both count. Enter them in
Settings, under **Leave out internal networks**, one per line: an address, or
a network as `203.0.113.0/24` or `2001:db8:1234::/48`. A network wider than
`/8` (IPv4) or `/16` (IPv6) is refused: `0.0.0.0/0`, or a `/2` meant as `/24`,
would mark nearly every visit as your own, and correcting the setting later
does not unmark the rows. Or list them in the app config:

```elixir
# config/runtime.exs
config :phoenix_kit_web_analytics,
  internal_networks: ["203.0.113.0/24", "2001:db8:1234::/48"]
```

Every settings change is a permanent activity-log entry, and this one is your
own addresses, so the setting is stored under
`web_analytics_internal_networks_secret`: core withholds the value of a key
with `secret` in its name from that entry and from the change broadcast. The
addresses never reach the activity log. They are matched against the client
address as the module resolves it (`X-Forwarded-For` from a private peer, see
[Behind a reverse proxy](#behind-a-reverse-proxy)), so behind a proxy that is
the first thing to check when nothing gets excluded.

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

The module sets no cookie and writes no local storage (the one thing it keeps
in the host's session is described under
[consent](#when-it-is-collected-consent)), and with the settings as they ship
no IP address and no raw User-Agent is stored. A visitor ID is

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
that set them. The internal networks are the Settings field and your app's
config (the setting's value is kept out of the activity log); staff networks
are held in memory, by their network key, for their hours, and never written
to the database or the settings.

### What is kept about a visitor

The defaults above are a starting point, not a rule the module enforces.
What a site may keep, and whether it has to ask first, depends on the law it
answers to and on what the data is for — telling crawlers apart and blocking
abuse is not the same question as measuring an audience. So each kind of
identifying data has its own setting (Settings → **Who a visitor is**), all
of them off until switched on:

| Setting | Keeps |
|---------|-------|
| `web_analytics_visitor_rotation` | How long a visitor ID lasts: `daily` (default), `weekly`, `monthly`, or `never` — the same ID for as long as the address, browser and salt stay the same, which recognises a returning visitor across days |
| `web_analytics_store_ip` | The address: `off` (default), `truncated` (its `/24` or `/48` network) or `full` |
| `web_analytics_store_user_agent` | The raw User-Agent string — which crawler, which library, which exact version |
| `web_analytics_store_headers` | The request headers of a visit's first page view, in arrival order, with the protocol |
| `web_analytics_store_network` | The network's number (ASN), its owner and whether it is a hosting provider — when your geo resolver returns `:asn`, `:network` and `:hosting` |
| `web_analytics_store_signals` | What the client script measures about the device, and a salted hash of the stable part — a **device hash** that stays the same when the address changes. This is browser fingerprinting; it needs the client script on. The measurements are listed in `PhoenixKitWebAnalytics.Signals` |

They are written to one row per visitor ID
(`phoenix_kit_web_analytics_visitor_profiles`) when a visit starts, never to
the event rows, and shown on the visit's page. A row goes when its visitor
hasn't been seen for `web_analytics_retention_days`. Switching a setting off
stops it being recorded; `PhoenixKitWebAnalytics.Admin.forget_profiles/2` removes
what is already stored (`:ip`, `:user_agent`, `:headers`, `:network`,
`:signals` or `:all`), along with the bot reasons that were read from it.

Never kept, whatever the settings: the value of a header that carries a
credential (`Cookie`, `Authorization`, anything named like a token, key or
secret — its name still shows that it was sent), and the query string of
`Referer`. Headers that carry the visitor's address (`X-Forwarded-For` and
the like) keep their value only when the address itself is kept whole.

**Visitors means daily unique visitors added across the period**, under every
rotation: one visitor on three days counts as three. Raw reads and daily
rollups use the same definition, including monthly charts and exit visitors.
A longer-lived ID lets you follow returning visits; it does not change that
aggregate. The "right now" figure counts unique IDs in its short window.
Visit totals, bounce rate and average visit length also use daily portions:
a visit spanning UTC midnight contributes separately to each day. The visit
list and timeline continue to show the full visit.

Stored profile data can also be removed from Settings → **Data & retention**.
The removal records the acting user, kind and affected row count in the activity
log, never a stored value. Forgetting an address or User-Agent also removes its
values from stored request headers. Independent bot evidence remains until
retention or an explicit `:all` removal. Switch the corresponding collection
setting off first to prevent new values being collected.

Countries are only recorded if you configure a resolver
(`PhoenixKitWebAnalytics.Geo`) or run behind a CDN that sets a country header.
No IP database ships with this package.

### When it is collected: consent

Whether a visitor has to be asked before any of this is collected depends on
the law a site answers to, so the module takes no position. Each kind of
collection has its own rule (**Settings → When it is collected**):

| Kind | Setting | What it covers |
|---|---|---|
| Counting visits | `web_analytics_consent_measurement` | Page views, visits and events under the visitor ID |
| Details about a visitor | `web_analytics_consent_profile` | What `store_ip`, `store_user_agent`, `store_headers` and `store_network` keep |
| Device measurements | `web_analytics_consent_device` | What `store_signals` keeps |
| Session recordings | `web_analytics_consent_recording` | Recordings |

and each rule is one of:

| Rule | Collected when |
|---|---|
| `always` (default) | Every time. The visitor is told, not asked — how the module worked before the rules existed |
| `consent` | The visitor said yes |
| `unless_objected` | The visitor has not said no, and the browser sends neither `Sec-GPC: 1` nor `DNT: 1` |

The settings page offers four starting points — *Tell, don't ask*, *Count
visits, ask for the rest*, *Ask first*, *Collect until refused* — which only
fill the four rules in; any combination can be saved.

The last three kinds describe a visitor, so they are only ever kept for one
whose visits are counted. A page view that may not be counted is dropped, or
— with `web_analytics_without_consent` set to `anonymous` — counted with no
visitor: its own visitor and visit, no user, no profile, so page totals stay
whole while visitor and visit counts rise with every such view. Such a view
keeps its campaign (`utm_*`), its country, and the browser and system with
the browser's major version, and nothing finer: no ad-click identifier, no
region, no city, no exact build. It is still marked as the site's own traffic
when it is (a staff member, an internal network). Its row is marked
`metadata["anon"]`, it never raises a new-visitor alert, and it is never
judged a no-JavaScript bot.

**Where the answer comes from.** PhoenixKit's Legal module, when it is
installed and its cookie banner is on: the banner reports each decision to the
server, which sets a signed cookie this module reads. A site with its own
consent tool points the module at it instead:

```elixir
config :phoenix_kit_web_analytics, consent_source: {MyApp.Consent, :status}

# MyApp.Consent.status(conn, "analytics") :: :granted | :denied | :unknown
```

With neither, every visitor is unanswered: `consent` collects nothing (the
settings page warns) and `unless_objected` collects for everyone whose browser
does not object.

**A consent source that fails answers `:denied`.** One that raises, throws,
exits or returns anything but those three atoms — or a `consent_source` that
is not a `{module, function}` pair — could not say whether the visitor
refused, so it is read as a refusal rather than as "no answer", which
`unless_objected` would collect from. It is logged once per node, naming the
source. A source that cleanly returns `:unknown` is taken at its word.

**When the answer applies.** It is read from the request, so it is as fresh as
the last page load. A LiveView cannot see cookies: the plug notes the answer
in the session, and it holds for live navigation until the next full page
load. The Legal banner reloads on withdrawal by default; keep that option
on when using these rules. A host consent tool must also force a full page
reload after changing an answer, including withdrawal; a LiveView navigation
or reconnect alone does not refresh the session note. The note is all a LiveView knows, so **the
plug must run after `:fetch_session`**: a session with no note is read as a
visitor who objected and has not answered, and nothing that waits for an
answer is collected on LiveViews until the plug has written one. The client script re-asks the server the
moment the banner reports a decision, so device measurements and a recording
can start on the page where the visitor said yes. Changes to consent rules
and the selected category are applied to open LiveViews and their delayed
leaves; a yes to the previous category does not allow the new one. Nothing
collected before a yes is held back for later — there is no queue to flush.

`web_analytics_respect_dnt` is separate and blunter: while it is on, a browser
sending `DNT` or `Sec-GPC` is not tracked under any rule, a yes in the banner
included. The plug notes that in the session for LiveViews too, and takes the
note back on the first request that no longer carries the signal.

**What visitors are told.** The module declares what it is collecting right
now (`PhoenixKitWebAnalytics.data_collection/0`), following the settings: each
kind with its rule, what exactly is kept, and for how long. The Legal module
lists that under the matching toggle of its banner and in the Cookie Policy it
generates. The module sets no cookie of its own and writes no storage. While
a rule waits for an answer, the visitor's answer is noted in the site's own
session cookie (the note above); that is declared too, under the measurement
entry's `storage`.

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
| `web_analytics_exclude_paths` | `/admin*` … | Path patterns to ignore (trailing `*` = prefix; also matched past a leading locale, `/et/admin`) |
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
| `web_analytics_internal_networks_secret` | empty | The site's own networks, one per line (an address or a CIDR network, IPv4 or IPv6), added to the config's `internal_networks`. The name keeps `secret` so core keeps the value out of the activity log |
| `web_analytics_internal_roles` | `Owner, Admin` | Roles whose holders are site staff (comma-separated; `-`, an emptied field, is no one) |
| `web_analytics_admin_network_hours` | `24` | How long a staff sign-in marks its network (`0` = never) |
| `web_analytics_visitor_rotation` | `daily` | How long a visitor ID lasts: `daily`, `weekly`, `monthly`, `never` |
| `web_analytics_store_ip` | `off` | Keep the visitor's address: `off`, `truncated`, `full` |
| `web_analytics_store_user_agent` | `false` | Keep the raw User-Agent |
| `web_analytics_store_headers` | `false` | Keep the request headers of a visit's first page view |
| `web_analytics_store_network` | `false` | Keep the network's ASN, owner and hosting flag (needs a resolver that returns them) |
| `web_analytics_store_signals` | `false` | Keep the client script's device measurements and a device hash (needs the client script) |
| `web_analytics_consent_measurement` | `always` | When visits are counted: `always`, `consent`, `unless_objected` |
| `web_analytics_consent_profile` | `always` | The same, for what the `store_ip` / `_user_agent` / `_headers` / `_network` settings keep |
| `web_analytics_consent_device` | `always` | The same, for device measurements |
| `web_analytics_consent_recording` | `always` | The same, for session recordings |
| `web_analytics_consent_category` | `analytics` | The consent category the four rules follow: `analytics`, `marketing`, `preferences` |
| `web_analytics_without_consent` | `drop` | A page view that may not be counted: `drop` it, or count it `anonymous` (no visitor) |
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
# the statistics — see "Your own traffic". CIDR, IPv4 or IPv6. The Settings
# page has a field for the same list; both are counted.
config :phoenix_kit_web_analytics, internal_networks: ["203.0.113.0/24"]

# The day a browser's age is judged at (the "stale browser" bot reason).
# Leave it unset; a test suite whose fixtures carry fixed User-Agents pins it.
config :phoenix_kit_web_analytics, browser_versions_as_of: ~D[2024-06-01]

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

The address is visitor-hash input, and stored only if you switch that on
([What is kept about a visitor](#what-is-kept-about-a-visitor)). The plug, the
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

Five tables, created by `mix phoenix_kit.update` through the module's own
versioned migration chain (`PhoenixKitWebAnalytics.Migrations`, V01–V10),
UUIDv7 primary keys, prefix-safe for named-schema installs:

- `phoenix_kit_web_analytics_events` — one row per hit, append-only
- `phoenix_kit_web_analytics_daily_stats` — per-day, per-site totals
- `phoenix_kit_web_analytics_daily_dims` — per-day breakdowns (V04)
- `phoenix_kit_web_analytics_recordings` — session-recording chunks (V06)
- `phoenix_kit_web_analytics_visitor_profiles` — what is kept about a visitor,
  one row per visitor ID; empty unless a setting asks for it (V09, V10)

On a busy install with a large events table, build V03's, V05's and V07's
indexes `CONCURRENTLY` before upgrading — the migration then skips them; the
statements are in the `PhoenixKitWebAnalytics.Migrations` docs.

## Translations

Every string goes through the module's own gettext backend
(`PhoenixKitWebAnalytics.Gettext`), with English, Estonian, Russian and
Ukrainian catalogues in `priv/gettext`.

## License

MIT
