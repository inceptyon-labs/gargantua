---
# gargantua-pxva
title: 'Task: Smart Uninstaller UI (picker + plan review + confirmation)'
status: completed
type: task
priority: normal
created_at: 2026-04-17T21:50:14Z
updated_at: 2026-04-18T01:55:27Z
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

## Summary of Changes

**Files changed:**
- Sources/GargantuaCore/Models/Uninstaller/RemnantItem+ScanResult.swift (new) — public toScanResult() helper
- Sources/GargantuaCore/Services/RemnantScanner.swift — added UninstallPlanning protocol, scanner conforms
- Sources/GargantuaCore/Services/UninstallExecutor.swift — added UninstallExecuting protocol, removed duplicate private conversion helper
- Sources/GargantuaCore/Views/SidebarView.swift — added "Smart Uninstaller" item in CLEAN section
- Sources/GargantuaCore/Views/SmartUninstaller/{SmartUninstallerView,SmartUninstallerViewModel,UninstallAppPickerView,UninstallPlanReviewView,UninstallRemnantRow,ProtectedItemsTogglePanel}.swift (new)
- Sources/Gargantua/MainContentView.swift — route "smartUninstaller" sidebar selection
- Tests/GargantuaCoreTests/Views/SmartUninstaller{ViewModel,Execution}Tests.swift + SmartUninstallerTestFixtures.swift (new) — 16 tests covering app picker filtering/sort, plan selection defaults, protected-item gating, execution options, re-entrancy guard, Trash-only enforcement

**Key decisions:**
- ViewModel owns a phase state machine (idle → pickingApp → scanning → reviewingPlan → executing → summary | failed) with service protocols (AppScanning, UninstallPlanning, UninstallExecuting) so tests can inject stubs
- Reused existing ConfirmationModalView (3-tier router) and CleanupSummaryView rather than reimplementing them
- Hard-wired cleanupMethod to .trash in UninstallExecutionOptions because the executor rejects .delete — picking Delete in the modal would otherwise surface as a failed uninstall after final confirm
- execute() guards on `.reviewingPlan` phase to swallow double-confirms and key-repeat activations
- RemnantScanner.plan runs on a detached task in selectApp so the .scanning phase is observable on large apps (filesystem IO was blocking @MainActor)
- Running-app banner only shows when the app bundle itself is selected, since the executor only terminates the process when removing the bundle
- Protected items gated behind an opt-in toggle; deselecting the toggle also drops any protected items already in the selection so the canProceed invariant stays consistent

**Notes for next task:**
- Real authorization prompting for protected items is still a stub — authorizationProvider defaults to { nil } and the executor throws .authorizationRequired. Follow-up bean should wire up an SMAppService/XPC privileged helper and obtain an AuthorizationRef via AuthorizationServices.
- Minor: RemnantItem.id uniqueness depends on rule IDs being unique + per-rule counter; consider asserting or deduplicating when building UninstallPlan if we ever allow user-authored rules in the uninstaller path (Codex review raised this as a theoretical WARNING).

**Status Update:** Merged to main in 8b502f6.
