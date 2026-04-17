---
# gargantua-zq15
title: 'Bug: lastAccessed uses modificationDate, not access time'
status: completed
type: bug
priority: normal
created_at: 2026-04-17T02:00:07Z
updated_at: 2026-04-17T16:31:55Z
parent: gargantua-l9dk
---

NativeScanAdapter.makeResult populates `lastAccessed` from `.modificationDate`, but `ConditionEvaluator` treats age as last-access age. A directory that's mtime-stale but actively being read (e.g., an in-use build cache) can get auto-classified as safe and pre-selected for cleanup.

Codex SC review of gargantua-guga surfaced this during the Dev Purge cutover. Low priority — modification time is still a reasonable proxy for most cases, but worth correcting to avoid false-positive deletions.


## Summary of Changes

Swapped `lastAccessed` source in `NativeScanAdapter.makeResult` from `FileManager.attributesOfItem(atPath:)[.modificationDate]` to URL resource values (`.contentAccessDateKey`) with `.contentModificationDateKey` as a fallback for filesystems that don't track atime.

Also consolidated the prior separate `isDirectoryKey` and `attributesOfItem` probes into a single `resourceValues(forKeys:)` call — net fewer syscalls per result.

Effect: `ConditionEvaluator`'s age checks now reflect actual last-access age, so an actively-read build cache with a stale mtime no longer gets auto-classified safe and pre-selected for deletion.

- File: `Sources/GargantuaCore/Services/NativeScanAdapter.swift` (3 lines changed)
- Tests: 235/235 passing; lint clean for this change (pre-existing `type_body_length` warning untouched)
- Commit: 8457def merged to main in merge commit
