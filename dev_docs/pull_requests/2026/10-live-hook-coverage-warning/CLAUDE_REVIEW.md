# PR #10 — Warn when tracked LiveView pages don't run LiveHook

Author: timujinne · Merged: aa9a89f, 2026-10-23 · 13 files, +1637 / −1245 (mostly gettext
reference churn)

`LiveHook.coverage/1` reads the router's live routes. It leaves out the paths the
`web_analytics_exclude_paths` setting excludes, folds `/:locale/x` into `/x`, and
counts the remaining pages per live_session by whether that session's `on_mount` lists
the hook. Settings and the dashboard show `live_hook_notice/1` with the unhooked
sessions and the ways to hook each kind (your own live_session, PhoenixKit's through
`config :phoenix_kit, extra_live_session_on_mount`, a library's own `on_mount:`, or
wrapping a bare `live` route). `LiveHook.runs_in?/1` replaces the plug's inline check.

Checked against core 2.64.0: `extra_live_session_on_mount` is real. It is read at router
compile time, prepended to **every** PhoenixKit live_session (`build_live_surface/5`,
maintenance, the legacy dashboard), and `__mix_recompile__?` picks up a change to it. So
the README's advice works as written.

## Findings

### BUG - MEDIUM — `coverage/1` and the collectors disagreed on what a localized path excludes (fixed)

`coverage/1` strips a leading parameter segment and treats `/:locale/admin/...` as
covered by `/admin*`. The PR's test asserts that too ("/:locale/admin/... is left out by
the default exclusions"). But every collector matches the *request* path,
`/et/admin/...`, against `/admin*` anchored at the start, and that never matched. So on
a multi-language install, PhoenixKit's admin in a non-default language was tracked: the
plug counted its page views, and the beacon and recordings checked the same bare path.

The PR made this worse with its own advice. Following the notice and adding the hook
through `extra_live_session_on_mount` puts it on `:phoenix_kit_admin` as well. The hook's
own check (`trackable_path?/1`) then let localized admin live navigation, clicks and
"Right now" presence through, while the warning said nothing about it because
`coverage/1` thought those pages were excluded.

Fix: `Config.excluded?/2` now also matches past a leading locale-shaped segment. That
is core's shape: 2–3 lowercase letters, optionally `-` and 2–4 letters, never core's
reserved `api`/`mcp`. One function serves the plug, the hook, the beacon, recordings,
alert path filters and `coverage/1`, so they agree. I put the fix in the matcher
rather than passing the `locale` path param, because the beacon and recordings only
ever see `location.pathname`. Trade-off on record: a host page whose first segment is
locale-shaped but isn't a locale (`/faq/admin`) is now also covered by `/admin*`. The
Settings help text, the README row, the Config docs and AGENTS.md say so.

Tests: `config_test.exs` (what counts as a locale segment, and what doesn't), plus
`plug_test.exs` (`/et/admin/settings` registers no callback).

### NITPICK — `coverage/1` folds any leading parameter, not only a locale (not changed)

`unparameterized/1` reads `/:slug/x` as `/x` as well. Its job is to merge the localized
and bare copies of each page PhoenixKit generates, and a host route that starts with a
non-locale parameter is rare. The worst outcome is a miscounted page in a warning, so I
left it as it is.

### NITPICK — `coverage/1` runs in `DashboardLive.mount/3`, so on both renders (not changed)

It makes no database query: it walks `Phoenix.Router.routes/1` and makes one cached
settings read. Computing it only when connected would make the warning flash in after
the first paint. Not worth it.

## Fixes

- `lib/phoenix_kit_web_analytics/config.ex` — `excluded?/2` reads past a locale segment
- Settings help text for Excluded paths (en/et/ru/uk filled), README settings row,
  AGENTS.md load-bearing rule
- Tests as above
