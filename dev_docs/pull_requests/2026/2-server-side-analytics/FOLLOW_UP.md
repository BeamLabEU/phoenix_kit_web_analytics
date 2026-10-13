# Follow-up — PR #2 (server-side analytics, recordings, bot signals, rollups)

Findings from `CLAUDE_REVIEW.md`, re-checked against the code on 2026-10-13.

## Fixed (pre-existing)

- ~~HIGH: the visitor salt was written to the activity log~~ — the key is
  `web_analytics_hash_secret`, which core withholds (`config.ex`).
- ~~HIGH: rollup reads could raise~~ — `rollup_reader.ex` rescues and degrades.
- ~~MEDIUM: month buckets ignored the time zone~~ — fixed in `rollup_reader.ex`.
- ~~MEDIUM: tokens in paths~~ — `Collector.redact_tokens/1`.
- ~~MEDIUM: presence ignored exclusions and bots~~ — `LiveHook.watchable?/2`.
- ~~IMPROVEMENT: event alerts, zero-view parity, watermark writes, NUL bytes,
  body cap~~ — all in place.
- ~~NITPICK: field labels, empty `en` catalogue~~ — in place.

## Fixed (Batch 1 — 2026-10-13)

- ~~`run_async` dropped a job silently when the task supervisor was full~~ —
  it now says so at debug level (`Collector.start_job/1`).
- ~~The replay player's `ResizeObserver` was never disconnected~~ —
  disconnected in the hook's `destroyed`.
- ~~The schema prefix was escaped with `\'`~~ — SQL's own `''`
  (`Migrations.with_defaults/2`).
- ~~A LiveView socket missing its User-Agent or peer data was not counted as
  a skipped visit~~ — it is, so the no-JavaScript judgement pauses for it too.
- ~~The recording and device-measurement limits were keyed on the visitor
  hash alone~~ — a second, per-address budget sits beside each, so rotating
  the User-Agent no longer mints a fresh one.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_web_analytics/collector.ex` | `start_job/1` logs a dropped job |
| `lib/phoenix_kit_web_analytics/migrations.ex` | Prefix escaping |
| `lib/phoenix_kit_web_analytics/live_hook.ex` | Inert socket counted as skipped |
| `lib/phoenix_kit_web_analytics/recordings.ex`, `web/track_controller.ex` | Per-address budgets |
| `priv/static/assets/phoenix_kit_web_analytics.js` | Observer disconnected |

## Verification

`mix precommit` and `mix test` — see the PR that carries this file.

## Open

Product questions the review raised that are still as they were. Each is a
change in what the module measures or costs, so they are Max's to decide, not
a sweep's:

- **Click targets can hold personal text** — a button's label is stored
  truncated but not scrubbed (`BeaconPayload`). Scrub email-like strings, or
  record plain buttons only when marked `data-analytics`?
- **Time on page and scroll depth stop at the first time a tab is hidden.**
  Keep the maximum across hides, or document "until first hide"?
- **The client script asks `/recording` on every page load**, recording on or
  off. Defer it to the first pointer or scroll event?
- **The rate rule's threshold is per visitor hash**, and a shared address
  (an office, a carrier NAT) is one visitor to it. Raise the default?
- **`@reroll_days` is 2** while a day can still gain late leaves for longer.
- **The report cache stores a failed query's fallback** for its 30 seconds,
  and `clear/0` does not reach a computation already in flight.
- **A stitch that fails inside the hit's transaction is rescued**, after
  Postgres has already aborted it. A savepoint would let the insert survive.
- **Settings and Right now run their queries on both mounts.**
- **V4 clears the rollup watermark** — a shipped migration; noted, not changed.
