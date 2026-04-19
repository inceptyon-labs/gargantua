---
# gargantua-rp82
title: 'Task: Wire FclonesAdapter into ScanEngine pipeline'
status: completed
type: task
priority: high
created_at: 2026-04-18T22:18:15Z
updated_at: 2026-04-19T02:47:29Z
parent: gargantua-4nb9
blocked_by:
    - gargantua-i1ii
---

Compose FclonesAdapter alongside NativeScanAdapter/CzkawkaAdapter in a multi-adapter scan pipeline so duplicate results surface through ScanEngine. Respect PRD §5 sequential pipeline rule (never run fclones + czkawka + native simultaneously). Keep duplicate results review-by-default. Blocked-by: gargantua-i1ii (adapter shipped). Reference: Sources/GargantuaCore/Services/ScanAdapter.swift, FclonesAdapter.swift.


## Summary of Changes

Introduced `ScanEngine`, a sequential multi-adapter composition type
conforming to `ScanAdapter`, and wired `FclonesAdapter` through it so
the Duplicate Finder UI receives live results.

**New files**
- `Sources/GargantuaCore/Services/ScanEngine.swift` — runs child
  adapters one at a time (`for adapter in adapters { try await ... }`);
  never uses `async let` / `TaskGroup` per PRD §8.4. Empty adapter list
  returns `[]`; any adapter throwing stops the pipeline. Review-by-
  default safety from `FclonesAdapter` carries through unchanged since
  the engine does not re-classify. Doc-comments a known limitation
  around shared `ScanProgress` across multiple adapters for the
  next caller that wants multi-adapter pipelines.
- `Sources/GargantuaCore/Views/DuplicateFinderContainerView.swift` —
  SwiftUI state owner (idle → scanning → results/error) that builds
  a `ScanEngine` wrapping `FclonesAdapter.autoDetect(...)`. Binary-
  missing failures surface as retry-able error state with the
  resolver's own error message (suggests `brew install fclones` or
  `GARGANTUA_FCLONES_BIN`). Resets `selectedIDs` before every scan so
  stale fclones ids (which are only stable within one scan) can't
  point into a new result set.
- `Tests/GargantuaCoreTests/Services/ScanEngineTests.swift` — 7 tests
  covering empty list, single-adapter pass-through, in-order
  concatenation, strict sequential execution (with a DispatchQueue-
  serialised overlap detector), throwing adapter stopping the
  pipeline, engine-in-engine nesting, and `.review` safety
  preservation.
- `Tests/GargantuaCoreTests/Views/DuplicateFinderContainerStateTests.swift`
  — 4 tests for the `deriveScanState(results:errors:)` helper
  introduced during Codex review (see below).

**Modified**
- `Sources/Gargantua/MainContentView.swift` — the `"duplicateFinder"`
  case now hosts `DuplicateFinderContainerView` and forwards the same
  `resolvedScanRoots` already used by Dev Purge. `onSendToTrash` is
  still unwired; the Trust Layer / ConfirmationModalView flow for
  destructive duplicate removal remains a follow-up Task.

**Baseline**: 656 → 667 tests (+11). `swift build -Xswiftc
-warnings-as-errors` clean. `swiftlint --strict` clean on all touched
files; 47 pre-existing violations in unrelated files are unchanged
ambient tech debt.

**SC review**: Sonnet Pass 1 found 0 ERRORs. Codex Pass 2 caught one
ERROR and two WARNINGs:
- (ERROR, fixed) `FclonesAdapter.scan()` reports hard failures
  (timeout, non-zero exit, JSON parse) on `ScanProgress.errors` and
  returns `[]` rather than throwing — the container was treating
  empty results as success, so a failed scan would render as "No
  duplicates found" with no indication that anything broke. Added a
  pure `deriveScanState(results:errors:)` helper: empty results +
  non-empty errors → `.error` (joined messages); partial success
  (results + errors) still renders `.results` so a single
  permission-denied subdir doesn't block review.
- (WARNING, fixed) Scan `Task` was not retained or cancelled — a
  re-scan could race with a late completion from the prior scan.
  Now tracked in `@State`, cancelled on every re-scan, and guarded
  by a generation id so superseded completions are dropped on the
  MainActor hop.
- (WARNING, documented) Single shared `ScanProgress` across multiple
  adapters causes `isScanning`/`fractionCompleted` to oscillate
  between adapters because each adapter calls `start()`/`finish()`.
  Not exercised by the current single-adapter pipeline. Documented
  on `ScanEngine` as a known limitation; multi-adapter UIs (Deep
  Clean composing native + czkawka through the engine) will need
  either per-child progress objects or engine-owned aggregate
  progress before landing.

## Key Decisions (for follow-up Tasks)

- **`ScanEngine` conforms to `ScanAdapter`.** Engines nest cleanly,
  and existing call sites that already take `any ScanAdapter` (e.g.
  `DeepCleanView.adapterOverride`) can accept an engine without
  changes. Verified with a "nested engine" test.
- **Sequential semantics are the contract, not an implementation
  detail.** The unit test uses 50ms delays + a DispatchQueue-based
  overlap detector so a future refactor that naively introduces
  concurrency would fail loudly. PRD §8.4 cited inline.
- **Trust Layer boundary stays above the container.** `onSendToTrash`
  is still forwarded; this Task deliberately does not wire a real
  trash callback. The next Task in this feature (post-Trust-Layer)
  picks up that wire.
- **Duplicate scan is user-initiated.** The container starts in the
  idle state with a "Scan for duplicates" button. Navigating to the
  Duplicate Finder does not auto-run fclones — large home directories
  can take minutes, and an auto-scan would burn CPU the moment the
  user clicked the sidebar item.
