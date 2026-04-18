---
# gargantua-2v99
title: 'Event Horizon Console: live path-stream for Smart Uninstaller'
status: in-progress
type: feature
priority: high
created_at: 2026-04-18T02:51:59Z
updated_at: 2026-04-18T02:52:13Z
---

## Problem

During Smart Uninstall, users see static text ("Scanning installed apps", "Analyzing {App}", "Uninstalling…") with a non-animated SF Symbol. No feedback that work is happening. Indistinguishable from a hang. See `SmartUninstallerView.swift:76-164`.

## Vision

Replace the three dead phases (`loadingApps`, `scanning`, `executing`) with a themed **Event Horizon Console** — a live monospace terminal that streams real filesystem paths as we inspect them, dressed in the app's Interstellar/Gargantua aesthetic. Real information wearing a good costume.

## Scope

Plumbing + baseline console, no fancy animations yet (those are in follow-up bean).

### Progress event plumbing

- [ ] Define `ScanProgressEvent` (enum or struct) carrying: `path: String`, `outcome: .checked | .match | .skipped | .failed(reason)`, `timestamp: Date`
- [ ] `DefaultAppScanner` emits events via `AsyncStream<ScanProgressEvent>` during `loadApps()` — one event per bundle inspected
- [ ] `RemnantScanner` emits events during `scan(app:)` — one per path probed, marked `.match` when a remnant is found
- [ ] `UninstallExecutor` emits events during execution — one per file removed (`.match` → trash success, `.failed` otherwise)
- [ ] Each emitter also updates a running counter so the header can show `GRAVITY WELL: 2.3 GB · 47 artifacts`
- [ ] Backwards-compatible: existing `async` returns still work; new stream is additive (optional parameter or separate `streamingScan` method)

### Console view

- [ ] New file `Sources/GargantuaCore/Views/SmartUninstaller/EventHorizonConsoleView.swift`
- [ ] Monospace rolling buffer (~200 line cap, drop oldest) with auto-scroll
- [ ] Header block: target app name, gravity well (bytes), TARS humor-setting status line, animated accretion-disk spinner (Unicode ring cycling `◜◠◝◞◡◟`)
- [ ] Phase subtitle:
  - `loadingApps` → *"Surveying nearby star systems"*
  - `scanning(app)` → *"Tracing gravitational echoes from {app}"*
  - `executing` → *"Crossing the event horizon"*
- [ ] Each row: truncate-from-middle for long paths, trailing outcome badge (`✓` checked, `FOUND` match, `✗` failed)
- [ ] Color palette: deep space background (`GargantuaColors.void_` or darker), amber accretion (new token `GargantuaColors.accretion`) for matches, dim ink for checked
- [ ] Footer bar: live stats — `EVENT HORIZON CROSSINGS: {n}` (deletions), `TIDAL FORCES: nominal|anomalous`

### View model

- [ ] New `PathStreamViewModel` (`@Observable` or `ObservableObject`) that:
  - Subscribes to the scanner's `AsyncStream<ScanProgressEvent>`
  - Maintains a ring buffer of ~200 events
  - Publishes aggregate stats (total bytes, match count, failure count)
  - Cancels cleanly when the scan phase ends

### Integration

- [ ] Replace the three `centeredStatus` callers in `SmartUninstallerView.swift` with `EventHorizonConsoleView`
- [ ] Share one console instance across phases so the buffer visibly fills in from loading → scanning → executing (fewer jumps)

## Tests

- [ ] `PathStreamViewModel`: buffer caps at 200 events, oldest drops, stats accumulate correctly
- [ ] Scanner/executor emit at least one event per inspected path (use in-memory fixtures)
- [ ] Event ordering preserved under back-pressure
- [ ] Phase transition doesn't drop events mid-flight

## Non-goals (follow-up bean)

- Spaghettification animation on deletion
- Time-dilation easter egg
- Enhanced accretion disk with gravitational lensing
- Summary screen aesthetic upgrade

## Files

- Sources/GargantuaCore/Services/DefaultAppScanner.swift
- Sources/GargantuaCore/Services/RemnantScanner.swift
- Sources/GargantuaCore/Services/UninstallExecutor.swift
- Sources/GargantuaCore/Views/SmartUninstaller/EventHorizonConsoleView.swift (new)
- Sources/GargantuaCore/Views/SmartUninstaller/PathStreamViewModel.swift (new)
- Sources/GargantuaCore/Views/SmartUninstaller/SmartUninstallerView.swift
- Tests/GargantuaCoreTests/Views/PathStreamViewModelTests.swift (new)
- Tests/GargantuaCoreTests/Services/*ScannerProgressTests.swift (additions)
