# PR #13 review

Reviewed the bot reporting, V11 migration and retention pass, client reporting limit, endpoint plug, LiveViews, translations, and tests against the current upstream main. [Pull request #13](https://github.com/BeamLabEU/phoenix_kit_web_analytics/pull/13)

| Severity | Finding and fix |
| --- | --- |
| BUG - HIGH | The endpoint captured consent before the router could load the visitor's session or assigns. With `unless_objected`, an early unknown answer could count a request even though the pipeline subsequently read a refusal. The endpoint now evaluates consent on the prepared connection. A regression test sends a refusal through both copies of the plug. |
| BUG - HIGH | The bot-name heuristic accepted arbitrary identifying text, including two-label hostnames, for event storage. The classifier now emits canonical product names or fixed markers. The collector strips reserved atom and string keys. Both raw reporting and V11 backfill restrict legacy metadata before grouping, which also prevents a legacy rule from colliding with the total row. |
| BUG - HIGH | During the migration backfill, new views at one site could offset another site's missing views in the day-wide completeness check. The retention pass now compares each site's remaining events with its own saved totals before replacing that day's rollup. |
| BUG - HIGH | Drop diagnostics could log the original request path, including its query or a one-time credential embedded in the path. The logger now uses the same path redaction as event storage. |
| BUG - MEDIUM | The quiet hint could appear on a redirect, a non-HTML response, or a cacheable page with only a max-age directive. Only a successful HTML page view with explicit private or no-store cache control qualifies, with shared-cache overrides still checked. |
| IMPROVEMENT - MEDIUM | A profile-refresh test could span the daily visitor-ID rotation during early UTC hours. Its two visits now have explicit timestamps three hours apart on the same UTC day. |

The PostgreSQL-backed suite passed with 1,074 tests and 29 doctests. The shipped JavaScript also passed Node's syntax check.
