# AGENTS.md

This file provides guidance to AI agents working with code in this repository.

## Project Overview

Privacy-first, cookieless web analytics as a PhoenixKit plugin module. The whole
premise is that installing analytics must not change what a host's pages cost to
load: tracking is a **plug**, not a script tag. Before changing anything in the
collection path, check the change against that premise — if it adds bytes to a
rendered page, adds a client-side request, or writes a cookie, it doesn't belong
here.

## Architecture

Two halves, deliberately independent:

**Write path** (must never slow down or break a host request)

- `lib/phoenix_kit_web_analytics/plug.ex` — the tracker. In the request process
  it does a method/path check, one cached settings read, and
  `register_before_send/2`. Everything else is deferred.
- `lib/phoenix_kit_web_analytics/collector.ex` — enrichment + insert, run in a
  `Task.Supervisor` with a `max_children` cap (drops, never queues). Owns
  session stitching and path/query normalization.
- `lib/phoenix_kit_web_analytics/{visitor,user_agent,referrer,geo}.ex` — pure
  classification helpers, no database, no dependencies.
- `lib/phoenix_kit_web_analytics/live_hook.ex` — LiveView navigation.
- `lib/phoenix_kit_web_analytics/web/{track_controller,beacon_payload,beacon}.ex`
  — the optional public beacon/pixel. `BeaconPayload` is the trust boundary and
  is where any change to what a client may influence belongs.

**Read path**

- `lib/phoenix_kit_web_analytics/reports.ex` — every aggregate the UI shows.
  All queries degrade to empty results rather than raising.
- `lib/phoenix_kit_web_analytics/web/*_live.ex` — six admin pages.
- `lib/phoenix_kit_web_analytics/web/{components,filters}.ex` — shared UI.
- `lib/phoenix_kit_web_analytics/retention.ex` — hourly rollup + prune.

## Rules that are load-bearing

- **Never store an IP address, a raw User-Agent, or a query string.** The
  schema has no column for the first two, and `Collector.normalize_path/1`
  strips the third. Campaign parameters get their own columns before that point.
- **Nothing in the tracking path may raise.** The plug's `before_send` callback,
  the collector, `Config.collection_config/0`, and every `Reports` query rescue
  and degrade. A broken analytics read costs a missing row, never a failed page.
- **`enabled?/0` must answer `false` when it can't tell.** Boot ordering and a
  stopped test sandbox both hit this.
- **The charts are CSS.** Do not add a charting library, here or to the host.
- **Interpolation inside `<script>` goes through `data-` attributes.** HEEx
  doesn't interpolate script bodies; `Web.Beacon` reads its configuration off
  `document.currentScript` for exactly this reason (and it keeps the script body
  a static string a strict CSP can hash).

## Migrations

Module-owned and versioned, following `PhoenixKitBoards.Migrations`:
`lib/phoenix_kit_web_analytics/migrations.ex` implements `current_version/0`,
`migrated_version_runtime/1`, `up/1`, `down/1`, tracks the installed version in
a `COMMENT ON TABLE` on `phoenix_kit_web_analytics_events`, and is returned from
`migration_module/0`. `mix phoenix_kit.update` in the host generates the
migration that calls it.

Adding a version means: bump `@current_version`, add `up_vN/1` + `down_vN/1`,
add the `apply_step/3` clauses, and keep every statement prefix-safe (pass
`prefix:` through, bare index names, schema-anchored existence checks).

`test/support/test_migration.ex` is the checked-in equivalent of the generated
host migration, so the suite runs against exactly the DDL an install gets.

## Settings

All keys are `web_analytics_*` and live in the host's `phoenix_kit_settings`.
`lib/phoenix_kit_web_analytics/config.ex` is the only module that knows their
names and defaults — add new ones there, not inline. `collection_config/0` is on
the hot path and reads through the settings cache in one multi-get.

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
  `insert_event/1`, `enable_tracking/1`, `days_ago/1`, `hours_ago/1`
- `PhoenixKitWebAnalytics.LiveCase` — the test endpoint/router for LiveView and
  controller tests

**The settings cache lives outside the sandbox transaction.** Both cases clear
it in `setup`; a test that writes a setting must `clear_settings_cache/0` before
reading it back, or it will see the stale value.

**Async writes can't see the sandbox connection.** Test storage through
`Collector.track/1` (synchronous), not `track_async/1` or an HTTP request to the
beacon endpoint.

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
