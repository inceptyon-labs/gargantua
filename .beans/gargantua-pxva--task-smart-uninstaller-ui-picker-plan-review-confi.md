---
# gargantua-pxva
title: 'Task: Smart Uninstaller UI (picker + plan review + confirmation)'
status: in-progress
type: task
priority: normal
created_at: 2026-04-17T21:50:14Z
updated_at: 2026-04-18T01:36:58Z
parent: gargantua-j8a1
blocked_by:
    - gargantua-9dxb
---

SwiftUI surface for the Smart Uninstaller: app picker, plan review grouped by RemnantCategory, Trust Layer confirmation flow, post-uninstall summary.

Scope:
- App picker: search + sort (by name / size / last used), filter isSystemApp
- Plan review screen: groups = remnantsByCategory, size totals, per-item safety badge, expand/collapse per group
- Confirmation tiers from SafetyLevel.confirmationTier: singleButton / summaryDialog / fullModal
- Running-app warning banner when AppInfo.isRunning
- Protected items locked with override unlock UX
- Post-uninstall: CleanupSummaryView-style recap with bytes freed + rollback hint (Trash)
- Follow .interface-design/system.md tokens; run /interface-design:audit when done
- Accessibility: full VoiceOver labels on safety badges, keyboard-navigable tree

Blocked by gargantua-9dxb (execution path).
