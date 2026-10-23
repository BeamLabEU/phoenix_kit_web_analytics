# AGENTS.md

This file provides guidance to AI agents working with code in this repository.

## Project Overview

Web analytics as a PhoenixKit plugin module, recorded **server-side**: a plug
counts page views, and a LiveView `on_mount` hook records what visitors do on
LiveView pages — navigations, interactions (events the LiveView handles) and
exits — straight from the socket. An optional client script (shipped via
`js_sources/0`, its reports stored only when switched on) adds what a server
can't see: outbound/download clicks, scroll depth, exits from non-LiveView
pages. It tracks the one site it's installed on.

Premise to check changes against: server-side first. Anything that can be
known on the server is recorded there; the client script only covers what
can't, stays optional, and never writes a cookie or storage.

## Architecture

**Write path** (must never slow down or break a host request)

- `plug.ex` — page views. In the request process: a method/path check, one
  cached settings read, `register_before_send/2`. Notes DNT/GPC in the session
  for the hook.
  A Chrome Speculation-Rules prefetch/prerender (`Sec-Purpose`/`Purpose`) is
  handed to the collector with `bot: "prefetch"`.
- `live_hook.ex` — LiveView: page views for live navigation (`_live_referer` +
  `_mounts == 0`; a reconnect is not a view), interactions via an
  `attach_hook(:handle_event)`, and registration with `LivePresence`. A first
  connect carrying the host's prefetch params (`nav_delivery`, `prerendered`)
  is a page view too (`"prefetch_connect"`): no plug request ever fired for it.
- `live_presence.ex` — monitors LiveView processes; ETS "who is on which page
  now"; records a `"leave"` with `engaged_ms` on DOWN or on a patch.
- `collector.ex` — enrichment + insert in a capped `Task.Supervisor` (drops,
  never queues). Session stitching runs with the insert in one transaction
  under an advisory lock on the visitor. Calls `Alerts.event_recorded/2`.
- `tracking.ex` — the helpers the plug, hook and beacon share (client IP rule,
  UTM params and ad-click identifiers, current user, UTF-8-safe truncation).
- `{visitor,user_agent,referrer,geo}.ex` — pure classification helpers.
- `web/{track_controller,beacon_payload,beacon}.ex` — the public endpoint for
  the client script, beacon and pixel. `BeaconPayload` is the trust boundary.
- `priv/static/assets/phoenix_kit_web_analytics.js` — the client script.
- `bot_signals.ex` — behavioural bot detection (automation flag, speed, no
  JavaScript) and the per-visitor-per-minute counters (page views, recording
  chunks). The collector asks it per hit; the retention pass runs its
  stateless no-JavaScript judgement.
- `recordings.ex` + `schemas/recording.ex` — optional session recordings:
  validation (the frame format is documented there), sampling, the
  per-visitor rate, replay assembly, pruning. The player is the
  `PhoenixKitWebAnalyticsReplay` hook in the client script.
- `traffic_flags.ex` + `internal_traffic.ex` — the own-traffic bits
  (internal network, staff, staff network) and how a hit gets them: CIDRs
  from app config, staff roles from the scope (or a 5-minute per-user role
  cache), staff networks in ETS learnt from core's `session_created` and
  from staff requests in the plug, shared over `PubSub.Manager` when new.
- `alerts.ex` — the "Website activity" notification type; turns stored hits
  and core's `{:user_created, user}` broadcast into activity entries per
  recipient (core routes them to inbox / email / Telegram / digests).
