---
# gargantua-lm94
title: 'Task: Wire Quick Scan button to NativeScanAdapter'
status: completed
type: task
priority: high
created_at: 2026-04-17T01:06:23Z
updated_at: 2026-04-17T01:06:37Z
parent: gargantua-l9dk
---

Replace the dashboard Quick Scan button's MoCleanAdapter call with NativeScanAdapter driven by YAML rules.

## Acceptance Criteria
- [x] New `NativeScanAdapter` service that loads YAML rules, walks paths, applies `SafetyClassifier`, emits `[ScanResult]`
- [x] `RuleDirectoryResolver` finds `cleanup_rules/` via env var → app bundle → walking up from executable (supports `swift run` + shipped `.app`)
- [x] Dashboard `startQuickScan()` replaces `MoCleanAdapter` call with `NativeScanAdapter` using `.light` profile
- [x] Scan output flows into `AlertItem.aggregate` unchanged
- [x] Build green (`swift build`)

## Files Touched
- Sources/GargantuaCore/Services/NativeScanAdapter.swift (new)
- Sources/GargantuaCore/Views/DashboardView.swift:152-173 (startQuickScan rewired)

## Summary of Changes
Created `NativeScanAdapter` that iterates loaded `ScanRule` values, filters by active `CleanupProfile.categories`, expands `~` in paths, enumerates children when a rule has `exclude` patterns (so each browser cache subdir becomes its own result), measures size via `DirectorySizeScanner.directorySize`, applies `SafetyClassifier.classify` for profile-aware overrides, and reports per-rule progress through `ScanProgress`. Co-located `RuleDirectoryResolver` resolves the cleanup_rules directory across dev and shipped contexts.

## Known Limitations (handled by follow-up tasks under epic l9dk)
- Glob patterns (`**/node_modules`, `*cache*`) are currently skipped — see sibling task for bounded glob walker
- Exclude pattern matcher is a minimal fnmatch — complex patterns may miss
- Only `.light` profile is used for the Quick Scan button
