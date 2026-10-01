# PR #2 — Server-side analytics, session recordings, bot signals, rollups; quality sweep

Author: Dmitri Don (mdon) · Merged: 706a5ea (2026-10-01) · 79 files, +21.6k / −1.5k

## Summary

Turns the module from "a plug that counts page views" into a server-side
analytics suite: a LiveView `on_mount` hook (navigations, interactions, exits),
`LivePresence` ("Right now"), session stitching and a session timeline, an
optional client script (clicks, scroll, exits from non-LiveView pages),
optional session recordings with a replay player, behavioural bot signals,
daily rollups (`daily_stats` / `daily_dims`) read together with raw events in
one `UNION ALL`, a single-flight report cache, activity-feed alerts, an `Admin`
module that logs every operator mutation, and migrations V02–V06. The core pin
moves to `~> 2.38`.

The PR already carries two self-review passes (`Quality sweep…`,
`Fix what re-validating the sweep found…`) and 482 tests. This review was a
fresh pass over the whole of it, split three ways (write path; read path and
persistence; public endpoint, client script and UI). Every finding below was
checked against the producing code, and the ones marked *reproduced* were run.

Baseline before any change: `mix test` — 12 doctests, 482 tests, 0 failures.

## Findings

### BUG - HIGH: the visitor-hash salt was written, in plaintext, to the permanent activity log — **fixed**