- `profiles.ex` + `schemas/visitor_profile.ex` — what the `store_*` settings
  keep about a visitor, one row per visitor ID: written when a visit starts
  (after the hit's transaction), device measurements when the client script
  reports them, bot reasons as they are found. `forget/1`, `prune/0`.
- `signals.ex` — the trust boundary for device measurements (`clean/1`: an
  allow-list of keys, types and bounds) and the salted `device_hash/2`. The
  client script measures only when `GET …/recording` answers `signals: true`.
- `bot_score.ex` — pure: reasons, weights, levels, and which source owns
  which reason (`merge/3`).
- `consent.ex` — whether each kind of collection (`:measurement`,
  `:profile`, `:device`, `:recording`) may happen for a visitor: the
  `web_analytics_consent_*` modes, the answer's source (Legal's signed
  cookie, or the host's `consent_source`), and the session note the hook
  reads. Every entry point puts `consent:` on its hit; the collector is the
  one place that acts on it (`consented/2`, `profile_allowed?/1`).
- `data_collection.ex` — what the module declares to Legal's banner and
  policy (`data_collection/0`, found by name), built from the settings.

**Read path**

- `reports.ex` — every aggregate the UI shows, including `sessions/2` and
  `session_timeline/1`. Queries degrade to empty results and log. Results go
  through `report_cache.ex` (single-flight, 30 s; cleared after a settings
  save and every retention pass).
- `rollup_reader.ex` + `dimensions.ex` — a period is read from the rollups
  for finished days and from raw events for the rest, in one `UNION ALL`;
  every breakdown is defined once in `Dimensions`, so the rollup and the raw
  remainder can't count differently.
- `session_stats.ex` — the per-session query shared by reports and rollup.
- `web/*_live.ex` — Overview, Right now, Sessions, a session, Pages,
  Acquisition, Technology, Events, Bots, Settings.
- `bots.ex` — the Bots page's queries over `visitor_profiles`: ranked
  visitors, groups by network / subnet / address / device / User-Agent.
  The page is links only (the whole filter is in the URL).
- `web/{components,filters,user_names}.ex` — shared UI.
- `admin.ex` — every operator mutation (settings, tracking switch, retention
  run, salt rotation), each logged to `PhoenixKit.Activity`.
- `retention.ex` — the hourly pass, one at a time across nodes (a session
  advisory lock): session-start backfill, the no-JavaScript bot judgement,
  recording prune, rollup into `daily_stats` + `daily_dims` (watermark
  `web_analytics_rolled_through`; a day is re-rolled for 3 hours after it
  ends), event prune (never past the watermark; fails closed).

## Rules that are load-bearing

- **Nothing that says who a visitor is gets stored unless a setting asks
  for it, and every such setting defaults to off.** An address, a raw
  User-Agent, request headers, the network's owner and device measurements
  each have their own `web_analytics_store_*` key; all of them go to
  `visitor_profiles` (one row per visitor ID, `Profiles`), never to an event
  row — the events schema has no column for any of them. A new kind of
  identifying data means a new setting, off by default, with a `forget/1`
  kind. What may be kept is the operator's decision (the module is meant to
  fit any law), so don't hard-code a privacy position in either direction.
- **Whether a visitor must be asked is the operator's rule, per kind of
  collection** (`web_analytics_consent_*`: `always` / `consent` /
  `unless_objected`; all default to `always`). A new entry point must put
  `consent: Consent.for_conn(conn, config)` (or `for_session/2`) on what it
  hands the collector — a hit without the key is taken as the host's own
  call and allowed. A new kind of data about a visitor belongs to one of the
  four purposes or gets a fifth, with its own key. A consent source that
  fails answers `:denied` — raise, throw, exit, a return that is not one of
  the three atoms, a malformed `consent_source` — and only a clean
  `:unknown` is unknown: `unless_objected` collects on unknown, so a failure
  must not read as one. `Consent.status/2` runs in `Plug.call/2` itself, so
  it catches everything. Nothing is queued for a later yes.
- **A LiveView session without the plug's note is objected-and-unanswered**
  (`Consent.noted/1` → `{:unknown, true}`), and notes decode by exact match.
  The note is therefore load-bearing: written for every visitor while a rule
  waits for an answer, and declared in `DataCollection` (`storage`). The DNT
  note beside it is deleted by the plug when the signal stops.
