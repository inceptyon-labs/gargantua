---
# gargantua-pb19
title: 'Gargantua singularity polish: spaghettification + accretion + summary'
status: todo
type: feature
priority: normal
created_at: 2026-04-18T02:52:03Z
updated_at: 2026-04-18T02:52:03Z
blocked_by:
    - gargantua-2v99
---

## Problem

The Event Horizon Console (bean gargantua-X) gives real info in a good costume, but the "executing" phase still feels like a list clearing itself. The theming is under-exploited. People should screenshot this.

## Scope

Polish pass on top of the console from bean #1. Pure visual/UX layer — no new plumbing.

### Spaghettification on delete

- [ ] During the `executing` phase, each successfully deleted path animates out with a stretch-and-swallow effect (~400ms):
  1. Line's characters fan out with increasing kerning
  2. Trailing 6-10 characters dissolve into periods and dots (`→ · . . ·  ⊙`)
  3. Whole line fades to 0 and collapses vertically
- [ ] Failed deletions do NOT spaghettify — they stay with a red `✗` and `TIDAL FORCES: anomalous` appears in the footer
- [ ] Animation is `reduceMotion`-aware; honors `NSApp.effectiveAppearance` reduce motion

### Accretion disk polish

- [ ] Upgrade the spinner from Unicode ring to a small SwiftUI Canvas drawing an accretion disk with subtle gravitational-lensing arc
- [ ] Amber (`GargantuaColors.accretion`) with a warm core; rotation tied to activity rate (faster when events are streaming, slowing when idle)
- [ ] Maintain a fallback to the Unicode ring if Canvas rendering is expensive

### Time-dilation easter egg

- [ ] If the scan exceeds 10s wall time, fade in a single italic footer line:
  *`Δt: 7 minutes per second on Miller's planet`*
- [ ] Only appears once per session; stays until the phase exits
- [ ] Purely decorative — zero behavioral impact

### Summary screen upgrade

- [ ] Rework `SmartUninstallerView.summaryState` to match the console aesthetic
- [ ] Show `SIGNAL RECOVERED` heading over the existing `CleanupSummaryView`
- [ ] Add a one-line close message sampled from a small pool keyed to success vs partial-failure:
  - Success: *"{n} artifacts lost to Gargantua. Mass recovered: {size}."*
  - Partial: *"{n} artifacts lost to Gargantua. {m} resisted tidal forces."*
  - Total fail: *"Signal lost. All artifacts still bound."*
- [ ] Keep the existing action button (`Done`) as-is

## Tests

- [ ] Spaghettification animation triggered once per deletion, not on check-only events
- [ ] Reduce-motion accessibility: animation collapses to instant-disappear
- [ ] Time-dilation line appears only after 10s elapsed, only once

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
