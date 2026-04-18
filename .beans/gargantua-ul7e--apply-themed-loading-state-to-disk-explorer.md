---
# gargantua-ul7e
title: Apply themed loading state to Disk Explorer
status: completed
type: feature
priority: normal
created_at: 2026-04-18T14:25:55Z
updated_at: 2026-04-18T15:34:29Z
parent: gargantua-6383
---

Disk Explorer doesn't have a scan/clean lifecycle — it's interactive directory navigation with on-demand sizing. Apply lighter theming:

- Cosmic vocabulary on the loading state (e.g. "Probing gravitational pull at $path…", spinning AccretionDisk indicator).
- Match Smart Uninstaller's full-screen `ZStack { void_.ignoresSafeArea(); ... }` wrapper.
- Use the same loading/empty/permission-denied messaging tone.

## Tasks

- [x] Replace the small `ProgressView` in the header with an `AccretionDiskView` (or similar) for visible activity during slow drilldowns.
- [x] Apply cosmic-tinted empty state when a directory is empty.
- [x] Match Smart Uninstaller wrapper pattern.
- [x] Verify it doesn't regress the size bar / breadcrumb interactions.

## Summary of Changes

- Wrapped DiskExplorerView body in a ZStack with GargantuaColors.void_.ignoresSafeArea() — matches the SmartUninstaller / Deep Clean / Dev Purge wrapper.
- Replaced the small system ProgressView in the header with an AccretionDiskView (size 14, accretion-amber) plus an italic 'Probing gravitational pull…' subtitle when isLoading is true, so directory drilldowns show consistent cosmic activity.
- Added an emptyState that renders when the load completes with no items: a low-opacity 28pt accretion disk + 'Empty orbit' / 'No bodies detected at this radius.' copy.

## Verification

- swift build clean.
- Full test suite: 452/452 passing.
