# Pre-release review — everything since v0.9.0

Reviewed 2026-11-15 against `v0.9.0` (`ad95356`) through `21ef1c6`, then the
fixes below. The Claude and Codex reviews in this directory are unchanged.
Phoenix, OTP and Ecto thinking skills were read before the source pass.

Range: the visitor API, the address-health ring, opt-in rate limits, opt-in
`"api"` events, the core floor `>= 3.5.0 and < 4.0.0`, and the lock
refreshes through `phoenix_kit` 3.6.0. Version is still 0.9.0.

## Claude's pre-release fixes, re-checked

1. **Stale `ex_aws_ec2` lock entry.** Gone from `mix.lock`. `deps.unlock
   --check-unused` is part of the gate below.
2. **A visitor map with no id shared one person's limit.** `visitor_key/3`
   returns `nil` for a map that has no binary `visitor_id`, and `hit_visitor`
   then allows. The network bucket is the only counter. The test holds an
   office to `network_limit` 3, not `limit` 1.
3. **One bad app-config rule dropped every configured rule.** Each rule is
   normalized on its own, and a bad one is skipped. The warning it logged
   was the fail-open line, which is a separate bug, fixed below.
4. **Core pin.** `test/core_pin_conformance_test.exs` requires
   `>= 3.5.0 and < 4.0.0`, admits 3.5.0 through 3.9.9, rejects 2.x, 3.4.9
   and 4.0.0, and raises if `PHOENIX_KIT_PATH` strips the requirement.
5. **Smaller.** No user-facing "from core 2.64" string remains (historical
   changelog and older review docs only). `deny/3` halts `:sent`, `:chunked`,
   `:file` and `:upgraded` and still replaces an uncommitted response.
   The README says the tracking plug has to sit in the API pipeline.

## BUG - MEDIUM — a settings outage dropped app-config network exemptions (fixed)

`collection_config/0` answers `disabled_config/0` when the settings read
raises or exits. That map keeps `rate_limit: :on` (the rules and the
counters are not in the table) but set `internal_networks: []`. The usual
"database blip" path inside core's settings cache already rebuilds the map
with `network_entries/1`, so app-config networks survive it. The rescue
path did not. An office listed only in
`config :phoenix_kit_web_analytics, internal_networks:` could be limited
while the table was unreadable, and the blocklist (settings only) correctly
stayed empty.

`disabled_config/0` now uses `network_entries(nil)`: the app-config list
only. The setting's own lines are absent, because they cannot be read.
`config_without_settings/0` exposes that map so the test does not have to
take the settings table down.

## BUG - MEDIUM — a bad rule consumed the fail-open warning (fixed)

`configured_rule/1` called `fail_open/1`. The log line says the rate limit
was not applied and the request was allowed, which is false when another
rule still refuses. Both warnings share a ten-minute key, so the bad rule
could hide a real Hammer failure.

A skipped rule now logs
`rate-limit rule skipped (the others still apply)` under its own key.
The test still requires `t_bad` in the log, and requires the fail-open key
to stay unset.

## IMPROVEMENT - MEDIUM — a cost that did not fit spent the visitor bucket (fixed)

The network bucket is read first and left unchanged when it is full.
The visitor bucket went through Hammer's `hit`, which increments and then
decides. After 4 of a limit of 5, a cost of 2 was refused and the counter
became 6, so a later cost of 1 was refused too.

`count/5` now reads the visitor bucket the same way, before either `hit`.
A refusal spends nothing. A window can still roll between the read and the
`hit`; that one request follows Hammer. An earlier rule that already
charged stays charged when a later rule refuses.

## NITPICK — plug registration id was a 27-bit hash (fixed)

`RateLimit.Plug.init/1` used `:erlang.phash2(rules)` as the persistent-term
id. A collision would skip registering the second plug's rules for the life
of the node, and `charge/3` would allow those names. The id is the
normalized rules term. Equal lists still register once. A reload that
changes a rule and changes it back still keeps the newer registration, as
before.

## Checked, not changed

- The registration lock is `:global.trans({{RateLimit, :register}, self()}, …)`.
  The resource id is shared; `self()` is the requester. Concurrent first
  requests keep every rule (the existing 32-task test).
- `Plug.Crypto.secure_compare/2` returns false when the lengths differ, so a
  short bypass token does not raise into fail-open.
- API rows stay out of visit-shaped reads: stitch, session-start backfill,
  Bots' latest visit, sessions (`session_start`), recent sessions, active
  visitors, dimensions and rollup totals. An API-only day can roll a zero
  `daily_stats` row, which reads as nothing. Raw API events are pruned with
  everything else and are not rolled up, so a period older than retention
  has no API report.
- A per-visitor rate is also per network. The API cap increments both
  counters even when one bucket is already over; the documented ceilings
  (60 and 240 kept) still hold. `BotSignals` down returns 0 and fails open.
- Own traffic is marked, not dropped. A prefetch is `bot: "prefetch"` and
  does not join the visitor. A bot score is stored and shown, and nothing
  blocks on it.
- Blocklist beats exemptions other than the bypass token, including staff
  and localhost. `charge/3` on a visitor map does not re-apply the
  blocklist; the plug does, on the request.
- `charge/3` re-checks staff after a not-exempt plug verdict. It does not
  re-run the host's `exempt` MFA. Re-calling that function on every charge
  can repeat a side effect.
- Nil-id maps are not treated as loopback. A map has no peer to compare
  with the resolved client, and exempting loopback there would skip limits
  for a local proxy.
- `IpHealth` samples the plug's HTML page views before the collector drops
  bots and unconsented hits. The warning says the address "looks like" one
  address. The forwarded-header flag is not part of the verdict, so a
  spoofed `X-Forwarded-For` cannot hide a one-address result.
- The per-node secret used when there is no salt can be written twice if
  two processes start together. The loser keeps hashing with the secret it
  already read until the next call.
- IPv6 shown on the Rate limits page is a `/48` when whole addresses are
  not stored. The bucket key is the `/64`. The display is the coarser one.
- `User.display_name/1` can fall back to the local part of an email. Alerts
  already used it before this range, and the text still does not include a
  full address.
- The install line in the module doc still says `~> 0.2`. It is outside
  this range's edits.

## Gate

`mix precommit` clean (dialyzer: 4 errors, all in `.dialyzer_ignore.exs`, no new ones).
`mix test`: 1,010 tests + 29 doctests, 0 failures, integration included.
