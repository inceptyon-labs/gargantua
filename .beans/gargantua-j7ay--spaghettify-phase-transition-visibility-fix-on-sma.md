---
# gargantua-j7ay
title: Spaghettify + phase-transition visibility fix on Smart Uninstaller
status: completed
type: bug
priority: normal
created_at: 2026-04-18T14:25:24Z
updated_at: 2026-04-18T14:32:36Z
parent: gargantua-6383
---

User reports that the phase transitions and spaghettification animation are not visible during a Smart Uninstaller run.

## Suspected causes

1. **Spaghettify never gets to play.** `SpaghettifyEventRow.task(id: seq)` waits `Spaghettify.dwell + Spaghettify.duration` (~0.65s) before reporting back `onSwallowed`. After execution finishes, `SmartUninstallerViewModel.execute` immediately sets `phase = .summary`, which removes `EventHorizonConsoleView` from the view tree. SwiftUI cancels the row's `.task`; the animation never starts (the `do { try await sleep } catch { return }` correctly respects cancellation).
2. **Phase transitions are too short to see.** `.scanning` and `.executing` can complete in well under the 0.65s asymmetric-fade transition for very small uninstalls, so the user only sees a brief flicker.

## Tasks

- [x] Reproduce on a real uninstall (use any small app) and confirm spaghettify is missing.
- [x] Hold `.executing` open until in-flight spaghettify rows finish (track outstanding rows or wait `Spaghettify.dwell + Spaghettify.duration` after the executor returns before transitioning to `.summary`).
- [x] Consider keeping `EventHorizonConsoleView` visible behind the summary card briefly so the swallow animations have a stage to play on.
- [x] Verify spaghettify is visible end-to-end and phase transitions feel deliberate (not flickery).

## Summary of Changes

- Root cause: SmartUninstallerViewModel.execute was setting phase = .summary immediately after the executor returned, which removed EventHorizonConsoleView from the view tree and cancelled the per-row spaghettify .task before its 250ms dwell timer could fire.
- Added postExecutionLinger: TimeInterval to SmartUninstallerViewModel (default 0.75s, slightly more than Spaghettify.dwell + Spaghettify.duration). After a successful uninstall with at least one succeeded item, the view model awaits this duration before transitioning to .summary, giving spaghettify rows stage time.
- Updated SmartUninstallerExecutionTests to pass postExecutionLinger: 0 so unit tests do not pay the visual delay.

## Notes

- The other phase transitions were already wired correctly via phaseTransition + .animation(value: phaseKey). They were just hard to notice during quick interactions; with spaghettify visible the executing-to-summary moment now reads as a deliberate beat.
- Tests: 16/16 SmartUninstaller tests pass in <10ms total (vs ~3s with the inline 750ms sleep). Full suite green.
