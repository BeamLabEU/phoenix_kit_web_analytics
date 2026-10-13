# PR #7 — release-readiness review

Reviewed on 2026-10-13 against `863b591`, including Claude's follow-up and
the merged PR (`f4ce619`). Release candidate remains **0.7.0** in all three
version references. Hex's public package API still lists **0.6.1** as latest.
This review does not publish, push or tag the release.

## Findings and fixes

### BUG - HIGH — report counts depend on whether the days have been rolled up

Claude correctly identified the visitor-count mismatch but left it open.
Longer visitor-ID rotations let one ID appear on multiple days: daily rollups
sum daily uniques, while raw totals, dimensions, exit visitors and monthly
trends previously counted that ID once across the entire window.

Reports now consistently count distinct `(visitor_id, UTC day)` pairs.
**Visitors means daily unique visitors added across the period**, under every
rotation. The short-window "right now" figure continues to count unique IDs.
The README, schema documentation, tooltips, changelog and agent instructions
explain the definition. Existing daily rollups need no migration or backfill.

A second mismatch existed for visits spanning midnight: with a durable visitor
ID, the same session can have page views on both days. Raw reads counted one
session and its full duration; rollups counted its daily portions. The shared
session aggregate now groups by session and UTC day, making visit totals,
bounces and session seconds consistent too. The session list and timeline
continue to show the full visit. This daily aggregate definition is explained
in the UI and README.

Regression coverage compares all report families before rollup, after rollup
and after raw-event pruning, under weekly/monthly/never rotation. It also
covers raw bot/path filters, monthly trends and a visit crossing midnight.

### BUG - HIGH — forgetting an address leaves its copies in stored headers

`forget(:ip)` blanked the address column but retained address-bearing header
values collected while full-address storage was enabled. The same duplicate
storage problem affected `forget(:user_agent)` and the `user-agent` header.

Both operations now remove their header values too, retaining header names.
Profiles whose only copy was in headers are included in the affected-row count.
Repeated removal returns zero once all matching values are gone.

The storage boundary also trusted header maps handed directly to the collector
as already sanitised. Such a map could keep credentials, addresses while the
address setting was off, or query strings in `Referer`. Capture now normalises,
bounds and redacts those maps using the same storage rules as the plug.
Regression tests cover both entry paths, including mixed-case header names.

### BUG - MEDIUM — erasure can partially succeed, or delete unrelated bot evidence

Profile data updates, reason removal and empty-row deletion previously ran as
separate statements without a transaction. A failure could leave partial
erasure, and rescoring could observe data being removed without its reasons.
These changes now happen in one transaction. A database-trigger regression
test verifies rollback when the final deletion fails.

Rows with independent bot reasons now survive removal of a different kind of
data. Only truly empty rows are dropped; `:all` still explicitly deletes every
profile. Tests cover rate evidence and automation evidence on a signals-only
profile. The audit count also includes rows changed only through header copies
or derived reasons.

### BUG - MEDIUM — incomplete device reports erase measurements and their evidence

A second report without canvas, renderer or audio replaced the stored signals
and blanked the device hash. It also rescored from the incoming report rather
than what remained stored. Concurrent reports could leave the score associated
with a different measurement snapshot.

Cleaned measurements now merge with stored ones. Explicit values replace old
values; absent or invalid values preserve earlier measurements. The merge,
device hash and signals score run in one transaction, with the existing row
lock. A partial-report regression verifies hash preservation and retained
evidence, then verifies that an explicit renderer replacement updates both.

### BUG - HIGH — changing consent settings leaves open LiveViews using old permissions

The hook cached permissions at mount. Introducing a requirement or changing
the consent category could therefore leave existing sockets collecting under
the previous rules, including their delayed leave events.

Live hits now carry only the plug's consent note and its category, never the
host's full session. The hook and collector re-apply current rules to it.
A missing note fails closed when a requirement is introduced; an answer for
the old category does not authorise a new category. A denied page is removed
from presence on its next socket activity, and the collector also checks
idle-page leaves. Anonymous views discard this context along with identity.
Three integration regressions cover those cases.

**Visitor answer changes still need a full HTTP load.** A socket cannot read
updated browser cookies. Legal reloads on withdrawal by default, confirmed
against its implementation; hosts must keep that option on or arrange a full
reload through their own consent tool. Live navigation or reconnect alone
does not refresh the note. This existing integration constraint is now
explicit in the README and Consent documentation. No client-supplied grant
or additional cookie/storage was introduced.

### IMPROVEMENT - MEDIUM — make audited erasure available to operators

Claude's `Admin.forget_profiles/2` was useful but had no settings-page action,
and the README still directed operators to the unaudited low-level helper.
Settings now has a kind selector and a confirmed removal form. Work runs
asynchronously; duplicate submissions are ignored while it runs. The handler
uses a fixed allow-list and passes actor options to Admin. The UI reports
success or failure and refreshes storage counts. The README points to Admin.
LiveView tests verify erasure and its audit entry, and reject unknown kinds.

## Validation

- `mix precommit`: passed, including compilation with warnings as errors,
  unused-lock checks, Hex audit, strict Credo and Dialyzer. The existing
  Gettext/Expo opaque-type exclusion remains unchanged; no new exclusions.
- `mix test`: **26 doctests, 882 tests, 0 failures**, including PostgreSQL and
  LiveView integration tests; 15 additional regression tests over Claude's
  867-test result.
- Named-schema PostgreSQL check: install to V08, upgrade to V10, insert a
  profile using the new defaults, roll back to V08 and upgrade again to V10.
  Runtime version reads passed; the public schema remained V10. The temporary
  schema was removed afterwards.
- `mix gettext.extract --merge --no-fuzzy`: catalogues updated; all new strings
  translated in en/et/ru, with no empty or fuzzy entries.
- `mix hex.build`: built 0.7.0 successfully with the published dependency
  configuration; no local core override. Package includes the client asset and
  catalogues, and excludes tests and review documents.
- `git diff --check`: passed. No dependency, lockfile or migration changes.

## Release notes

The code is prepared for the unreleased 0.7.0 candidate. The CHANGELOG includes
these fixes and the host requirement to run `mix phoenix_kit.update` for
V09/V10. Claude's route-test fixes and audited Admin API remain intact.

Hex audit reported an expired cached authentication session. An API key is
configured, so this is not proof that publishing will fail, but publishing
authentication has not been exercised. No publish was attempted.
