---
# gargantua-7xh2
title: 'Task: Thread active profile into Deep Clean'
status: todo
type: task
priority: normal
created_at: 2026-04-17T18:07:17Z
updated_at: 2026-04-17T18:07:17Z
parent: gargantua-lupo
---

DeepCleanView currently defaults to `.deep` from MainContentView. Wire persisted active profile selection into Deep Clean where appropriate so PRD cleanup-profile UX is honored consistently.

Acceptance criteria:
- MainContentView resolves active profile from PersistenceController settings
- DeepCleanView receives the active profile or a documented Deep-specific override
- Behavior is covered by focused tests or a clear smoke note
- Existing `.deep` default remains safe when persistence is unavailable
