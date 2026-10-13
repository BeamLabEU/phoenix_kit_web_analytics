# PR #7 — Visitor profiles, bot score, consent rules (merged as `f4ce619`)

Author: mdon · Merged: 2026-10-13 · 50 files, +11 555 / −723

Adds what the operator may keep about *who* a visitor is (`web_analytics_store_*`, one
`visitor_profiles` row per visitor ID, migrations V09/V10), a `BotScore` of weighted reasons
with a Bots page, device measurements from the client script (`Signals`), a configurable visitor
ID rotation, and per-purpose consent rules (`Consent`: `always` / `consent` / `unless_objected`,
with the Legal module or a host `consent_source` as the answer, a session note for LiveViews,
and an optional "count the view without a visitor" mode). Five prior commits (`f5b3b5a` …
`b22f85e`) had already folded two validation rounds into the PR, so this was a fresh read of the
merged result, concentrating on the load-bearing rules in `AGENTS.md`.

Read in full: `consent.ex`, `plug.ex`, `collector.ex`, `live_hook.ex`, `profiles.ex`,
`signals.ex`, `bot_score.ex`, `bots.ex`, `data_collection.ex`, the track controller, the config /
admin / migration / visitor / recordings / bot-signals / geo / live-presence diffs, the client
script's new half, and the settings page. The Bots and Session LiveViews were read for input
handling only.

Baseline: `mix test` — 26 doctests, 864 tests, **11 failures** (all in pre-existing LiveView page
tests, see the first finding — none in anything the PR touches).

## Findings

### BUG - MEDIUM — the LiveView page tests expect a `/en` prefix core no longer emits (fixed)

All 11 baseline failures are `href`/`live_patch` assertions in `new_pages_test.exs` and
`report_pages_test.exs` (`/sessions`, `/events`, `/pages`, the Bots filters, the period select).
The suite hard-codes `/en/admin/web-analytics` as the base and the test router mounts the pages
under that scope, but `phoenix_kit` 2.62.2 (the `libs` commit `85b7471`, after the merge) makes
the primary locale prefixless: `Paths.*` now emits `/admin/web-analytics/...`, which the test
router doesn't route and the assertions don't match. Not caused by the PR — but the gate was red
on `main`. Router scope, `@base` constants, `live_case.ex` and the `test_helper.exs` /
`test_router.ex` comments now use `/admin/web-analytics`.

### IMPROVEMENT - HIGH — `visitors` stops being a lossless per-day number as soon as the rotation isn't `daily` (documented, not fixed)

