---
# gargantua-r8u6
title: Apply themed scan console + Singularity summary to Deep Clean
status: completed
type: feature
priority: normal
created_at: 2026-04-18T14:25:39Z
updated_at: 2026-04-18T15:30:47Z
parent: gargantua-6383
---

Wrap Deep Clean's scan/clean lifecycle in the same cosmic theming as Smart Uninstaller: `EventHorizonConsoleView` during scanning + cleaning, `SingularityCloseMessage` outcome on the summary, and asymmetric phase transitions between idle / scanning / results / cleaning / summary.

## Architectural notes

- `NativeScanAdapter` only accepts `ScanProgress` today — needs a `ScanProgressObserving` plumb-through (or a small bridge inside `DeepCleanView` that emits `ScanProgressEvent` from `progress.currentPath` updates) so the console has live event data.
- `CleanupEngine.clean` doesn't emit per-item events — needs the same bridge or a one-shot observer so the cleaning phase has visible activity.
- A `PathStreamViewModel` should live on `DeepCleanSessionState` so the buffer survives across navigation alongside results.

## Tasks

- [x] Add a phase enum to `DeepCleanSessionState` modelled on `SmartUninstallerPhase`.
- [x] Plumb `ScanProgressObserving` into `NativeScanAdapter.scan` and `CleanupEngine.clean` (or wrap with an adapter).
- [x] Replace the start-screen + scanning-footer combo with `EventHorizonConsoleView` during scan/clean phases, fed by a `PathStreamViewModel` on the session.
- [x] Replace `CleanupSummaryView` rendering with the Smart Uninstaller summary pattern: `SingularityCloseMessage` heading + line + accented `CleanupSummaryView`.
- [x] Adopt the same `phaseTransition` asymmetric fade between phases.
- [x] Verify scan + clean both feel cohesive with Smart Uninstaller; no regression to results-bucket UI.

## Summary of Changes

### Generalized chrome
- Refactored EventHorizonConsoleView to accept a EventHorizonContext struct instead of a SmartUninstallerPhase. The context bundles header, target, subtitle, isInProgress, isExecuting, and phaseKey so any tool can drive the same console.
- Added EventHorizonContext.uninstaller(phase:), .deepClean(phase:profileName:), and .devPurge(phase:profileName:) factories that derive the appropriate strings + flags. Smart Uninstaller copy is unchanged.

### Observer plumbing
- ScanAdapter protocol: added scan(progress:observer:) with a default impl that ignores the observer.
- NativeScanAdapter: emits .checked per sized child path, .match per dedup-survived result, .failed per per-rule warning.
- CleanupEngine: added clean(_:method:observer:) that emits .match (with bytes) for successful removals and .failed for failures. Default clean(_:method:) delegates to it with nil.

### Deep Clean refactor
- DeepCleanSessionState now owns a DeepCleanPhase enum (idle / scanning / results / cleaning / summary) and a PathStreamViewModel that persists across navigation.
- DeepCleanView body switches on phase; scanning + cleaning phases render EventHorizonConsoleView; summary renders the SingularityCloseMessage outcome heading + line + accented CleanupSummaryView, mirroring the Smart Uninstaller pattern.
- Asymmetric phase transitions match Smart Uninstaller (insertion: opacity + scale 0.92 + offset y:16; removal: opacity + offset y:-16; reduce-motion collapses to identity).
- After cleanup completes, the view holds the EventHorizonConsole on screen for 750ms (mirroring SmartUninstaller post-execution linger) so spaghettify swallow animations have stage time.
- Removed the now-dead scanningFooter and cleaningOverlay; the console replaces them.

### Verification
- swift build clean.
- Full test suite: 452/452 passing.
