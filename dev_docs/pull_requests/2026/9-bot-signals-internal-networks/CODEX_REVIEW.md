# PR #9 — Bots and internal networks: independent recheck

Reviewed 2026-10-24. PR author: timujinne. Merge: `03f7efc`.
Scope includes dependency refresh `630ac39` and Claude's fixes in `60ec4d0`.

## BUG - MEDIUM — rerolling pruned data erases its breakdowns (fixed)

`rollup_day/1` preserves a site's `daily_stats` row when its raw events are
gone, but unconditionally deleted every `daily_dims` row for the date. A
manual reroll after pruning therefore preserved the headline totals while
erasing the pages, acquisition and technology breakdowns that cannot be
reconstructed. A mixed day also lost the pruned site's breakdowns while
correctly rebuilding the other sites.

This deletion predates #9. The PR's new tests for preserving pruned data, and
Claude's follow-up, asserted only totals and missed it. The public reroll API
is relevant here: the GitHub review explicitly notes that older affected days
need manual `Retention.rollup_day/1` calls outside the settling window.

Fix: reuse the normalized list of sites that still have raw events to scope
dimension replacement. A site with only bots/own traffic loses both rollups;
a site with no raw events retains both. Hostless sites continue to use `""`,
retaining Claude's `COALESCE` fix. No additional raw-event query is needed.

Tests extend the fully pruned and mixed-site cases to compare the preserved
dimension rows, and confirm that bot-only and removed page dimensions vanish.
Both preservation assertions failed on `60ec4d0` before the fix.

## Other checks

- Claude's hostless-site key correction is sound. Its regression test passes;
  it now also asserts that hostless dimensions are removed when all hits are bots.
- The network secrecy test really includes settings history: pinned core
  stores history in `phoenix_kit_activities`, which `list_activities/0` reads.
  Core's history and settings broadcasts redact keys containing `secret`.
- Networks remain under the secret key, enter the single cached collection
  read, and are parsed with the same width and syntax limits for both config
  and Settings. No new identifying event columns or scheduled settings writes.
- `stale_browser` belongs to `:request`, contributes 20 points, and does not
  change `is_bot`. It uses the transient User-Agent, so forgetting a stored
  copy should not clear it. Browser anchors remain an approximation as documented.
- Dependency refresh remains Hex based. Validation uses the committed lock,
  including core 2.64.0; it does not establish compatibility with every permitted
  older dependency version.

## Validation

- Baseline: `mix test` — 27 doctests, 929 tests, zero failures, integration enabled.
- Regression run before fixes: both new preservation assertions fail.
- Targeted tests after fixes: 3 doctests, 95 tests, zero failures.
- Final: `mix test` — 27 doctests, 932 tests, zero failures, integration enabled.
- `mix precommit` passes, including compile, lock checks, Hex audit, formatting,
  Credo and Dialyzer (the same four existing Dialyzer suppressions as baseline).
