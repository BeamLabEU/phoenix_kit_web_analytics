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
- `live_hook.ex` — LiveView: page views for live navigation (`_live_referer` +
  `_mounts == 0`; a reconnect is not a view), interactions via an
  `attach_hook(:handle_event)`, and registration with `LivePresence`.
- `live_presence.ex` — monitors LiveView processes; ETS "who is on which page
  now"; records a `"leave"` with `engaged_ms` on DOWN or on a patch.
- `collector.ex` — enrichment + insert in a capped `Task.Supervisor` (drops,
  never queues). Session stitching runs with the insert in one transaction
  under an advisory lock on the visitor. Calls `Alerts.event_recorded/2`.
- `tracking.ex` — the helpers the plug, hook and beacon share (client IP rule,
  UTM params, current user, UTF-8-safe truncation).
- `{visitor,user_agent,referrer,geo}.ex` — pure classification helpers.
- `web/{track_controller,beacon_payload,beacon}.ex` — the public endpoint for
  the client script, beacon and pixel. `BeaconPayload` is the trust boundary.
- `priv/static/assets/phoenix_kit_web_analytics.js` — the client script.
- `alerts.ex` — the "Website activity" notification type; turns stored hits
  and core's `{:user_created, user}` broadcast into activity entries per
  recipient (core routes them to inbox / email / Telegram / digests).

**Read path**

- `reports.ex` — every aggregate the UI shows, including `sessions/2` and
  `session_timeline/1`. Queries degrade to empty results and log.
- `session_stats.ex` — the per-session query shared by reports and rollup.
- `web/*_live.ex` — Overview, Right now, Sessions, a session, Pages,
  Acquisition, Technology, Events, Settings.
- `web/{components,filters,user_names}.ex` — shared UI.
- `admin.ex` — every operator mutation (settings, tracking switch, retention
  run, salt rotation), each logged to `PhoenixKit.Activity`.
- `retention.ex` — hourly rollup (watermark `web_analytics_rolled_through`) +
  prune (never past the watermark; fails closed).

## Rules that are load-bearing

- **Never store an IP address, a raw User-Agent, or a query string** — in a
  path *or* a referrer. The schema has no column for the first two; the
  collector strips the third from both. Campaign parameters get their own
  columns before that point.
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
`(session_id, inserted_at)` index. Adding a version means: bump `@current_version`, add `up_vN/1` + `down_vN/1`,
add the `apply_step/3` clauses, and keep every statement prefix-safe (pass
`prefix:` through, bare index names, schema-anchored existence checks).

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
`mix gettext.extract --merge` and fill en/et/ru — none may stay empty.

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
`LivePresence` and `Alerts` aren't started by the test helper — use
`start_supervised!/1` where a test needs them.

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
6. `git tag x.y.z && git push origin x.y.z` (bare version, no `v` prefix)
7. `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "…"`

Never tag before everything is committed and pushed — tags are immutable
pointers.

### Commit Message Rules

Start with an action verb: `Add`, `Update`, `Fix`, `Remove`, `Merge`. **Do not
include AI attribution or `Co-Authored-By` footers.**

## Pull Requests

Review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/`, named
`{AGENT}_REVIEW.md`. Severity levels: `BUG - CRITICAL`, `BUG - HIGH`,
`BUG - MEDIUM`, `IMPROVEMENT - HIGH`, `IMPROVEMENT - MEDIUM`, `NITPICK`.
