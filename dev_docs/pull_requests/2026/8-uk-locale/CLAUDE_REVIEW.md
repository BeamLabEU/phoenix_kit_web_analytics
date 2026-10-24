# PR #8 — Add Ukrainian (uk) translations

Author: timujinne · Merged: ca4f81c, 2026-10-23 · 5 files, +2668 / −4

Adds `priv/gettext/uk/LC_MESSAGES/default.po` (the full catalogue), names uk in the
README, AGENTS.md and the Gettext moduledoc, and adds `gettext_test.exs`: every shipped
locale is known to the backend, and Ukrainian's three plural forms resolve as its
`Plural-Forms` header says (1/2/5/11/21/22/111).

## How it was checked

Every catalogue was parsed with Expo and checked by machine rather than by eye:

- every catalogue against `default.pot`: none missing and none extra, in all four locales
- no empty `msgstr` (singular or any plural index), no `fuzzy` flag
- no placeholder drift: a translation never introduces a `%{name}` its msgid lacks,
  and a singular keeps exactly the msgid's set
- uk's `Plural-Forms` is the same three-form rule ru uses

All passed, both on the PR's merge and again after PRs #9 and #10 re-extracted the
catalogues.

## Findings

None. The test the PR adds is the right shape: it checks the plural rule with real
numbers instead of asserting that the header string exists.

## Fixes

None needed.
