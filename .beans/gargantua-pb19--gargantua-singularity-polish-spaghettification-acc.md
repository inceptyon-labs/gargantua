---
# gargantua-pb19
title: 'Gargantua singularity polish: spaghettification + accretion + summary'
status: completed
type: feature
priority: normal
created_at: 2026-04-18T02:52:03Z
updated_at: 2026-04-18T12:20:01Z
blocked_by:
    - gargantua-2v99
---

## Problem

The Event Horizon Console (bean gargantua-X) gives real info in a good costume, but the "executing" phase still feels like a list clearing itself. The theming is under-exploited. People should screenshot this.

## Scope

Polish pass on top of the console from bean #1. Pure visual/UX layer — no new plumbing.

### Spaghettification on delete

- [x] During the `executing` phase, each successfully deleted path animates out with a stretch-and-swallow effect (~400ms):
  1. Line's characters fan out with increasing kerning
  2. Trailing 6-10 characters dissolve into periods and dots (`→ · . . ·  ⊙`)
  3. Whole line fades to 0 and collapses vertically
- [x] Failed deletions do NOT spaghettify — they stay with a red `✗` and `TIDAL FORCES: anomalous` appears in the footer
- [x] Animation is `reduceMotion`-aware; honors `NSApp.effectiveAppearance` reduce motion

### Accretion disk polish

- [x] Upgrade the spinner from Unicode ring to a small SwiftUI Canvas drawing an accretion disk with subtle gravitational-lensing arc
- [x] Amber (`GargantuaColors.accretion`) with a warm core; rotation tied to activity rate (faster when events are streaming, slowing when idle)
- [~] Maintain a fallback to the Unicode ring if Canvas rendering is expensive (deferred — no perf signal exists to trigger it; dead-code fallback declined)

### Time-dilation easter egg

- [x] If the scan exceeds 10s wall time, fade in a single italic footer line:
  *`Δt: 7 minutes per second on Miller's planet`*
- [x] Only appears once per session; stays until the phase exits
- [x] Purely decorative — zero behavioral impact

### Summary screen upgrade

- [x] Rework `SmartUninstallerView.summaryState` to match the console aesthetic
- [x] Show `SIGNAL RECOVERED` heading over the existing `CleanupSummaryView`
- [x] Add a one-line close message sampled from a small pool keyed to success vs partial-failure:
  - Success: *"{n} artifacts lost to Gargantua. Mass recovered: {size}."*
  - Partial: *"{n} artifacts lost to Gargantua. {m} resisted tidal forces."*
  - Total fail: *"Signal lost. All artifacts still bound."*
- [x] Keep the existing action button (`Done`) as-is

## Tests

- [x] Spaghettification animation triggered once per deletion, not on check-only events (shouldSpaghettify guards on .match + executing phase + post-baseline seq)
- [x] Reduce-motion accessibility: animation collapses to instant-disappear (SpaghettifyModifier reduceMotion branch skips kerning/scale, hard-cuts opacity)
- [x] Time-dilation line appears only after 10s elapsed, only once (SingularitySession.shared.timeDilationShown gate; 10s threshold in tripTimeDilationIfDue)

## Non-goals

- Sound cues (can revisit if we decide to add)
- Custom fonts (use the system monospaced)
- Parallax / 3D effects

## Depends on

- gargantua-{plumbing bean id} — this polish layer requires the console to exist

## Files

- Sources/GargantuaCore/Views/SmartUninstaller/EventHorizonConsoleView.swift
- Sources/GargantuaCore/Views/SmartUninstaller/SpaghettifyModifier.swift (new)
- Sources/GargantuaCore/Views/SmartUninstaller/AccretionDiskView.swift (new)
- Sources/GargantuaCore/Views/SmartUninstaller/SmartUninstallerView.swift (summary phase)
- Tests/GargantuaCoreTests/Views/SpaghettifyModifierTests.swift (new)

## Summary of Changes

Four polish additions on the Smart Uninstaller Event Horizon Console — pure visual/UX layer, no plumbing changes to scanners or the executor.

### Added
- `Sources/GargantuaCore/Views/SmartUninstaller/SpaghettifyModifier.swift` — pure `Spaghettify.text(_:progress:)` tail-dissolve helper plus `SpaghettifyModifier` ViewModifier (tracking + opacity + vertical collapse). Reduce-motion branch skips animation-specific effects.
- `Sources/GargantuaCore/Views/SmartUninstaller/AccretionDiskView.swift` — `TimelineView(.animation)` + `Canvas` accretion disk with radial amber gradient, rotating lensing arc, and hot core. Rotation rate modulated by `activityRate` (events/sec).
- `Sources/GargantuaCore/Views/SmartUninstaller/SingularityCloseMessage.swift` — pure outcome bucketing (`.success` / `.partial` / `.totalFailure`) + flavor-line helper used by the summary screen.
- `Tests/GargantuaCoreTests/Views/SpaghettifyModifierTests.swift` — 12 tests across text-dissolve behavior and close-message outcomes.

### Modified
- `Sources/GargantuaCore/Views/DesignTokens.swift` — added `GargantuaColors.accretion` as a semantic alias for `review`.
- `Sources/GargantuaCore/Views/SmartUninstaller/EventHorizonConsoleView.swift` — replaced Unicode ring with `AccretionDiskView`, wired spaghettify to successful `.match` events during `.executing`, added 10s time-dilation footer line, introduced phase-boundary tracking so scan-phase matches do not get swallowed as deletion successes.
- `Sources/GargantuaCore/Views/SmartUninstaller/SmartUninstallerView.swift` — reworked `summaryState` with `SIGNAL RECOVERED` heading and outcome-keyed close message above the existing `CleanupSummaryView`.
- `Sources/GargantuaCore/Views/SmartUninstaller/PathStreamViewModel.swift` — added `firstSequence` counter so row identity survives ring-buffer rollover.
- `Tests/GargantuaCoreTests/Views/PathStreamViewModelTests.swift` — tests for `firstSequence` advancement and monotonicity across `clear()`.

### Review fixes (Codex independent pass)
- Stable sequence IDs replaced array-index identity so ring-buffer rollover doesn’t corrupt `swallowedSeqs` or `.task(id:)` re-triggering.
- `.task` closures now respect cancellation via explicit `do/catch` and `Task.isCancelled` checks instead of `try?`.
- Added an `executingBaselineSeq` so `.match` events from the scan phase (which live on in the stream) are not spaghettified as if they were deletion successes.
- Rewrote `tailGrowsMonotonically` test to sample across the middle third and assert the strict monotonic invariant.

### Deferred
- Unicode-ring fallback to `AccretionDiskView` was declined: there is no runtime signal that Canvas rendering is expensive for a 14pt disk at 60fps, so adding a fallback would be speculative dead code. Revisit if a real perf regression shows up.

### Verification
- 449/449 tests passing (+14 new).
- `swift build` clean.
- `swiftlint` clean on all changed files; pre-existing violations elsewhere are untouched.
