# PR #11 — Visitor API, address check, rate limits, API-request tracking

Pre-PR review of the seven feature commits: a quality-sweep pass plus an
external panel (codex, grok, zai), each seat given its own area and a shared
list of open questions. Every finding below was checked against the code
before it was fixed; each fix has a test that fails without it.

## Findings

### BUG - HIGH — `Host: localhost` skipped every rate limit behind a local proxy (fixed)

`local_request?/1` exempted a loopback peer whose `Host` was a local name.
Behind a proxy on the same machine the peer is always loopback and `Host`
is the client's to choose — or `127.0.0.1` from a default `proxy_pass`.
Raised by all three seats. Now the resolved client address must be
loopback too; a proxy's appended `X-Forwarded-For` never is.

### BUG - HIGH — concurrent first requests lost registered rules (fixed)

`ensure_registered/1` read, modified and wrote one persistent term without
a lock; codex reproduced 1 of 32 simultaneous registrations surviving, after
which `charge/3` answered `:ok` for the lost rules. Now under a node-local
`:global.trans`.

### BUG - MEDIUM — blocklist telemetry carried one-time tokens (fixed)

The `:block` event sent `conn.request_path` raw while `:deny` used
`clean_path/1`. zai and codex.

### BUG - MEDIUM — API rows still reached three visit-shaped reads (fixed)

The session-start backfill marked them as starts (codex, grok, zai), the
Bots page's `latest_sessions/1` linked a visitor to an API request's session
(codex, grok), and `LiveHook` tracked a live navigation to an API path as a
page view and listed it under Right now (grok).

### BUG - MEDIUM — `log_only` stopped at the first rule over its limit (fixed)

A tight rule hid every rule after it, defeating the mode's purpose. codex.

### BUG - MEDIUM — staff loaded after the plug were limited by `charge/3` (fixed)

The plug's "not exempt" verdict, reached before authentication, was reused
as-is. Staff are now looked for again. codex.

### BUG - MEDIUM — `deny/3` could raise or leave a request unanswered (fixed)

An `on_deny` that raised, or returned a conn with no response, escaped or
left the request unanswered; an already-sent conn raised. codex.

### IMPROVEMENT - MEDIUM — same rule name in two plugs (warned)

Each plug enforces its own rules but `charge/3` finds a rule by name. A
differing redefinition is now logged at registration. codex, grok, zai.

### IMPROVEMENT — the address-check hash was reversible (fixed)

Unkeyed `phash2` of an IPv4 address can be reversed by trying them all;
now keyed with a per-node secret. zai.

### NITPICK — docs (fixed)

A localhost-only site reads as one *internal* address, not one public one;
`RequestVisitor` names the two hits stored under another ID (anonymous
no-consent page views, a write that runs past midnight UTC). The two new
admin strings that named the kit were reworded; Refresh got
`phx-disable-with`.

## Noted, not changed

- **An earlier rule stays charged when a later one refuses** (grok, codex):
  sequential attempt counting, the way core's own limiter charges; rolling
  back Hammer increments would need a second write per rule.
- **A reload that changes a plug's rules back keeps the newer registration**
  (codex): the marker is the rules' hash; only a code reload in development
  reaches it.
- **`Accept: application/json;q=1,text/html;q=0` gets HTML** (codex): no
  q-value parsing; `format: :json` on the plug forces it.
- **Token redaction covers core's routes only** (codex): a host-defined
  sensitive path needs a hook — its own change.
- **The API-row cap fails open while `BotSignals` restarts** (grok): it is
  a supervised child; the window is a restart.
- **A staff member on a blocked network is refused** (grok, zai): the
  blocklist is the operator's explicit decision and outranks exemptions;
  the bypass token is the way through.

## Gate

`mix precommit` clean (dialyzer: the same 4 ignored warnings as before);
1001 tests + 29 doctests. One existing retention test needs a second
database connection and fails when the local Postgres is at its connection
limit (other suites held 93–99 of 100 while this ran); it passed in a
full run with the retention change in place.
