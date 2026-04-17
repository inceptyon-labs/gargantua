---
# gargantua-avik
title: 'Task: Bounded glob walker for ** patterns in NativeScanAdapter'
status: in-progress
type: task
priority: high
created_at: 2026-04-17T01:07:11Z
updated_at: 2026-04-17T01:23:08Z
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
