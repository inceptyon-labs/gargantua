---
# gargantua-v0sa
title: 'Feature: Live progress indication during Deep Clean scan'
status: in-progress
type: feature
priority: high
created_at: 2026-04-17T12:16:05Z
updated_at: 2026-04-17T12:22:29Z
---

## Problem

During Deep Clean scans, the UI reads as frozen: `DeepCleanView.scanFooter` shows only an indeterminate spinner + category name. `ScanProgress` already exposes `fractionCompleted` and `itemsFound`, but nothing renders them. Each rule's `evaluate()` runs in one `Task.detached` that recursively walks dirs — a rule like `User Library Caches` can sit on the same category name for 20+ seconds with fraction unchanged.

User report (2026-04-17): "when it is 'deep scanning' there isnt really any indication that it is doing anything, it sits there and then bam all the results pop up".

## Scope

Render the existing `ScanProgress` state that's already being emitted, plus add sub-status emission during the expensive `directorySize` walks so each rule shows motion.

## Tasks

- [x] Replace indeterminate `ProgressView()` in `DeepCleanView.scanFooter` with determinate progress bar bound to `scanProgress.fractionCompleted`
- [x] Show `itemsFound` running count in footer
- [x] Show running reclaimable-bytes total (sum of sizes collected so far) — requires surfacing running size via `ScanProgress` (new field or keep in view state)
- [x] Prettify `currentCategory` display (e.g. "browser_cache" → "Browser Cache") — it's already shown but is raw snake_case
- [x] Emit sub-status for the big `directorySize` walks so the UI updates mid-rule. Simplest: have `NativeScanAdapter.evaluate` call back to `ScanProgress` with the current path being sized. Requires `directorySize` to accept a progress callback or (simpler) emit before the call with the path about to be walked.
- [ ] Smoke test: run a deep scan, confirm footer updates continuously and no single category sits silently for >5s

## Non-goals

- Cancellation UI (separate concern, can reuse `gargantua-evdi`)
- Streaming results into the list as they arrive (nice-to-have, out of scope)

## Files

- `Sources/GargantuaCore/Views/DeepCleanView.swift` — footer UI
- `Sources/GargantuaCore/Models/ScanProgress.swift` — possibly extend
- `Sources/GargantuaCore/Services/NativeScanAdapter.swift` — emit sub-status