`Config.generate_salt/0` stores the salt through
`Settings.update_setting_with_module/3`. Core records every setting write as a
permanent `setting.changed` activity entry and withholds the value only when
the key name marks it as a secret (`secret`, `password`, `token`, `api_key`, …,
or core's own restricted list). `web_analytics_hash_salt` matched none, so the
first salt and **every rotation** were stored as `"from"`/`"to"` with
`"restricted": false`. Anyone who can read the activity feed could recompute a
visitor ID from an IP and User-Agent, and rotating the salt didn't help because
the old ones stayed in the log. This contradicted `Config`'s own "must never be
exposed" and `Admin`'s "never the salt". *Reproduced.*

**Fix:** the key is now `web_analytics_hash_secret`. A fresh secret is
generated on first use after upgrading (the old value is deliberately not
carried over — it is already in the log). Visitor IDs are hashed per day, so
the cost is one day's continuity. New test asserts no activity row holds either
the old or the new value. Operators should treat earlier `setting.changed`
rows for `web_analytics_hash_salt` as exposed and purge them (noted in the
CHANGELOG).

### BUG - HIGH: rollup-backed reports raised instead of degrading — **fixed**

`RollupReader.rollup_totals/raw_totals/rolled_buckets/sites` called
`repo().one/all` bare, while the moduledoc and AGENTS.md promise that every
`Reports` query rescues and degrades. With migrations not run, or on a
transient DB error, `Reports.overview/1`, `timeseries/2` and `sites/1` raised
`Postgrex.Error` and took the Overview LiveView down. *Reproduced.*

**Fix:** `RollupReader` gets the same rescue-and-log `all/2`/`one/2` helpers
`Reports` uses. Test renames the rollup table mid-test and asserts empty
numbers plus a logged warning.

### BUG - MEDIUM: monthly rollup buckets depend on the database session time zone — **fixed**

`date_trunc('month', s.date)` on a `date` yields a `timestamptz` — midnight in
the *session's* zone. East of UTC, Postgrex reads 2026-08-01 back as
2026-07-31T21:00Z, `to_date/1` gives Jul 31, and the bucket matches nothing, so
the whole month vanished from the 12-month and "all" charts. *Reproduced*
(`SET LOCAL timezone = 'Europe/Tallinn'`). **Fix:** `date_trunc('month',
?::timestamp)`. Test sets the session zone.

### BUG - MEDIUM: one-time tokens in core's route paths were stored, reported, and put in alert text — **fixed**

The collector strips `?query` and `#fragment` (for exactly this reason) but not
a token carried *in the path*: `/users/reset-password/:token`,
`/users/confirm/:token`, `/users/magic-link/:token`,
`/users/register/verify/:token`, `/users/qr-login/scan/:token`,
`/profile/settings/confirm-email/:token`, `/access/link/:token`. These are
served as ordinary HTML/LiveView pages, so each was stored verbatim, visible to
every holder of the `web_analytics` permission in the Pages report, and — with
visitor alerts on — pushed to email/Telegram in the "New visitor … on <path>"
text. **Fix:** `Collector.normalize_path/1` replaces the segment after those
routes with `:token` (prefix- and locale-agnostic, ordinary pages with similar
names untouched). Test covers each route plus the false-positive guards.

### BUG - MEDIUM: presence ignored exclusions and bots — **fixed**

`LiveHook` guarded `track_pageview`/`track_interaction` with `trackable_path?`
but called `LivePresence.watch/navigate` unconditionally. An excluded page
(`/shop*`) still appeared under "Right now" and wrote a `leave` row when
closed, and declared bots were listed (and their IP/UA held in memory).
*Reproduced.* **Fix:** the hook only watches when tracking is on, the path is
not excluded and the visitor is not a declared bot (unless bots are recorded);
patching onto an excluded page calls the new `LivePresence.unwatch/1`, which
records the leave for the page it was on and drops the row. Tests for all
three paths.

(The reviewer also found `?pk_replay=1` pages were watched. In practice the
replay iframe is `sandbox` without scripts, so a LiveView never connects there;
not changed.)

### IMPROVEMENT - HIGH: "Tracked events" alerts were forgeable, uncapped and carried visitor text — **fixed**

* LiveView runs `handle_event` hooks before the view's own handler, so the hook
  records *any* event name a client sends; a beacon `n` takes any name too.
* `alert_max_per_hour` only applied to visitor alerts: 5 forged events with
  the cap at 2 produced 5 alerts per recipient.
* `source_label/1` interpolated `referrer_source`, which is the visitor's own
  `utm_source` when a campaign is present, so
  `?utm_source=URGENT: your account is locked, visit evil.example` became the
  notification text. Paths and event names are visitor-controlled too.
* A crawler's first hit alerted when `track_bots` was on.

**Fix:** event alerts take a separate hourly slot (their own counters, so a
burst of one kind can't use up the other's); text from the visitor's side is
cleaned (no control characters/line breaks, 80 chars); a source is only quoted
when it is a short plain name, otherwise the channel label is used; bot hits
never alert. Tests for each.

### IMPROVEMENT - MEDIUM: rolled-up and raw days disagreed on zero-view pages — **fixed**

The rollup drops `daily_dims` rows with neither a hit nor an exit; the raw half
of the same query didn't. A path that only saw interactions was a "top page"
with 0 views while its day was still raw, and disappeared once rolled up —
contradicting `Dimensions`' "never counted differently". *Reproduced.*
**Fix:** the same predicate on the raw side. Test compares raw vs rolled.

### IMPROVEMENT - MEDIUM: one watermark setting write per rolled day — **fixed**

`roll_forward/1` advanced `web_analytics_rolled_through` inside its per-day
loop. Every core setting write is a permanent `setting.changed` entry
(AGENTS.md: "Never write a setting on a schedule"); rolling a 6-day backlog
wrote 6 entries, and the post-V04 reset on a year of data would write ~365.
*Reproduced.* **Fix:** advance once, to the last contiguous day that rolled up.
Steady state is still one write a day (the watermark is a real day boundary);
a stateless derivation would be the next step if that is judged too many.

### IMPROVEMENT - MEDIUM: NUL bytes cost the whole hit — **fixed**

`?utm_source=%00` made the insert raise Postgres `22021` and the hit was lost
(it is rescued, so only that hit; but trivially repeatable). *Reproduced.*
**Fix:** `Event.changeset/2` strips NULs from every string change and from
metadata strings. Test.

### IMPROVEMENT - MEDIUM: body-size caps only applied to `text/plain` — **fixed**

`TrackController.with_body_params/3` capped 16 KB / 128 KB only when it read
the body itself. A `Content-Type: application/json` body is parsed earlier by
the host endpoint's `Plug.Parsers` (default 8 MB) and went straight to
`BeaconPayload`/`Recordings.validate`, which do work proportional to its size.
**Fix:** a declared `content-length` over the cap is dropped for every content
type, before anything is validated. Test.

### NITPICK: untranslated field names, empty `en` strings — **fixed**

The settings error flash fell back to `Atom.to_string` for six fields (a long
exclusion list produced English-only "Check: exclude paths."); they now reuse
the form's own existing labels (no new msgids). 23 empty `en` msgstrs
(AGENTS.md: none may stay empty) filled. `gettext.extract --check-up-to-date`
clean.

## Not fixed — on record

* **Recording rate limit is keyed on the visitor hash**, which includes the
  client-chosen User-Agent, so varying it gets a fresh 30-chunks/minute bucket
  (each chunk up to 2,000 frames). Needs `web_analytics_recording` on (off by
  default). A global per-minute budget needs a number grounded in real
  traffic — a fixed one would throttle busy sites that sample 100% — so it is
  left for a deliberate decision; sampling is the current mitigation.
* **The client script fetches `…/recording?p=` on every page load**, on every
  host that has the package installed, regardless of the recording or
  client-script switches, contradicting its header comment ("nothing is sent
  while the page loads"). `Recordings.record?` also ignores `client_script?`.
  Fixing it means deferring the fetch to the first pointer/scroll event and
  deciding whether recording should require the client-script switch — a
  product call, so left open.
* **Click targets can hold personal text** (`aria-label`/button text such as
  "Sign out jane@example.com", download file names). Make plain buttons
  opt-in via `data-analytics`, or scrub email-like strings in
  `BeaconPayload`.
* **Time on page / scroll stop at the first tab hide** (`reported` is only
  reset on navigate). Document "until first hide" or reset on `visible` and
  keep the max server-side.
* **Mount queries (`LiveNowLive`, `SettingsLive`).** Moving `load/1` into
  `handle_params/3` would change nothing: `handle_params` also runs on the dead
  render, which is how every other page here already behaves. Fixing it for
  real means loading only when `connected?/1` and rendering a skeleton first.
* **Per-visitor limits on shared IPs.** An office/CGNAT crossing 30 page views
  a minute under one IP+UA is flagged `rate`, which retroactively marks the
  visit as bot. Documented as the visitor-hash design; the threshold may want
  to be higher by default.
* **Misconfigured hook marks the visit as a bot.** When the `LiveHook` is
  mounted but can't read `:user_agent`/`:peer_data` (longpoll), the plug has
  already set `"lv"`, the hook stays inert, and after 30 minutes
  `judge_no_js` flags the visit. A one-time warning when the hook goes inert
  would make it diagnosable.
* Smaller: `reroll_recent`'s `@reroll_days 2` never re-rolls the day before
  yesterday (settle is 3 h); a failed query's empty fallback is cached for
  30 s and `ReportCache.clear/0` doesn't invalidate in-flight computations; the
  `stitch` rescue in `Collector` can't save the event after a Postgres error;
  `Collector.run_async` drops silently on `:max_children`; replay player
  doesn't re-apply state on iframe `load` and never disconnects its
  `ResizeObserver`; the V4 migration clears the watermark so long-range charts
  lose pruned history until the first retention pass after boot; `\'` in the
  migration prefix escape (copied from core, input is a mix option).

## Checked and cleared

Replay iframe URL (a visitor cannot make an admin load a visitor-chosen URL —
`loadable` only for plug/LiveView-recorded paths in the same session,
`clean_path` rejects `//`, backslashes, control chars, dot segments; iframe is
`sandbox="allow-same-origin"` with no scripts); XSS (player uses `textContent`
throughout; no `raw/1`); no `String.to_atom`; identity spoofing (`user_uuid`
always nil from the beacon, visitor derived server-side); admin mutations
(behind the admin `live_session`, permission-gated, bounded, logged); the
client script uses no cookies or storage and honours DNT/GPC; rollup/raw
boundary arithmetic (no gap or overlap); `Dimensions` is the single source for
both halves and parameterised; truncation vs unique indexes; `prune_before`
fails closed and never passes the watermark; killing a retention run leaves no
stuck advisory lock; `ReportCache` single-flight claim cleanup and memory
bound; migrations V1–V6 symmetric and prefix-safe with no full-table UPDATE;
`LivePresence` has no monitor/map leak; `BotSignals` ETS is swept; enabled?/0
fails closed.

## Gate

* `mix test` — 12 doctests, 497 tests, 0 failures (482 before; +15 new). The salt test
  and the four read-path tests (month bucket, degrade, zero-view parity,
  watermark writes) were confirmed to fail with the fix reverted; the rest
  pin behaviour the reviewers reproduced but were not re-run against the
  old code.
* `mix precommit` — see the release commit.
