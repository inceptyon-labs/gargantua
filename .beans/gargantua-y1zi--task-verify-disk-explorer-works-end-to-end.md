---
# gargantua-y1zi
title: 'Task: Verify Disk Explorer works end-to-end'
status: completed
type: task
priority: high
created_at: 2026-04-17T01:07:47Z
updated_at: 2026-04-17T02:28:20Z
---

User reports Disk Explorer 'doesn't work'. mo analyze --json is real (unlike mo clean/purge) so this is probably a different failure — binary path, permission, or UI wiring. Diagnose and fix so Disk Explorer actually opens a directory treemap-style view per PRD §5.



## Diagnosis (2026-04-16)

**Bean hypothesis was wrong.** `DiskExplorerView` does NOT use `MoAnalyzeAdapter` — it uses the native `DirectorySizeScanner` (FileManager-based). The "doesn't work" symptom is a UX problem, not a mo-binary/permission problem.

**Root cause**: `DirectorySizeScanner.scanChildren(of: NSHomeDirectory())` is fully serial with no streaming, progress, or cancellation. On this machine, sizing `~/Library` (150 GB) alone takes 31s and `~/Development` (61 GB) takes 21s. Total cold-cache scan of `~` is ~54s. User sees only `ProgressView()` the whole time → reads as "broken".

**Measured on this machine:**
- `~` top-level: 16 directories, 54s total
- `~/Library`: 31.4s (150 GB)
- `~/Development`: 21.4s (61 GB)
- Everything else: <1s each

## Plan

Make the UI visibly progress from the first second by streaming per-child sizing results. Directory rows appear immediately with a spinner in the size column; each resolves as its size is computed. Uses bounded concurrency so SSD parallelism helps but we don't thrash the filesystem.

### Scope
- Stream results from `DirectorySizeScanner` via `AsyncStream<DirectoryItem>`.
- Add `DirectoryItem.isSizing` flag so the row can render a spinner while pending.
- Rewire `DiskExplorerView.loadDirectory` to consume the stream and keep `items` sorted largest-first as results arrive.
- Bounded concurrency (cap 4) around the per-child `directorySize` call.
- Cancellation when the user navigates (the `.task(id:)` modifier cancels the old task; the stream honors `Task.isCancelled`).

### Out of scope (tracked by other beans from avik review)
- Bounded/cancellable `directorySize` (per-call time cap) — follow-up
- Walker-level exclude pruning for `node_modules` etc. — follow-up
- Hidden-file policy for `.venv`/`.gradle`/`.next` — follow-up
- Streaming child enumeration of million-entry dirs — follow-up

## Acceptance Criteria
- [x] `DirectorySizeScanner.streamChildren(of:)` returns `AsyncStream<DirectoryItem>`; emits a row per directory as soon as its size is known; emits `(Files)` aggregate once
- [x] `DirectoryItem.isSizing: Bool` added; defaults to `false`
- [x] `DiskExplorerView` keeps rows live-sorted and renders a spinner in the size column while `isSizing == true`
- [x] Bounded concurrency: no more than 4 child `directorySize` calls in flight at once
- [x] Stream cancels promptly when `.task(id: currentPath)` restarts (verified via `Task.isCancelled` inside the stream)
- [x] Permission-denied children still render with the lock icon and "Requires Full Disk Access" caption
- [x] Tests: streaming emits expected children for a tmp dir with known layout; cancellation stops mid-stream; `(Files)` aggregate present (+ real `(files)` dir collision coverage)
- [x] `swift build` clean, `swift test` all passing (285/285), SwiftLint clean on changed files
- [ ] Live smoke: launching app → Disk Explorer at `~` shows first row within 1s, all rows resolved within 60s on this machine



## Summary of Changes

**Root cause of "Disk Explorer doesn't work"**: DiskExplorerView uses the native `DirectorySizeScanner`, not `MoAnalyzeAdapter` as the bean originally hypothesized. `scanChildren(of: NSHomeDirectory())` was fully serial with no streaming/progress/cancellation — on this machine it blocks for ~54s (`~/Library` 31s, `~/Development` 21s), during which users see only a spinner and read the feature as broken.

**Fix**: added `DirectorySizeScanner.streamChildren(of:) -> AsyncStream<DirectoryItem>`. The producer enumerates immediate children synchronously and emits an `isSizing: true` placeholder per readable subdirectory, then sizes those subdirectories concurrently (cap 4 in flight via `withTaskGroup`) and emits a replacement row per directory as its recursive size resolves. The (Files) aggregate emits once. Permission-denied children emit a single lock row.

`DiskExplorerView.loadDirectory` consumes the stream, upserts rows by `id`, and keeps the list live-sorted largest-first. A per-row `ProgressView` renders in the size column while `isSizing == true`. Cancellation propagates through the whole stack: consumer task → stream `onTermination` → producer `Task.cancel` → TaskGroup children → `directorySize`'s per-iteration `Task.isCancelled` check.

**Codex SC review** caught two issues pre-merge:
1. A real child directory literally named `(files)` would have a path that collides with the synthetic aggregate's path, so upsert-by-id would drop one of the two rows. Fixed by adding `DirectoryItem.isFilesAggregate: Bool` that disambiguates `id`; DiskExplorerView's drill-down and aggregate-styling checks now use the flag instead of a `hasSuffix` heuristic.
2. A narrow window where a row could be yielded after consumer cancellation (between `group.next()` resuming and the `yield` call). Fixed with a re-check right before yielding.

**Pending**: live smoke test on the running app (user-driven) — open app → Disk Explorer → first directory row should appear within ~1s; all ~16 home children resolved within ~60s on this machine. Size bars will rescale as larger directories resolve (accepted UX tradeoff).

**Merged**: completed in 49bce1e.
