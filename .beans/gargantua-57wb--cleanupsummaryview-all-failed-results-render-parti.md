---
# gargantua-57wb
title: 'CleanupSummaryView: all-failed results render ''Partially Complete'' header'
status: todo
type: bug
priority: normal
created_at: 2026-04-18T13:03:59Z
updated_at: 2026-04-18T13:03:59Z
blocked_by:
    - gargantua-yzja
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

- [ ] `CleanupSummaryView` header for total-failure results reads "Cleanup Failed" (or equivalent), not "Partially Complete"
- [ ] Success section hidden when zero items succeeded
- [ ] Unit test: `CleanupResult(itemResults: [<all failed>])` → header state differs from partial case
- [ ] Smoke-test Deep Clean summary path doesn't regress
