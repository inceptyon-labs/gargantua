---
# gargantua-zq15
title: 'Bug: lastAccessed uses modificationDate, not access time'
status: in-progress
type: bug
priority: normal
created_at: 2026-04-17T02:00:07Z
updated_at: 2026-04-17T16:30:33Z
parent: gargantua-l9dk
---

NativeScanAdapter.makeResult populates `lastAccessed` from `.modificationDate`, but `ConditionEvaluator` treats age as last-access age. A directory that's mtime-stale but actively being read (e.g., an in-use build cache) can get auto-classified as safe and pre-selected for cleanup.

Codex SC review of gargantua-guga surfaced this during the Dev Purge cutover. Low priority — modification time is still a reasonable proxy for most cases, but worth correcting to avoid false-positive deletions.
