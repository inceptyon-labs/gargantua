---
# gargantua-apnw
title: 'Task: Developer Tools UI (availability gating + preview panes)'
status: todo
type: task
priority: normal
created_at: 2026-04-18T22:18:47Z
updated_at: 2026-04-18T22:18:52Z
parent: gargantua-7hdn
blocked_by:
    - gargantua-rwpi
---

Surface Homebrew/Docker controls in UI only when DeveloperToolPreviewAdapter.availability() reports installed. Render dry-run previews via preview(.homebrew) and preview(.docker) into preview panes with reclaimable sizes. Preserve multi-word Docker types (e.g. 'Build Cache'). No execute path yet — destructive ops are Phase 3 behind Trust Layer confirmation. Reference: Sources/GargantuaCore/Views/, DeveloperToolPreviewAdapter.swift.
