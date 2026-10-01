# PR #1 — Follow-up

Re-verified against current code on 2026-10-01, during the quality sweep.

## Fixed (pre-existing)

- ~~BUG - HIGH: `pages_live.ex` crashes once a period has ≥100 paths~~ —
  fixed inside the PR itself (`:page_limit` assigned in `mount/3`, still
  there at `pages_live.ex:30`). The page has since moved to `?page=N`
  paging, and `new_pages_test.exs` ("/pages pages past the first hundred
  paths") pins a period with more than 100 paths.
- ~~BUG - MEDIUM: admin-page smoke test broken by the heading removal~~ —
  fixed inside the PR (`Test.Layouts` renders `page_title` via
  `<.live_title>`).
- ~~BUG - MEDIUM: settings-save test asserts a value the cache can't see~~ —
  fixed in `56b849a` ("Update the core floor to ~> 2.38 …"). The failure came
  from a stale `mix.lock` pinning core 2.21.1, whose
  `Settings.get_settings_cached/2` had no miss-fill: a key absent from the
  cache read as `nil` and fell back to the default (30). Core 2.38+ fills
  misses, so the batched read sees the saved 45.
  `report_pages_test.exs` ("settings page saving updates the stored
  settings") passes and asserts both `retention_days/0` and
  `session_timeout_minutes/0`.

## Open

None.
