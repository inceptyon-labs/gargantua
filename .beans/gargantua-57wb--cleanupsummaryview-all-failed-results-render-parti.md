---
# gargantua-57wb
title: 'CleanupSummaryView: all-failed results render ''Partially Complete'' header'
status: completed
type: bug
priority: normal
created_at: 2026-04-18T13:03:59Z
updated_at: 2026-04-20T12:55:28Z
---

Pre-existing inconsistency flagged by Codex review during gargantua-yzja.

When a cleanup result has zero succeeded items and >0 failed items (total
failure), `CleanupSummaryView`'s own header still renders "Cleanup Partially
Complete" with the amber `review` icon, because `result.allSucceeded` only
checks `failedItems.isEmpty`. The success section then shows "0 items moved
to Trash".

In the Smart Uninstaller surface, this means a red "SIGNAL LOST" banner with
a red accent bar sits directly above an amber-iconed "Partially Complete"
card that reads "0 items moved" — visually contradictory.

### Proposed fix

Treat "zero succeeded + >0 failed" as a distinct "total failure" state in
`CleanupSummaryView.header`:

- Icon: `xmark.octagon.fill` in `protected_`
- Heading: "Cleanup Failed"
- Suppress the "0 items moved" success section entirely in this case

### Scope note

Was explicit non-goal of gargantua-yzja ("Refactoring the underlying
CleanupSummaryView — used by Deep Clean too"). Address separately so Deep
Clean / DevArtifactScan benefit too.

### Acceptance

- [x] `CleanupSummaryView` header for total-failure results reads "Cleanup Failed" (or equivalent), not "Partially Complete"
- [x] Success section hidden when zero items succeeded
- [x] Unit test: `CleanupResult(itemResults: [<all failed>])` → header state differs from partial case
- [x] Smoke-test Deep Clean summary path doesn't regress (build + 719 tests pass; no CleanupSummaryView API changed)


## Summary of Changes

Introduced `CleanupSummaryView.SummaryOutcome` (`.complete` / `.partial` / `.failed`) and a static `outcome(for:)` classifier. `.failed` (zero succeeded, >0 failed) now renders `xmark.octagon.fill` in `protected_` with heading "Cleanup Failed", suppresses the success section and the `0 Bytes freed` subtext. `.complete` and `.partial` are unchanged.

No public API change: `CleanupResult.allSucceeded` is preserved; the classifier is a view-internal helper exposed `internal` (not `public`) for `@testable` unit tests.

Files:
- `Sources/GargantuaCore/Views/CleanupSummaryView.swift` — enum + classifier + header switch + conditional success section
- `Tests/GargantuaCoreTests/Views/CleanupSummaryViewTests.swift` — 5 tests covering complete / partial / failed / single-failed / empty

Deep Clean and DevArtifactScan pick up the fix automatically since they use the same `CleanupSummaryView`.
