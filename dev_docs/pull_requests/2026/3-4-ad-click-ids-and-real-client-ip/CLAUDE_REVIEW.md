# PRs #3 and #4 — Ad-click identifiers (0.4.0) and the real client IP (0.5.0)

Author: timujinne · Merged together: 3036c8e (#3) and 6bf468e (#4), 2026-10-07

- **#3** `add-ad-click-ids` — `gclid`/`gbraid`/`wbraid`/`msclkid`/`fbclid`/`ttclid`/`li_fat_id`
  are kept in `click_id` + `click_param` (migration V07), and an ad-only
  identifier makes the visit `paid`. 24 files, +607 / −61.
- **#4** `real-client-ip` — behind a private/loopback peer the client address is the
  last `X-Forwarded-For` entry (then `X-Real-IP`), by core's rule; the LiveView
  hook stays inert for a proxied socket without `:x_headers`, counts the skip,
  and the no-JavaScript bot judgement pauses while skips are ≥ 5 % of a node's
  live visits. 19 files, +1.5k / −0.7k.

Both PRs carry their own post-review fix commits (`2bca92e`, `fb03987`,
`9667247`, `8c38a38`, `d04553c`), so this was a fresh pass over the merged
result: the write path (`tracking.ex`, `collector.ex`, `plug.ex`,
`live_hook.ex`), `bot_signals.ex`, migration V07, and the doc/UI claims,
checked against the producing code and core 2.55.1 in `deps/`.

Baseline: `mix test` — 13 doctests, 549 tests, 0 failures.
`mix gettext.extract --merge` — 0 new / 0 removed, no empty or fuzzy `msgstr`
in en/et/ru.

## Verified, no change needed

- **The client-IP rule matches core's.** `Tracking.client_ip/1` run against
  `IpAddress.client_address/1`'s source: last entry across all header lines, then
  `X-Real-IP`; an unreadable last entry (`unknown`, a trailing comma) falls to
  `X-Real-IP`/the peer exactly as core does. Ports (`a.b.c.d:p`, `[v6]:p`) are
  stripped, a bare IPv6 is never cut, `::ffff:a.b.c.d` is unmapped. A public peer's
  headers are ignored. *Run, not just read.*
- **Core floor is high enough.** `client_address/1` and
  `client_address_from_socket/1` arrived in core 2.18; the module pins `~> 2.38`.
  An old core can't make `socket_ip/1`'s `rescue` swallow an
  `UndefinedFunctionError` into "skipped" for every visitor.
- **`BotSignals` ETS keys don't collide.** `:started_at`, `{:rate, …}`,
  `{:live, kind, hour}` and `{:live_skipping, node}` have distinct shapes; each
  match spec and the sweep's `select_delete` only touches its own. The table is
  bounded (≤ 48 `:live` rows). Every public read rescues `ArgumentError`, so a
  not-started process degrades to "nothing skipped" / "judge nothing".
- **`count_live_visit/1` is once per connected mount.** `client_info/1` is only
  reached from `mount_connected/1`, so patches and events don't dilute the 5 %
  share.
- **V07 is prefix-safe and fits the name limit.** `add_if_not_exists`,
  `create_if_not_exists`, `prefix:` threaded, bare index names; the longest,
  `phoenix_kit_web_analytics_events_click_param_inserted_at_index`, is 62 chars
  (limit 63). The `CONCURRENTLY` recipe in the moduledoc uses the same names.
- **No `Logger`/hot-path regression.** The plug's `before_send` and
  `Tracking.client_ip/1` both rescue; `warn_deprecated_config/0` runs once in a
  `:temporary` Task.
- **DNT/GPC still gate the whole hit**, so `click_id` is never stored for an
  opted-out visitor.

## Findings

None of these is a defect in the merged behaviour; they are the limits a
maintainer should know about. None was changed except the last.

### IMPROVEMENT - MEDIUM: CGNAT (`100.64/10`) and link-local (`169.254/16`, `fe80::/10`) proxies are treated as public peers

`Tracking.local?/1` is a copy of core's list (10/8, 172.16/12, 192.168/16, 127/8,
`::1`, `fc00::/7`, mapped). A reverse proxy or ingress reached over a Tailscale /
CGNAT address, or a link-local one, is then a "public" peer: its
`X-Forwarded-For` is ignored and every visitor hashes to the proxy. Same
symptom the PR set out to fix, for those networks. *Run: `100.64.0.1` and
`169.254.1.1` peers with a forwarded header return the peer.*

**Not fixed.** The copy is deliberately identical to core's so the plug, the
hook and a login agree on who a visitor is; widening it here would split them.
The right fix is in core (`IpAddress.local?/1` public, ranges widened), after
which this copy can be deleted. The README's "Behind a chain" advice
(`RemoteIp` before the plug) is the workaround meanwhile.

### IMPROVEMENT - MEDIUM: `click_id` is stored on every hit that carries it, including internal ones

With Google's `url_passthrough` the identifier rides along on every internal
link of an ad visit. `click_referrer_*` correctly ignores it for an `internal`
hit, but the column is still filled, so one ad visit writes N rows with the same
`click_id` and grows the partial `(click_id)` index N-fold. A conversion upload
needs one per session.

**Not fixed.** Storing it only on the session's first hit would need the
collector to know the session before the insert (it stitches inside the same
transaction, so it could), and dropping it from later hits loses nothing the
first doesn't have — but it changes what `click_id` means in the schema after a
release and wants its own test matrix. Worth doing if the index size shows up.

### IMPROVEMENT - MEDIUM: `?gclid=…`/`?msclkid=…` forges "paid" traffic

Any visitor, or the beacon's client-supplied URL, can mark a visit `paid` with
an arbitrary identifier (≤ 255 chars). It is the same trust level as
`utm_medium=cpc` always was, and the BeaconPayload moduledoc now says so; there
is no way to verify an identifier server-side without the ad platform's API.
Recorded so nobody builds a "ROAS" figure on `click_id` without a conversion
check on the platform's side.

### NITPICK: `Tracking.client_ip/1` round-trips a public peer through core

For a public `remote_ip` it formats the tuple (`:inet.ntoa`), then parses it
back, per request, on the hot path — the answer is the peer. Cheap, and it
keeps "core's answer" literally core's, so it was left.

### NITPICK: a PubSub that isn't up logs a warning every sweep

`subscribe_to_live_skips/0` retries (and warns) each minute until the internal
PubSub exists. Core starts it with the app, so in practice this is a boot-time
line or two; if it ever persists it is the log that says why. Left as is.

### NITPICK: moduledoc line over the wrap — **fixed**

The `connect_info` sentence in `PhoenixKitWebAnalytics`'s `Installation` section
ran past 80 columns after PR #4 added `:x_headers`; reflowed.

## Outcome

Gate and release: see the CHANGELOG / commit that follows. Hex was at 0.3.0, so
0.4.0 (PR #3) was never published; it ships inside 0.5.0.