- **A view counted without a visitor carries nothing that singles one out**
  (`Collector.anonymous/1`): no user, roles, headers, session anchor or
  click identifier, country only, `metadata["anon"]`, no `"lv"` (so it is
  never judged no-JS), no profile, no new-visitor alert. A new identifying
  hit key must be dropped there.
- **`track_event/2` / `track_pageview/1` take `conn:`** and then follow the
  visitor's answer; without it (and without `:consent`) the hit is the
  host's own call.
- **A per-visitor rate limit is not a limit**: the visitor ID includes the
  User-Agent. Anything a public endpoint counts per visitor is also counted
  per address (`:signals_address`, `:recording_address`).
- **What is declared follows what is collected.** A new `store_*` setting or
  kind of data gets a line in `DataCollection.entries/0`, active only while
  it is on.
- **Never kept whatever the settings:** a query string (in a path, a
  referrer or a stored `Referer` header — campaign parameters get their own
  columns first), and the value of a credential header (`Profiles`'
  `@secret_headers` / `@secret_words`).
- **An operator's own addresses aren't a setting.** `internal_networks` is
  app config and staff networks (`InternalTraffic`) live in ETS only; what
  reaches a row is the `traffic_flags` bits. Every settings write is a
  permanent activity entry.
- **A bot score is evidence, never a verdict.** `BotScore` reasons and
  their sum live on the profile and are only shown (the Bots page, a visit's
  page). Nothing drops, flags `is_bot` or blocks because of a score. A new
  reason is one observable fact with a weight, owned by exactly one source
  (`:request`, `:signals`, `:behaviour`) — a test enforces that.
- **A profile write must never cost the event.** `Profiles` calls run after
  the hit's transaction or off its process (`Collector.note_reason/3`), and
  rescue everything.
- **Reasons are rescored under a row lock, from what the row holds.**
  `Profiles.rescore/3` is `SELECT … FOR UPDATE` + write in one transaction
  (two sources report within a second of each other), and `:request`
  reasons come from the stored headers / hosting, not the incoming hit — a
  visit can start on a hit with no headers. `forget/1` takes back the
  reasons read from what it blanks (`BotScore.derived_from/1`); a new
  reason read from stored data goes in that list.
- **Own traffic is marked, not dropped.** `traffic_flags` (bits in
  `TrafficFlags`) is worked out before the collector's transaction from
  memory only; a bit new to a visit is written back to the visit's rows in
  that transaction. Rollups hold only `traffic_flags = 0` and `not is_bot`;
  a report filter carries its `excluded_flags` mask, and any mask other than
  "every bit" (or `flagged: true`) reads raw.
