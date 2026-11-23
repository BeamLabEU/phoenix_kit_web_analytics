# Post-release review — everything since the v0.10.0 Hex release

Scope: `v0.10.0..HEAD` (74a7c52), confirmed against Hex: `latest_version` on
hex.pm is `0.10.0` (published 2026-11-15). Four commits: PR #12 (the
`delta/2` float-zero fix + test + its review doc) and two "lib upgrades"
(mix.lock only). Reviewed 2026-11-16+; changes made here are listed under
"What I changed".

## 1. PR #12 — the `delta/2` float-zero fix (3e9da81, merged 2f9257c)

**Verdict: correct, and now proven at the LiveView level.**

The fix `def delta(_current, previous) when previous == 0, do: nil` matches
`0`, `0.0` and `-0.0` (`==` is numeric comparison in guards), where the old
literal `0` clause matched only the integer. The trigger was real:
`bounce_rate` is `percentage(bounces, sessions)` = `bounces * 100 / sessions`,
a float, so a previous period with sessions but no bounces yields exactly
`0.0`, which fell through to `/ 0.0` and raised `ArithmeticError` during
render.

I audited every other division in the read path for the same hazard:

- `Reports.percentage/2` / `average/2`, `PagesLive.share/2`,
  `DailyStat.bounce_rate/1` / `avg_session_seconds/1` guard with
  `in [0, nil]` (strict — `0.0` does not match), but every divisor there is a
  count that passes through `RollupReader.to_int/1` or a `COUNT(...)`, so a
  float zero cannot reach them. Verified at the source: `session_totals_query`
  uses `count(...)` for `sessions` / `bounces`.
- `Components.share/2` guards with a literal `0`; its `max` comes from
  `max_value(rows, :pageviews)`, counts only.
- `live_now_live.ex:284` wraps its divisor in `max(..., 1)`;
  `Components` `ceil(n / 7)` / `100 / n` use integer counts or guards;
  `div/rem` sites all divide by constants; the one SQL division
  (`SUM::float / SUM(duration_count)` in `slowest_paths`) is guarded by
  `having sum(duration_count) > 0`.

So `delta/2` was the only place a float `0.0` could be a divisor. No further
fix needed.

### IMPROVEMENT - MEDIUM (fixed here) — the bounce-rate delta is now percentage points

PR #12's own review recorded this nitpick: a rate card compared with a
relative change renders 40% → 44% as `+10%` (not `+4 pp`), and — after the
crash fix — a `0.0% → 42.5%` move shows no badge at all, although it is the
largest change the card can show. Since a previous `0.0` is a real baseline
for a rate, I added `Components.delta_pp/2` (plain `current - previous`,
`nil` only when either side is `nil`) and the bounce card now uses it with a
new `delta_unit={:pp}` attr on `stat_tile`, formatted as `%{value} pp`
(new msgid, translated in en/et/ru/uk — ru/uk use `п.п.`). Count cards keep
the relative `delta/2`.

### IMPROVEMENT - MEDIUM (fixed here) — LiveView-level regression test

Added `report_pages_test.exs` "renders when the previous period's bounce
rate was 0.0": a two-page visit 10 days ago (previous window bounce rate
exactly `0.0`) plus a single-page visit now, then mounts the dashboard.
Proven to be a real guard: in a worktree at `v0.10.0` this test fails with
`ArithmeticError` at `components.ex:1040` called from
`dashboard_live.ex:157`; on current HEAD it passes. `delta_pp/2` is covered
in `components_delta_test.exs`, including `delta_pp(42.5, 0.0) == 42.5`.

## 2. The two "lib upgrades" commits (208b82d, 74a7c52 — mix.lock only)

**Verdict: sound, and they clear security advisories.**

- The pins match what core 3.7.0 requires: its changelog states upgrades need
  Phoenix `1.8.17` in the 1.8 line and a patched LiveView (`1.2.14+`), and the
  lock now has phoenix 1.8.17 / phoenix_live_view 1.2.15. `phoenix_kit`
  3.6.0 → 3.7.0 sits inside the module's `>= 3.5.0 and < 4.0.0` floor/ceiling.
- postgrex 0.23.0 is fine: core's `~> 0.22` (two segments) admits `< 1.0.0`.
- Core 3.7.0's changelog has no removals and nothing touching the APIs this
  module integrates with (settings `*secret*` withholding, the Hammer
  table, `PubSub.Manager`, `Activity`, `session_created`). Compile against
  3.7.0 is warning-free.
- `mix hex.audit`: **no retired or advisory packages** on the new lock; the
  v0.10.0 lock did have advisories, so the upgrades fix those too.
- `mix deps.unlock --check-unused`: clean. The lock was produced without
  `PHOENIX_KIT_PATH`, so it reflects the Hex pin as required.

## Verification (this review)

- `mix compile --warnings-as-errors`: clean.
- `mix test`: 29 doctests, **1018 tests, 0 failures** (1014 before this
  review; +3 `delta_pp` unit tests, +1 LiveView regression test).
- Negative proof: worktree at `v0.10.0` + the new regression test → 1 failure,
  `ArithmeticError` in `delta/2` from `DashboardLive.render/1`.
- `mix credo --strict`: no issues. `mix format --check-formatted`: clean.
- `mix hex.audit`, `mix deps.unlock --check-unused`: clean.
- `mix dialyzer`: passed (`done (passed successfully)`, exit 0; the 4
  "errors" are the project's pre-existing `:skip` entries, 4 skipped,
  0 unnecessary skips).
- Gettext: `mix gettext.extract --merge --no-fuzzy`; the only new msgid is
  `%{value} pp`, filled in en/et/ru/uk; `gettext_test` passes.

## Not changed

- No version bump, no CHANGELOG entry, no tag, no Hex publish — releasing is
  a separate step (`hex-publish`). The PR #12 fix and these improvements
  should get a changelog line at the next version bump.
- The `0.0` delta badge showing `0.0%`/`0.0 pp` for "no change" was left as
  is — truthy `0.0` renders the badge, which PR #12's review judged correct.
