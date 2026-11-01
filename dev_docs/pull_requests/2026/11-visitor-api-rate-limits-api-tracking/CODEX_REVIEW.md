# PR #11 — Visitor API, address check, rate limits and API tracking

Author: mdon. Merged 2026-11-01 as `94ca492`.
Reviewed 2026-11-01 against `51ef04e`, including the fixes already folded into
the PR. The existing Claude review is unchanged.

Reviewed the request visitor recipe and memoization, ring and address samples,
rate-limit registration and counters, exemptions and refusal callbacks, API
collection and report isolation, settings, declarations, routes and UI.
Phoenix, OTP and Ecto thinking skills were read before source review.

## BUG - HIGH — header storage kept the rate-limit bypass credential (fixed)

The new default credential header, `x-rate-limit-bypass`, matched neither
`Profiles.@secret_headers` nor `@secret_words`. With header storage enabled,
an ordinary tracked page could therefore persist the shared bypass token in
`visitor_profiles.headers`. A configured header such as `x-operator-pass`
had the same problem. Reading a stored token would allow bypassing limits and
the network blocklist.

The default header is now explicitly secret, and the configured bypass header
is also excluded regardless of its name. Header names remain visible, while
their values are removed from both request captures and host-provided header
maps. Regressions failed against the original implementation for both default
and custom headers; the custom case also checks the direct capture boundary.

This prevents new captures. Existing profiles are not rewritten: an affected
operator can use Settings' existing forget-headers action and replace the
bypass token. No migration or automatic deletion of stored profiles was added.

## BUG - MEDIUM — callback throws escaped, and callback exits could bypass a denial (fixed)

`host_deny/4` rescued exceptions only. A throw escaped both it and the plug;
an exit reached the plug's outer fail-open handler, returning the original
connection after the limit had already refused the request. Direct calls to
`deny/3` also let these failures escape. The exemption callback had the same
uncaught-throw problem at the plug boundary.

The refusal callback now handles throws and exits locally and sends the
built-in halted 429. The public charge/check and plug boundaries catch throws
alongside exits and preserve their documented fail-open behavior. Tests cover
raising, throwing, exiting and silent refusal callbacks, and a throwing
exemption callback. The throw cases failed against the original code.

## BUG - MEDIUM — non-GET API requests ignored speculative headers (fixed)

The GET tracking path read `Tracking.prefetch_reason/1`, but
`maybe_register_api/2` passed `nil` for every other method. HEAD and POST
requests carrying speculative headers were consequently stored even though
the API collection contract excludes prefetches.

Both registration paths now pass the same classification. The regression
sends GET, HEAD and POST requests with `Sec-Purpose: prefetch;prerender` and
asserts that none becomes an API row; it failed against the original code.

## Verified

- The visitor API uses the collector's salt, rotation, client address and
  prefetch input, and never creates a salt.
- API rows have separate session IDs and no session start, profile or alert;
  stitching, backfill, presence and visitor/visit reports exclude them.
- API collection is bounded by both visitor and network, independent of
  User-Agent changes. Aggregate API visitor counts use daily uniqueness.
- Limits use atomic Hammer increments, with a network bucket alongside the
  visitor bucket. Rule registration retains the PR's node-local lock.
- Internal and blocked networks use separate parsed caches, and their
  settings retain secret names. Refusal paths use token redaction.
- No schema, version, release, translatable UI string or client storage change
  was needed.

## Validation

Six regression tests failed before their respective fixes: four in the
LiveView/API/rate-limit tests and two in profile header tests. The original
focused test run had 95 tests, 4 failures; after the first fixes it passed.

`PGHOST=127.0.0.1 PGUSER=postgres mix test`: **1,004 tests and 29 doctests,
zero failures**, integration tests enabled.

`mix precommit`: **passed** — compilation with warnings as errors, unused
dependency check, Hex audit, formatting, strict Credo and Dialyzer. Dialyzer
reported only the four existing ignored warnings, with no unnecessary skips.

The shared PostgreSQL service rejected connections in recovery, so integration
tests use a separate temporary PostgreSQL 18 instance on localhost, with
`PGHOST=127.0.0.1 PGUSER=postgres`. No repository configuration was changed.