- **A speculative prefetch is a bot, never the visitor.** `bot: "prefetch"`
  forces `is_bot`, ignores `track_bots?`, and hashes the visitor on its own
  input, so Chrome's prerender from a person's own browser neither starts nor
  joins their visit. The person's click is recovered from the LiveView
  connect (`prefetch_connect`, which also counts as JavaScript evidence in
  `BotSignals`'s `@js_sources`). A new source reported only by JavaScript goes
  in that list.
- **`visitors` counts daily unique visitors, added across the period.**
  Every aggregate raw read counts `distinct (visitor_id, inserted_at::date)`
  in UTC, matching the rollups' per-day distinct counts under every visitor
  rotation. This includes exit visitors and monthly trend buckets. The
  "right now" figure is distinct IDs within its short time window instead.
  Visit totals, bounces and session seconds also use daily visit portions
  (`SessionStats`), so a session spanning midnight has the same aggregates
  raw or rolled up. The visit list and timeline still show the full visit.
- **Never store form contents.** An interaction keeps its event name and only
  the short values of allow-listed params (`web_analytics_event_params`);
  `phx-change` (recognised by `_target`) isn't recorded at all.
- **Nothing in the tracking path may raise.** The plug's `before_send` callback,
  the collector, `Config.collection_config/0`, and every `Reports` query rescue
  and degrade. A broken analytics read costs a missing row, never a failed page.
- **`enabled?/0` must answer `false` when it can't tell.** Boot ordering and a
  stopped test sandbox both hit this.
- **Charts are core's SVG components** (`bar_chart` etc.). Do not add a
  charting library, here or to the host.
- **Client JavaScript ships through `js_sources/0`**, never an inline
  `<script>` (the legacy `<.beacon />` component is the one exception, kept
  for hosts already using it).
- **A hit reported after its page (a leave) carries `session_anchor`**, so it
  joins the session its page view started.
- **Alert text never includes an email address or visitor input.**

## Migrations

Module-owned and versioned, following `PhoenixKitBoards.Migrations`:
`lib/phoenix_kit_web_analytics/migrations.ex` implements `current_version/0`,
`migrated_version_runtime/1`, `up/1`, `down/1`, tracks the installed version in
a `COMMENT ON TABLE` on `phoenix_kit_web_analytics_events`, and is returned from
`migration_module/0`. `mix phoenix_kit.update` in the host generates the
migration that calls it.

Versions: V01 tables; V02 `engaged_ms`, `scroll_depth`, `target` +
`(session_id, inserted_at)` index; V03 `session_start` (backfilled in batches by
the retention pass, never in the migration); V04 rollup columns + `daily_dims`;
V05 `(path, inserted_at)` and `(user_uuid, inserted_at)` indexes; V06
`recordings`; V07 `click_id`, `click_param` + their partial indexes; V08
`traffic_flags smallint NOT NULL DEFAULT 0` (no index, no backfill); V09
`visitor_profiles`; V10 `bot_score` + `bot_reasons` on it. Adding a
version means: bump `@current_version`, add `up_vN/1` + `down_vN/1`, add the
`apply_step/3` clauses, and keep every statement prefix-safe (pass `prefix:`
through, bare index names, schema-anchored existence checks).

**Never put a full-table `UPDATE` or a long backfill in a migration step** —
the host's migration runs in one transaction holding its locks. Backfill in
batches from the retention pass instead, as V03 does.

**Never write a setting on a schedule.** Every core setting write is a
permanent `setting.changed` activity entry; an hourly watermark would add 24 a
day forever. Prefer stateless, idempotent passes (see
`BotSignals.judge_no_js/2`).

`test/support/test_migration.ex` is the checked-in equivalent of the generated
host migration, so the suite runs against exactly the DDL an install gets.

## Settings

All keys are `web_analytics_*` and live in the host's `phoenix_kit_settings`.
Collection keys belong to `config.ex`, alert keys to `alerts.ex` — add new
ones there, not inline. `collection_config/0` is on the hot path and reads
through the settings cache in one multi-get. Writes go through `Admin`.

## Translations

Every string goes through `PhoenixKitWebAnalytics.Gettext` (LiveViews do
`use Gettext, backend: PhoenixKitWebAnalytics.Gettext` after
`use PhoenixKitWeb, :live_view`, which repoints `gettext/1` at this module's
catalogue; tabs set `gettext_backend:`). After changing strings run
`mix gettext.extract --merge --no-fuzzy` and fill en/et/ru/uk — none may stay
empty.

## Common Commands

```bash
mix deps.get
mix test                    # unit tests always; integration tests need PostgreSQL
mix test.setup              # createdb (integration tests auto-exclude without it)
mix format
mix credo --strict
mix dialyzer
mix precommit               # compile --warnings-as-errors + deps.unlock --check-unused + hex.audit + quality.ci
```

### Local cross-repo development

`phoenix_kit` resolves from Hex by default. To build against a local checkout:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

The variable is the dep's app name upper-cased with `_PATH`. Unset = the
published pin, so `mix hex.publish` and CI resolve exactly as before. Never
hand-edit a `phoenix_kit*` dep into a `path:` tuple — a committed path dep ships
a broken package.

## Testing

`test/test_helper.exs` runs core's versioned migrations, then this module's, and
excludes `:integration` when PostgreSQL isn't reachable.

- `PhoenixKitWebAnalytics.DataCase` — sandbox + settings-cache reset +
  `insert_event/1`, `enable_tracking/1`, `days_ago/1`, `hours_ago/1`, and
  `ActivityLogAssertions`
- `PhoenixKitWebAnalytics.LiveCase` — the test endpoint/router for LiveView and
  controller tests
- `PhoenixKitWebAnalytics.Test.TrackedLive` at `/shop` — a host page mounted
  with the LiveView hook (give the conn `put_connect_info` for
  `:peer_data`/`:user_agent`)

**The settings cache lives outside the sandbox transaction.** Both cases clear
it in `setup`; a test that writes a setting must `clear_settings_cache/0` before
reading it back, or it will see the stale value.

**Hits are written inline in tests** (`config :phoenix_kit_web_analytics,
async_tracking: false` in `config/test.exs`), so a plug request, a beacon POST
or a LiveView click can be asserted on in the database directly.
`LivePresence`, `Alerts`, `ReportCache`, `BotSignals` and `InternalTraffic`
aren't started by the test helper — use `start_supervised!/1` where a test
needs them. `config/test.exs` also turns the report cache off
(`report_cache_ms: 0`), and the presence reconnect grace and supersede
windows to 0; tests of those set them explicitly. `LiveCase.fake_scope/1`
builds a scope core's own role checks read (`roles:` / `held_roles:` as
`:owner`-style keys or names).

