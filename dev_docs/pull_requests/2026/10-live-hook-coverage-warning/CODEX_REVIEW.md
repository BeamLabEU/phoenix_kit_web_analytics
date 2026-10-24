# PR #10 — Hook coverage warning: independent recheck

Reviewed 2026-10-24. PR author: timujinne. Merge: `aa9a89f`.
Scope includes Claude's locale-exclusion changes and review in `60ec4d0`.

## BUG - MEDIUM — non-locale parameters can hide an unhooked session (fixed)

`unparameterized/1` removed any leading parameter. Thus `/:slug/admin/orders`
became `/admin/orders` and disappeared under the default `/admin*` exclusion,
even though `/customer/admin/orders` is tracked. Excluding `/` also concealed
`/:slug`, so an entire unhooked live_session could disappear from the warning.

Claude documented this as a harmless count approximation. It also changes
whether the session is reported at all, leaving the operator unaware that live
navigation, interactions and exits are missing from those tracked pages.

Fix: only `/:locale` is removed for deduplicating localized route twins.
Other parameters remain part of the page path.

## BUG - MEDIUM — the locale follow-up strips two segments in coverage (fixed)

Coverage first stripped `/:locale`, then passed the result to the newly
locale-aware `Config.excluded?/2`. For `/:locale/faq/admin`, the two steps
removed both `:locale` and `faq`, hiding the route under `/admin*`. Tracking
`/et/faq/admin` strips only `et`, so the page remains tracked. The follow-up
therefore left another disagreement between coverage and collection.

Fix: check the original route template through `Config.excluded?/2` before
deduplicating it. The shared matcher now understands the leading `/:locale`
template as well as concrete locale segments, and still removes at most one.
There is no separate exclusion rule in coverage.

Regression fixtures cover `/:slug/admin/orders`, `/:slug`, and a localized
`/faq/admin` page. All new coverage assertions failed on `60ec4d0` and pass
with the fixes; existing hooked/localized/admin expectations still pass.

## Other checks and limitations

- Claude's original `/et/admin` tracking fix is valid and remains in place.
  Plug, hook, beacon and recording exclusions share the matcher.
- The deliberately documented locale-shape approximation remains: `/faq/admin`
  matches `/admin*` because `faq` is locale-shaped. `/et/faq/admin` does not.
  The user-provided repository guidance explicitly requires this shared rule.
- Core prepends `extra_live_session_on_mount` to its sessions. The hook reads
  user and roles in `handle_params`/`handle_event`, after mount hooks run, so
  that ordering preserves attribution. Hook registration is read from the
  same session metadata by coverage and the plug.
- Coverage is a static route check. It cannot establish that every mount
  connects successfully, or see plug-local `:exclude` options. Existing docs
  describe those limits; connect-info skips have their own warning.

## Validation

- Baseline: `mix test` — 27 doctests, 929 tests, zero failures, integration enabled.
- New regression assertions reproduced both omissions before the fixes.
- Targeted tests after fixes: 3 doctests, 95 tests, zero failures.
- Final: `mix test` — 27 doctests, 932 tests, zero failures, integration enabled.
- `mix precommit` passes, including compile, lock checks, Hex audit, formatting,
  Credo and Dialyzer (the same four existing Dialyzer suppressions as baseline).
