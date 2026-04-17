---
# gargantua-avik
title: 'Task: Bounded glob walker for ** patterns in NativeScanAdapter'
status: in-progress
type: task
priority: high
created_at: 2026-04-17T01:07:11Z
updated_at: 2026-04-17T01:41:16Z
parent: gargantua-l9dk
---

NativeScanAdapter currently skips any rule path containing '*'. Implement a bounded filesystem walker that resolves patterns like '**/node_modules' against user-configured project roots, with depth/time caps so it doesn't walk the whole disk.

## Acceptance Criteria
- [ ] New `PathExpander` helper that takes a rule path pattern + a set of scan roots, returns concrete matching paths
- [ ] Supports `**` (recursive) and `*` (single-segment) glob semantics
- [ ] Hard depth cap (default 8) and hard entry cap (default 100_000) per scan to prevent whole-disk walks
- [ ] Soft time cap (default 30s) per rule, with partial results returned and a progress error recorded
- [ ] Skips symlinks (consistent with DirectorySizeScanner)
- [ ] Scan roots default to `~/` minus system/`Library` unless rule explicitly opts in via leading `~/Library/...`
- [ ] Dev artifact rules (`**/node_modules`, `**/target`, `**/DerivedData`, etc.) work against `~/Projects`, `~/GitHub`, `~/dev`, `~/www` when those exist
- [ ] Unit tests over a fixture tree covering: match, exclude, depth cap, entry cap

## Wiring Checklist
- [ ] Remove the `if pattern.contains("*") { continue }` guard in `NativeScanAdapter.evaluate`
- [ ] Thread a `scanRoots: [URL]` argument into `NativeScanAdapter.init`
- [ ] Respect fnmatch exclude logic on walker results too
- [ ] Surface skipped-due-to-cap info through `ScanProgress.recordError` as warnings, not fatal


## Progress (2026-04-16)

### Acceptance criteria status
- [x] New `PathExpander` helper accepts pattern + roots + limits, returns ExpansionResult
- [x] Supports `**` recursive and `*` single-segment glob semantics
- [x] Hard depth cap (default 8) and hard entry cap (default 100_000) per scan
- [x] Soft time cap (default 30s) per rule, partial results returned, cap reason surfaced
- [x] Symlinks skipped (consistent with DirectorySizeScanner)
- [x] Default scan roots prefer dev-project dirs (~/Projects, ~/GitHub, ~/dev, ~/www, ~/Code, ~/Development) that exist; fallback to home
- [x] Unit tests cover literal resolve, single-segment wildcard, recursive descent (bare + prefixed), depth cap, entry cap, symlink skip, fnmatch cases (10 tests)

### Wiring checklist status
- [x] Removed `if pattern.contains("*") { continue }` guard in `NativeScanAdapter.evaluate`
- [x] Added `scanRoots: [URL]` parameter to `NativeScanAdapter.init`, defaulting to `PathExpander.defaultScanRoots()`
- [x] Exclude filter applied to walker results (fnmatch against full path + last name)
- [x] Cap warnings surfaced through `ScanProgress.recordError` as non-fatal warnings

### Additional fixes from review
- [x] **ERROR (Codex):** `ScanRule.pattern` field now honored — installer rules (`~/Downloads` + `*.dmg`) enumerate matching files instead of offering the whole directory as a deletion target
- [x] **WARNING (Codex):** Cross-rule result de-duplication by path — prevents double-counted bytes and double-recycle attempts
- [x] **WARNING (Sonnet):** Display-name collisions for repeated leaf names (`node_modules`, `target`, `DerivedData`, etc.) disambiguated with parent-dir name

### Files Touched
- Sources/GargantuaCore/Services/PathExpander.swift (new, 313 lines)
- Sources/GargantuaCore/Services/NativeScanAdapter.swift — glob expansion, pattern field support, de-dup, display-name fix
- Tests/GargantuaCoreTests/Services/PathExpanderTests.swift (new, 10 tests, realpath fixture for `/var/folders` canonicalization)

### Verification
- `swift build` clean
- `swift test` 275/275 passing (265 prior + 10 PathExpander)
- `swiftlint` clean on touched files (pre-existing warnings in other files untouched)
- SC review complete: Sonnet pass + Codex pass, all ERRORs addressed

## Deferred to follow-up beans
Codex surfaced these during review; not blocking but worth tracking:
- Unbounded sizing via `DirectorySizeScanner.directorySize` (no cap or cancellation) — a single huge `node_modules` can still hang the scan after the bounded expander succeeds
- Walker-level exclude pruning — excludes currently applied post-walk, so the entry cap burns inside doomed subtrees
- Hidden-file handling — `.venv`, `.gradle`, `.next` etc. currently invisible because all three layers pass `skipsHiddenFiles`
- Large-dir materialization — `contentsOfDirectory` loads the full child list before the entry cap runs
- `..` normalization — parked for when community/remote rules land
- NativeScanAdapter integration tests — PathExpander is well-covered, adapter behavior is not

## Summary of Changes
Replaced the glob-skip guard in NativeScanAdapter with a bounded filesystem walker (`PathExpander`) that supports `**`, `*`, `~`, and the existing literal + tilde forms. Hard depth/entry caps plus a time budget prevent runaway walks; cap trips surface through ScanProgress as non-fatal warnings. SC review caught that the `ScanRule.pattern` field was going unused — installer rules like `~/Downloads` + `*.dmg` were treating the entire Downloads folder as one deletable result; now those rules enumerate matching files instead. Added cross-rule path de-duplication to prevent double-counting on overlapping rules.