**`mix.lock` reflects the Hex pin.** Running `mix deps.get` with
`PHOENIX_KIT_PATH` set can rewrite it for local core's transitive deps — don't
commit that.

## Critical Conventions

- **Module key**: `"web_analytics"` — consistent across every callback
- **Tab IDs**: prefixed `:admin_web_analytics`
- **URL paths**: hyphens, not underscores (`web-analytics`)
- **Navigation**: always `PhoenixKitWebAnalytics.Paths`, never a hardcoded path
- **Schemas**: `@primary_key {:uuid, UUIDv7, autogenerate: true}` +
  `use PhoenixKit.SchemaPrefix` (guarded by
  `test/schema_prefix_conformance_test.exs`)
- **Routes**: declared in `routes.ex` (both localized and non-localized, unique
  `:as` names). Never hand-register these in a host router — PhoenixKit injects
  them into its own `live_session :phoenix_kit_admin`.
- The collection endpoints pipe through `:phoenix_kit_api`, not `:browser` —
  `sendBeacon` cannot carry a CSRF token.

## Versioning & Releases

Version lives in **three** places: `mix.exs` (`@version`),
`lib/phoenix_kit_web_analytics.ex` (`@version` / `version/0`), and the version
test in `test/phoenix_kit_web_analytics_test.exs`.

1. Update all three
2. Add a `CHANGELOG.md` entry
3. `mix precommit` — zero warnings/errors
4. Commit: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. `git tag vx.y.z && git push origin vx.y.z` (`v`-prefixed; bare tags in the
   history predate the switch)
7. `gh release create vx.y.z --title "vx.y.z - YYYY-MM-DD" --notes "…"`

Never tag before everything is committed and pushed — tags are immutable
pointers.

### Commit Message Rules

Start with an action verb: `Add`, `Update`, `Fix`, `Remove`, `Merge`. **Do not
include AI attribution or `Co-Authored-By` footers.**

## Pull Requests

Review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/`, named
`{AGENT}_REVIEW.md`. Severity levels: `BUG - CRITICAL`, `BUG - HIGH`,
`BUG - MEDIUM`, `IMPROVEMENT - HIGH`, `IMPROVEMENT - MEDIUM`, `NITPICK`.
