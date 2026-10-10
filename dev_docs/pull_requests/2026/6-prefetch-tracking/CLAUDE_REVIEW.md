# PR #6 — Chrome speculative prefetch: phantom visits and lost clicks (0.6.1)

Author: timujinne · Merged: baeb054, 2026-10-10 · 15 files, +719 / −137

A request Chrome marks `Sec-Purpose: prefetch…` / `Purpose: prefetch` is stored as a bot
(`bot: "prefetch"` through the plug and collector), hashed as its own visitor so it never
starts or joins the person's visit, and kept out of the page-view speed counter. The
person's later click, which Chrome serves from its prefetch cache with no request, is
recovered from the first LiveView connect when the host sends `nav_delivery` /
`prerendered` / `prerendering` / `doc_referrer` connect params (`"prefetch_connect"`). The
client script holds its reports and recordings of a prerendered page until
`prerenderingchange`. Two review rounds were already folded into the PR (`5921acc`,
`7d6f393`), so this was a fresh pass over the merged result: `plug.ex`, `collector.ex`,
`live_hook.ex`, `bot_signals.ex`, the client script, the visit page's reason labels, the
gettext catalogues and the README.

Baseline: `mix test` — 15 doctests, 665 tests, 0 failures.

## Findings

### NITPICK — the client script's header comment was reflowed into one overlong line (fixed)

The PR's added sentence ended mid-paragraph with `Visitors sending Do Not Track or Global
Privacy Control` running past 130 columns. Reflowed; no code change.

### IMPROVEMENT - MEDIUM — the load-bearing rules didn't mention the prefetch path (fixed)

`AGENTS.md` describes the plug, the hook and the collector, and the rules the next change
has to respect. The PR adds a forced-bot path that deliberately ignores `track_bots?`, a
second source of page views in the hook, and a new entry in `BotSignals`'s `@js_sources`
(a source missing from that list is how a JavaScript visit gets judged a "no JavaScript"
bot). None of it was written down. Added the plug/hook lines and one rule.

## Noted, not changed

- **Possible double count when Chrome revalidates a prefetched LiveView page.** The hook
  counts a first connect with `nav_delivery == "navigational-prefetch"` on the assumption
  that no plug request fired. LiveView pages are usually sent `cache-control: max-age=0,
  private, must-revalidate`; if Chrome ever revalidated such a prefetched response with a
  conditional request that lacks `Sec-Purpose`, the plug would count the view and the
  connect would count it again. This needs a real Chrome to confirm and the PR author
  tested the delivery path, so no guard was added (one would have to dedupe against the
  visitor's recent page view of the same path, which is its own source of lost views).
- **Safari's legacy `Purpose: prefetch`** is treated like Chrome's, but Safari doesn't run
  the host's connect-param snippet, so a Safari visitor whose click is served from such a
  prefetch isn't counted. Safari only does this for its own previews; left as is.
- **A controller-rendered page served from the prefetch cache is not counted.** Already
  documented in the README and `LiveHook`.
- **The connect params are client-supplied.** A visitor can forge `nav_delivery` and get
  one extra page view of the page they are on. That is the same trust level as
  `_live_referer`, which the hook already honours, and the referrer still goes through the
  collector's query-string stripping and truncation.

## Verified, no change needed

- **The "no JavaScript" judgement can't relabel a prefetch.** `judge_batches` selects
  visit starts with `not s.is_bot`, and `clear_no_js` only touches `"no_js"` rows, so a
  prefetch keeps its reason.
- **A recovered visit isn't judged a bot for lacking JavaScript.** `prefetch_connect` is
  in `@js_sources`; the pageview it records has no `lv: true`, so it isn't a "hooked" page
  view either.
- **`prefetch_param?/1` clause order.** `prerendering: true` returns `false` before the
  other clauses; `prerendering: false` / `"false"` fails the guard and falls through to the
  delivery clauses, as intended. `_mounts == 0` keeps a reconnect from counting twice.
- **A live navigation carrying prefetch params is one page view** (the `cond` takes
  `live_navigation?` first); covered by a test.
- **Forced-bot visitor hashing.** `hashed_agent/1` keeps the hash the same length and salt;
  `user_uuid` no longer collapses a forced-bot hit into `"user:…"`; `speed/3` skips it.
- **No new raise path** in the plug's `before_send` (two header reads and a string match),
  and the collector change is inside the existing transaction.
- **Translations.** The new visit-page reason is filled in en/et/ru; no empty `msgstr`.
- **Client script.** `whenShown/1` queues only while `document.prerendering`; a prerendered
  page nobody opens sends nothing; after activation the queue flushes once.
