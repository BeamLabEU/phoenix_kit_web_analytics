# PR #5 — Own-traffic flags: internal networks, site staff, staff networks (0.6.0)

Author: timujinne · Merged: 431400e, 2026-10-07 · 61 files, +6.6k / −1.7k

Marks the site's own traffic with bits in `events.traffic_flags` (migration V08):
`internal_network` (CIDRs from app config), `admin` (signed-in staff role) and
`admin_network` (the network of a recent staff sign-in/request, ETS only). Reports,
rollups, "Right now", alerts and recordings leave marked traffic out; a report can
count it back in. Two review rounds were already folded into the PR (`4405fc1`,
`79c0384`, `f3c59a5`), so this was a fresh pass over the merged result: the write path
(`plug.ex`, `collector.ex`, `live_hook.ex`, `tracking.ex`), `internal_traffic.ex`,
`live_presence.ex`, `reports.ex`/`rollup_reader.ex`/`retention.ex`, `recordings.ex`,
the filter plumbing in `web/`, migration V08, checked against core 2.55.1 in `deps/`.

Baseline: `mix test` — 15 doctests, 638 tests, 0 failures (three more seeds, same);
`mix precommit` clean; `mix gettext.extract --merge` — 0 new / 0 removed, no empty or
fuzzy `msgstr` in en/et/ru.

## Findings

### BUG - MEDIUM — the Visits pager dropped the new switches (fixed)

`SessionsLive` built its **Older** / **Newer** URLs from `period`, `site` and `user`
only. The PR added the **Own traffic** and **Bots** switches to every report and made
`PagesLive`'s pager carry them (`Filters.to_params/1`), but missed this one, so on
Visits, with Own traffic ticked, clicking **Older** silently unticked it: the next page
was read without the own-traffic hits and the `before` cursor then pointed into a
different list. The page filter (`path`) was dropped the same way (older than the PR).

Fix: the pager takes `Filters.to_params(filter)` plus `user`/`before`. Test: 51 flagged
visits, `?flagged=1&bots=1&path=/landing`, both links keep all three, and the switches
stay ticked after paging.

### NITPICK — `Tracking.current_roles/1` guarded with `function_exported?` on an unloaded module (fixed)

`function_exported?/3` is `false` for a module not loaded yet, which would have taken
the `user_roles/1` branch (the role the user is *acting as*, not the ones they hold).
In practice a scope's module is loaded because something built the scope, but the
guard is cheap to make right: `Code.ensure_loaded?(Scope) and …`.

## Noted, not changed

- **`x-tidewave-diagnostic` skips tracking for anyone who sends it.** The header is a
  development tool's, but the plug honours it in production too, so it is a one-line
  opt-out (as DNT already is). Harmless to the data; the alternative (honouring it only
  from a loopback peer) wouldn't hold behind a local reverse proxy, so it stays.
- **"Visits by <staff user>"** (`/sessions?user=`) is empty by default, since staff
  visits are left out; the **Own traffic** switch shows them. That follows from the
  design (the list is a report like any other); the empty state doesn't say why.
- **The visit page's "Back" link** goes to `/sessions` without the filter. The visit
  page has no filter of its own to carry.
- **100.64.0.0/10 (CGNAT shared space)** isn't in `public?/1`, so a staff sign-in
  whose recorded address is in it would be learnt as a staff network. Only reachable
  when the address the host reports is itself a carrier-side one; left as is.

## Verified, no change needed

- **Nothing in the tracking path can raise.** `InternalTraffic.flags/2`,
  `note_admin_network/2`, `lookup_roles/2` and the plug's `note_staff/2` each rescue (and
  catch exits); every ETS touch rescues `ArgumentError`, so a stopped server reads as
  "no flags", not a failed page.
- **The back-write is correct under the lock.** `flag_session/2` only runs for a bit the
  session's latest hit lacks, updates through `(session_id, inserted_at)`, and the
  `(flags & added) <> added` guard keeps it idempotent; the hit itself carries
  `flags ||| stitch.flags`, so the latest row always holds every bit of the visit.
- **The rollup/raw split can't count differently.** `rollups_apply?/1` requires the
  mask to be *every* bit; any other mask (or `flagged: true`) reads raw, and the raw
  remainder applies the same `filter_flags`. The day query in `Retention` uses
  `traffic_flags = 0`. The mid-visit write-back onto an already-rolled day is the
  CHANGELOG's stated known limit.
- **Staff-network sign-in address uses core's rule.** `SessionFingerprint` takes
  `IpAddress.extract_from_conn/1` → `client_address/1`, the same rule as
  `Tracking.client_ip/1`, so a proxy's address isn't learnt as the staff network;
  `"unknown"` parses to nothing and is ignored.
- **CIDR matching** (`value >>> (bits - prefix) == base >>> (bits - prefix)`) binds as
  intended; `/33`, `/`, `-1`, family mismatches and non-strings are rejected; an
  IPv4-mapped address is unmapped on both sides.
- **V08 is prefix-safe and cheap.** `add_if_not_exists`/`remove_if_exists` with
  `prefix:`, a constant default (catalogue-only), no index, no backfill — consistent with
  the "never a long step in a migration" rule. `bit_or(smallint)` and `(smallint & $n)`
  run in PostgreSQL as used.
- **Presence counters stay consistent.** `@paths` and `@flagged` change together in
  `insert_visit/2` / `remove_visit/2`, `navigate` replaces the flags with the page, and
  `page/1`'s cursor is the last *shown* key, so skipped flagged pages are never
  re-walked or lost.
- **The `internal_networks` config never reaches storage.** Warnings count invalid
  entries and never quote them; the settings page shows counts; staff networks are
  ETS-only and the `-` roles sentinel is the only thing a setting stores.
- **No new core component collides with an auto-import**, and the module's own strings
  are translated in en/et/ru.