`RollupReader` is built on one stated fact: *"Distinct visitors add up across days exactly,
because the visitor ID itself changes every day."* The PR adds `web_analytics_visitor_rotation`
(`weekly` / `monthly` / `never`) without revisiting it. Rolled-up days store one distinct count
per day and a range sums them; every raw read (`Reports` trend buckets, `active_visitors`, and
anything the rollups don't serve — bots on, a single-path filter, flagged traffic, today alone)
counts `distinct visitor_id` over the whole range. With a longer rotation a returning visitor is
counted once per day in the first and once in the second, so the same headline moves when the
operator ticks **Bots** or filters to a path, and a "last 7 days" total overstates the people
by up to 7×.

Not fixed because it needs a product decision, not a patch: either count
`distinct (visitor_id, day)` on every raw read (changes the meaning of every raw `visitors`
figure and costs a wider hash key), or declare `visitors` "visitor-days" in the UI and add a
distinct-people figure that only raw reads can give. Recorded on the record instead: the false
comment in `rollup_reader.ex` is corrected and `AGENTS.md` carries a rule so the next `visitors`
read is written knowing it. Worth settling before the rotation setting is advertised.

### IMPROVEMENT - MEDIUM — `Profiles.forget/1` is a destructive operator action with no audit trail (fixed)

`AGENTS.md` and `Admin`'s moduledoc say every operator mutation goes through `Admin` and is a
permanent activity entry; the README tells operators to run `Profiles.forget/1` to take stored
data back after switching a `store_*` setting off (the settings page itself says what's stored
"stays until" retention). That call deleted or blanked every profile's address, User-Agent,
headers, network or device data — the exact data this PR exists to protect — and left no record
of who did it or how many rows. Added `Admin.forget_profiles/2` (logs `profiles.forgotten` with
the kind and row count, never a value; `profiles.forget_failed` on a raise; clears the report
cache) and a `Profiles.forget_kind/0` type, with three tests (kind + count + no value in the log,
`:all`, a zero-row run). The README / settings text still point at `Profiles.forget/1`; a button
on the settings page that calls the new function is the natural follow-up and is left to the
author (it needs a confirm step and three gettext strings).

## Noted, not changed

- **A forgotten kind can take behavioural bot evidence with it.** `forget(:signals)` (and any
  kind, via `drop_empty/0`) deletes a row whose identifying columns are all null even when
  `bot_reasons` still holds `rate` / `no_js` / `webdriver`, which aren't derived from the
  forgotten data and name nothing about the person. Defensible (a row with no data is pseudonym-
  only) and simpler than the alternative; flagging it because the Bots page loses those visitors.
- **`upsert_signals/4` overwrites where `upsert/3` merges.** A later signals report that lacks
  canvas / renderer / audio replaces a stored `device_hash` with `nil` (the hash needs one strong
  measurement), whereas the request-side upsert `COALESCE`s. The hash is the device's identity, so
  a weaker re-measure of the same device blanks what was known. Only reachable by the same
  visitor ID reporting twice; left as is.
- **The consent note is as fresh as the last full page load.** A visitor who answers the banner,
  or withdraws, and then live-navigates keeps the old answer in the hook until the next HTTP
  load; the client script's `phx:consent-recorded` handler refreshes recordings and device
  measurements but not the LiveView hook's page views and interactions. Documented in `Consent`
  and the hook; noted because withdrawal is the case where staleness matters.
- **The plug asks the consent source on every GET it sees**, excluded paths and non-HTML
  responses included, because the LiveView note must be written before the path check. One signed
  cookie read per request with the Legal source, whatever the host's source costs otherwise.
- **`BotSignals` counters get one ETS key per anonymous view** (`anon:` IDs are random per hit).
  Bounded — the sweep drops a minute's keys the next minute — so not a leak, just churn under
  `without_consent: anonymous` at volume.

## Verified, no change needed

- **Every collector entry point carries `consent:`.** Plug, LiveHook (page view, interaction),
  LivePresence leave, the beacon / pixel controller, and `track_event` / `track_pageview` with
  `conn:` (which also skips the call entirely under `respect_dnt` + an objecting browser). A hit
  with neither is the host's own call, as documented.
- **A failing consent source fails closed everywhere.** `Consent.status/2` rescues raises,
  catches throws and exits, rejects any return that isn't one of the three atoms and a malformed
  `consent_source`, and logs once per node without naming the visitor; only a clean `:unknown`
  reaches `unless_objected`'s "collect".
- **An anonymous view carries nothing identifying.** `Collector.anonymous/1` drops user, roles,
  headers, network and anchor, keeps only campaign params (click ID dropped), country only, the
  browser's major version, no OS version; the visitor ID is a fresh `anon:` UUID, `lv` is removed,
  no profile is written (`profile_allowed?/1`) and no new-visitor alert fires. Staff flags are
  worked out before the identity is dropped. A forced-bot (prefetch) hit is never counted
  anonymously.
- **Profile writes can't cost an event.** `Profiles.record` runs after the transaction and
  rescues; reason changes inside the transaction go through `Collector.run_async`;
  `rescore/3` holds `FOR UPDATE` from read to write so the request's and the device's reasons
  can't overwrite each other, and request reasons are read from the stored row, not the hit.
- **Credential headers never reach storage.** `@secret_headers` plus the `@secret_words`
  substring rule, `Sec-WebSocket-Key` exempted, `Referer` query stripped, address headers only
  with the whole address kept; the header names stay.
- **The device-measurement boundary holds.** `Signals.clean/1` is an allow-list with types and
  bounds, strings UTF-8-checked / NUL-stripped / truncated, lists capped; the endpoint is gated
  by the setting, the client script switch, `consent.device`, DNT, own-traffic flags, and counted
  per visitor *and* per address (the visitor hash includes the User-Agent). The hash is salted
  and needs one of canvas / renderer / audio.
- **`BotScore` ownership is complete.** Every weighted reason is owned by exactly one source;
  `derived_from/1` covers each reason read from stored data; scores are never used to drop, flag
  `is_bot` or block.
- **Migrations V09 / V10** are prefix-safe (`prefix:` everywhere, bare index names,
  `*_if_not_exists`), add no backfill, the profile table is empty with every setting off, and the
  `''` prefix escaping from `5cda6b1` is in place. `visitor_id string(64)` fits `user:` + UUID.
- **Bots page input handling.** Filters are parsed by regex / whitelist (`one_of/3` never makes an
  atom), the subnet / agent / device narrowing is parameterised, and the page only reads.
- **Translations.** `mix gettext.extract --merge --no-fuzzy` is a no-op (487 messages, 0 new);
  no empty or fuzzy `msgstr` in en / et / ru.
- **Rotation reaches every visitor-ID computation** (collector, recordings, automation flag,
  signals) with the configured period, so a page view and its recording agree on who the visitor
  is.

## Gate

`mix format`; `mix precommit` (compile `--warnings-as-errors`, `deps.unlock --check-unused`,
`hex.audit`, credo `--strict`, dialyzer) passes; `mix test` — 26 doctests, 867 tests, 0 failures
(baseline 11 failures, +3 new tests). Version bumped to 0.7.0 with a CHANGELOG entry; **not
pushed, published or tagged**.
