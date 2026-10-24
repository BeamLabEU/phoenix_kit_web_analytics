# PR #9 — Catch more bots posing as browsers; internal networks in Settings

Author: timujinne · Merged: 03f7efc, 2026-10-24 · 24 files, +2227 / −1176 (half of it
gettext churn)

What it does:

- **`stale_browser`** bot reason (weight 20, `:request`). Chrome, Edge and Firefox count
  as stale when they are about 24 four-week releases behind a dated anchor, and Safari
  when it is older than 16. `:browser_versions_as_of` pins the day for test fixtures.
- **More UA markers** (Google's other crawlers, playwright/puppeteer/selenium, heritrix
  …), `k6/` only at the start, and a bare `Mozilla/5.0` with no platform.
- **Internal networks in Settings** under `web_analytics_internal_networks_secret`,
  added to the app config's list. Every line must parse, a prefix shorter than `/8` or
  `/16` is refused (`check_cidr/1`), and the list rides in `collection_config/0`, so a
  hit makes no settings read of its own. A failed write is logged without its value
  (`failure_summary/1`).
- **Retention** drops a site's `daily_stats` row for a day once all of that site's raw
  hits that day are marked (a bot found later, or own traffic).

Checked against core 2.64.0: `Events.secret_key?/2` matches any key containing
`secret`. Core's newer **settings history** (`Settings.History`) uses the same test: the
entry records `restricted: true` and withholds both values. `value_at/2` returns `nil`
for such a key. So the AGENTS.md rule ("withheld from `setting.changed` and the
broadcast") still holds at 2.64, and now covers the history table as well.

## Findings

### BUG - MEDIUM — the emptied-site drop missed hits without a host (fixed)

`emptied_sites/3` selected the raw `e.site` and looked it up in `totals`. But
`Dimensions.totals/1` keys sites by `COALESCE(site, '')`, and the stored row holds `""`
for the same reason. A hostless site was therefore `nil` in one place and `""` in the
other. `Map.has_key?(totals, nil)` never matched, and `s.site in [nil]` never matches
the stored `""` row. The result: a day whose hostless hits had all been marked kept its
stale rollup row, which is exactly the case the change was written for. The fixtures
always set `site`, so the tests didn't catch it.

Fix: select `COALESCE(site, '')`. Test: "drops the row of hits without a host once
they're all marked". It fails on the merged code and passes now.

### IMPROVEMENT - MEDIUM — nothing tested that the networks stay out of the activity log (fixed)

The setting's whole reason for its name is that core withholds the value. The PR tests
the module's own log line but not core's `setting.changed` row or history entry. The
salt has exactly that test ("no activity row, core's own setting history included,
holds a salt"). Added the same test for the networks, with two writes, so that both a
`from` and a `to` would show up if core ever leaked them.

### NITPICK — `stale_browser` and old iPhones (not changed)

An iPhone 6s or 7 cannot go past iOS 15, so it is capped at Safari 15 and counts as
stale. The PR handles this on purpose: the weight is 20, below the 30 "suspicious" line,
so it only counts together with another reason, and the moduledoc says so.

### NITPICK — the Chrome/Firefox anchors drift with the new cadence (not changed)

The two-week majors make the estimate fall *behind* the real current version, so fewer
browsers are judged stale over time, never more. That is the safe direction, and the
comment says when to move the anchors.

## Fixes

- `lib/phoenix_kit_web_analytics/retention.ex` — `emptied_sites/3` keys by `COALESCE(site, '')`
- `test/phoenix_kit_web_analytics/retention_test.exs`, `admin_test.exs` — tests as above
