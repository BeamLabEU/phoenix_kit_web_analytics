# PR #6 — Chrome speculative prefetch

Author: timujinne. Merged 2026-10-10 as `baeb054`.
Reviewed 2026-11-01 against `51ef04e`, including subsequent changes.

Reviewed the prefetch classification, separate visitor hashing, LiveView first
connect and reconnect handling, JavaScript activation queue, bot evidence,
session display and existing tests. Phoenix, OTP and Ecto thinking skills were
read before source review. This records an independent Codex review; the
existing Claude review is unchanged.

## BUG - MEDIUM — an unactivated prerender still recorded visitor activity (fixed)

`prefetch_param?/1` refused the initial recovered page view while
`prerendering: true`, but `on_mount/4` still attached both hooks. The first
`handle_params` registered presence, later patches and interactions recorded
ordinary human activity, and disconnecting could record a leave. A supplied
`_live_referer` also selected the live-navigation branch before the prerender
guard. This could create phantom visits for a page nobody opened, including a
LongPoll connection made before activation.

The connected mount now skips analytics entirely while either `true` or
`"true"` says the page is prerendering. The host must still defer connecting
until activation, as documented. Activated connects continue through the
existing recovery path.

Replaced the narrow synthetic page-view test with a real LiveView regression:
connect with a prerender marker and live referer, assert no presence, click,
patch, disconnect, and assert no events. Both accepted marker forms are tested.
The test failed against the original implementation.

## Verified and limitations

- Speculative requests retain their own bot identity and skip the visitor's
  page-view speed counter; recovered connects provide JavaScript evidence.
- `_mounts` still prevents recovered reconnects from counting twice, and live
  navigation plus delivery markers still counts once.
- The optional script holds beacons and initial recording setup until
  activation. No new client storage or script was introduced.
- Browser delivery/revalidation behavior was reviewed from code and existing
  documentation; no real-browser Speculation Rules experiment was performed.
  Recovery for controller-rendered cached pages remains outside this PR's
  documented LiveView mechanism.

## Validation

`PGHOST=127.0.0.1 PGUSER=postgres mix test`: **1,004 tests and 29 doctests,
zero failures**, integration tests enabled on a temporary local PostgreSQL 18
instance. `mix precommit`: **passed**, with only the four existing ignored
Dialyzer warnings.
