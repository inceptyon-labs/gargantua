---
# gargantua-evdi
title: 'Task: Bounded/cancellable directorySize for Disk Explorer'
status: todo
type: task
priority: normal
created_at: 2026-04-17T02:28:51Z
updated_at: 2026-04-17T02:28:51Z
---

`DirectorySizeScanner.directorySize(at:)` is still an unbounded recursive walk via `FileManager.enumerator`. A single large directory (e.g. `~/Library` at 150 GB with millions of inodes) can keep one of the 4 concurrent sizing tasks busy for 30+ seconds. It already checks `Task.isCancelled` per file so cancellation is responsive, but we have no per-call wall-clock cap and no way to report partial progress for the single in-flight directory.

Scoped out of gargantua-y1zi (streaming cutover) because the streaming fix made Disk Explorer feel responsive from the first second; individual large directories just resolve late. Worth tackling as a follow-up once we have a real-world feel for which directories are the slow tail.

## Suggested approach
- Accept an optional `timeout: Duration` (e.g. 15s) on `directorySize`; return the partial total and an `isPartial` flag when exceeded
- Surface partial sizes in `DirectoryItem` (new `isPartial: Bool` or size tuple)
- DiskExplorerView renders a "~" prefix or caret icon on partial rows so users know the size is a lower bound

## Related
- gargantua-y1zi — streaming fix that made this a latent issue rather than a blocker
- Pre-existing avik Codex follow-ups (walker exclude pruning, hidden-file policy, million-entry streaming, `..` normalization) — all adjacent but tracked separately in handoffs if ever filed
