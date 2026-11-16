# PR #12 — Fix the dashboard crash when the previous bounce rate is 0.0

Author: timujinne · Merged: 2f9257c, 2026-11-16 · 2 files, +32 / −1

`Components.delta/2` returned `nil` for a zero previous value only when it was the
integer `0`. The dashboard's bounce-rate card passes floats (`Reports.percentage/2`
returns `bounces * 100 / sessions`, always a float), so a previous period in which
every session reached a second page gave `0.0`. That fell through to the arithmetic
clause and raised `ArithmeticError` on `/ 0.0`, crashing the Overview page. The clause
now reads `when previous == 0`, which matches `0`, `0.0` and `-0.0`. A new async unit
test (`test/phoenix_kit_web_analytics/web/components_delta_test.exs`) covers both.

## Verification

- **The trigger is real.** `bounce_rate` is `percentage(totals.bounces,
  totals.sessions)` (`reports.ex:249`). That is `nil` with no sessions and a float
  otherwise, so `0.0` exactly when `bounces == 0` and `sessions > 0`. On a small
  site's short previous window, that happens.
- **All callers are covered.** `delta/2` has four call sites, all in
  `dashboard_live.ex` (visitors, pageviews, sessions, bounce rate). The three counts
  pass through `RollupReader.to_int/1` (`numbers/1`), so they are integers, or `0`
  when the period was empty. Only the bounce rate can be a float, and the fix covers
  it.
- **No Decimal path.** `RollupReader` normalises every `sum(...)` to an integer
  (`to_int/1` rounds a `Decimal`). A `Decimal` would also miss the `== 0` guard and
  the `is_number` clause, and fall through to the catch-all `nil` rather than raise.
- **Sibling zero guards are not affected.** `Reports.percentage/2` and `average/2`,
  `DailyStat.bounce_rate/1` and `avg_session_seconds/1`, `PagesLive.share/2` and
  `Components.share/2` all guard with a strict `in [0, nil]` or a literal `0`. Each
  divisor there is a count (sessions, `*_count`, pageviews max) that comes out of
  `to_int/1` or an integer column, so a float `0.0` cannot reach them. I left them
  alone.
- **Rendering.** `stat_card`'s `:if={@delta}` treats `0.0` (no change) as truthy and
  shows `0.0%`. That is correct. `format_delta/1` only ever gets a float.

## Findings

### NITPICK — a rate is compared as a relative change (not changed)

The bounce-rate card shows a relative change: 40% → 44% renders as `+10%`, not
`+4 pp`. For that reason, a 0.0% → 42.5% move now shows no badge at all, although
it is the largest change the card can show. A percentage-point delta for rate
metrics would fix both. That is a display decision, not a defect, and it is out of
scope for a crash fix, so I'm only recording it here.

### NITPICK — no LiveView-level regression test (not changed)

The test exercises `delta/2` directly, not the dashboard rendering with a previous
period at 0% bounce. `delta/2` is where the exception was raised and is a pure
function, so the unit test locks in the fix. Building a two-period event fixture
just to re-prove it through the LiveView would add cost without covering anything
new.

## Verdict

Correct and complete. No changes needed.
