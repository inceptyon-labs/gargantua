---
# gargantua-omp3
title: 'Feature: Cleanup Execution UX'
status: todo
type: feature
priority: normal
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-16T11:06:44Z
updated_at: 2026-04-16T11:06:44Z
---

Wire the cleanup execution flow end-to-end: confirmation modals before cleanup, CleanupEngine execution, post-cleanup summary, and trash reveal. All components exist but are orphaned.

## Goals
- ConfirmationModalView shown before any cleanup operation
- CleanupEngine executes the actual file moves to Trash
- CleanupSummaryView shown after cleanup completes
- TrashRevealer enables 'Reveal in Trash' from summary
- AuditWriter records all cleanup operations

## Scope
**In Scope:** Wiring existing views and services into cleanup flow
**Out of Scope:** New cleanup strategies, undo beyond trash reveal
