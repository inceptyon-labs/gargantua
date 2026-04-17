---
# gargantua-i6ev
title: 'Task: Phase 1.5 live app smoke test'
status: todo
type: task
priority: critical
created_at: 2026-04-17T18:07:17Z
updated_at: 2026-04-17T18:07:17Z
parent: gargantua-l9dk
---

Validate the current native-scanner app end-to-end from the actual running macOS app.

Acceptance criteria:
- Launch app from `swift run Gargantua` or built `.app`
- Deep Clean produces real NativeScanAdapter results
- Dev Purge produces real NativeScanAdapter results using default/custom scan roots
- System Status renders native metrics
- Disk Explorer opens and resolves rows progressively
- Clean flow moves selected safe fixture items to Trash and writes an audit entry
- Capture any manual notes/screenshots in the bean body

This is a manual smoke gate; automated tests already pass.
