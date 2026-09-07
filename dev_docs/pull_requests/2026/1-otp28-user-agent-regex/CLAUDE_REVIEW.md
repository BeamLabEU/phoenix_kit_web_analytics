# PR #1 — Compile UserAgent on OTP 28: regex lists as functions, not attributes

Author: timujinne (Tymofii Shapovalov) · Merged: f3e1046 (2026-09-07)

## Summary

`@browsers` / `@operating_systems` in `UserAgent` held `{name, ~r//}` tuples as
module attributes. On OTP 28, a compiled `Regex` literal carries an internal
reference; the compiler rewrites a *bare* regex attribute into a runtime
`Regex.compile!/2` call, but a regex nested inside a list attribute is escaped
as the raw struct, and injecting that into `parse/1`'s body fails with
`cannot escape #Reference<...>`. The fix turns the two lists into private
zero-arg functions, built at call time instead of injected as attributes.

## Verification

The PR's diagnosis was verified by direct reproduction rather than taken on
faith, since the failure is version-sensitive and did not reproduce on this
box's default toolchain:

- Installed Elixir 1.18.4-otp-28 (matching the PR's stated environment)
  alongside the default 1.19.5-otp-28.
- A minimal repro (`@attr` holding `{name, ~r//}` tuples, read inside a
  function) reproduces `cannot escape #Reference<...>` on 1.18.4 and compiles
  fine on 1.19.5 — explaining why the bug is real but version-dependent.
- The merged fix (private functions returning the same literal lists) compiles
  clean under both `1.18.4-otp-28` and `1.19.5-otp-28`, including
  `mix compile --warnings-as-errors`.
- `mix.exs` requires `elixir: "~> 1.18"`, so 1.18.4 is a supported target —
  0.2.0–0.2.2 do not build there at all. This fix is correctly scoped as a
  patch release.

No correctness issue with the change itself: `browsers/0` and
`operating_systems/0` return the exact same literal lists as before, in the
same order, and `match_first/2`'s call sites are unchanged.

## Findings

### BUG - HIGH: `pages_live.ex` crashes once a period has ≥100 paths (pre-existing, unrelated to this PR — fixed)

`lib/phoenix_kit_web_analytics/web/pages_live.ex:86-87` referenced
`@page_limit` *inside* the `~H` template. In HEEx, every `@name` is an assigns
lookup (`Map.get(assigns, :name)`), never a module attribute — `@page_limit`
there tries to read an assign that was never set (only used in plain Elixir
code via the real module attribute in `load/1`). Any period with 100+ ranked
paths hits `<p :if={length(@paths) >= @page_limit} ...>` and raises
`KeyError: key :page_limit not found`, crashing the LiveView.

Introduced 2026-07-27 (`6996546a`), long before this PR — surfaced here only
because validating the release pulled in a full `mix test` run.

**Fix applied:** assign `:page_limit` in `mount/3` alongside `:page_title` so
the template's `@page_limit` resolves.

### BUG - MEDIUM: admin-page smoke test broken by an unrelated same-day commit (pre-existing, unrelated to this PR — fixed)

`ef36b6a` ("Remove duplicate page headings...", 2026-09-07) removed the
hand-rolled `<h1>` from each of the six admin LiveViews, reasoning that the
title is already shown by the host's breadcrumb bar via the `page_title`
assign. `test/support/test_layouts.ex` — the isolated test harness's layout —
never rendered that breadcrumb (or `page_title` anywhere), so
`ReportPagesTest."mounts and renders with no data at all"` started asserting
against text that no longer appears anywhere in the rendered output.

**Fix applied:**
- `test/support/test_layouts.ex`: root layout now renders
  `<.live_title>{assigns[:page_title]}</.live_title>` instead of a hardcoded
  `<title>Test</title>` — the standard idiomatic stand-in for "the page shows
  its title somewhere", matching what a real host layout does.
- `test/phoenix_kit_web_analytics/web/report_pages_test.exs`: the settings
  page's expected heading was the literal old `<h1>` text ("Web Analytics
  settings"), which was never actually derived from `page_title`
  ("Settings · Web Analytics") — updated to `"Settings"`, consistent with the
  other five pages' checks.

### BUG - MEDIUM: settings-save test asserts a value the cache can't see (pre-existing, unrelated to this PR — not fixed)

`ReportPagesTest."settings page saving updates the stored settings"` fails
deterministically (confirmed on the unmodified merge commit too, `--seed 0`):

```
assert PhoenixKitWebAnalytics.Config.session_timeout_minutes() == 45
left:  30   # falls back to @default_session_timeout
right: 45
```

`retention_days() == 90` (same test, one line above) passes. The difference:
`retention_days/0` reads through `Settings.get_integer_setting/2` (single-key
cache), while `session_timeout_minutes/0` goes through
`Config.collection_config/0` → `Settings.get_settings_cached/2` (batched
multi-get). `DataCase`'s own docs describe exactly this class of bug: the
settings cache lives outside the sandbox transaction, and a cache-miss
fill-query can't see a row this test just wrote — `enable_tracking/1` works
around it by explicitly priming `PhoenixKit.Cache.put/3` after clearing. The
save-test doesn't do that priming, and the two read paths apparently disagree
on whether they need it.

**Not fixed here** — root-causing the exact cache/sandbox interaction well
enough to fix it safely is its own task, and it's unrelated to this PR's
scope. `mix precommit` (this repo's actual release gate) does not run
`mix test` and passes clean; this is the one test failure left after the two
fixes above. Recommend a follow-up that either primes the cache the same way
`enable_tracking/1` does, or aligns `get_settings_cached/2`'s miss-fill with
`get_integer_setting/2`'s.

## Gate

- `mix format --check-formatted` — clean
- `mix precommit` (compile --warnings-as-errors, deps.unlock --check-unused,
  hex.audit, credo --strict, dialyzer) — clean, 0 warnings/errors
- `mix test` — 150 tests, 1 pre-existing failure (documented above,
  unrelated to this PR, not blocking)
- Compiled clean under both `elixir 1.18.4-otp-28` and `elixir 1.19.5-otp-28`
