---
# gargantua-qwz4
title: 'Task: Smoke grouped Deep Clean result modes'
status: todo
type: task
priority: normal
created_at: 2026-04-17T18:07:17Z
updated_at: 2026-04-17T18:07:17Z
parent: gargantua-r8vu
---

Validate folder/category/safety grouping on real Deep Clean scan results.

Acceptance criteria:
- Run a Deep Clean scan with enough results to exercise grouping
- Toggle Safety, Folder, and Category modes
- Folder and category groups are sorted by total reclaimable bytes descending
- Expanding/collapsing groups works
- Selection state survives mode toggles
- Keyboard navigation remains usable after toggling modes

Automated grouping tests exist; this is the remaining real-result UX smoke gate.
