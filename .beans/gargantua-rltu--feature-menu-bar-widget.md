---
# gargantua-rltu
title: 'Feature: Menu bar widget'
status: todo
type: feature
priority: low
created_at: 2026-04-23T20:55:06Z
updated_at: 2026-04-23T20:55:06Z
---

Add a menu bar widget for at-a-glance status and quick actions. Phase 3 nice-to-have from PRD §10.

## Context

PRD §10 lists a menu bar widget as Phase 3 polish: quick access to the app, actionable alerts (e.g., "reclaimable: 12 GB"), one-click scan.

## Requirements

- `NSStatusItem`-based menu bar extra, not a full Window-group app
- Launch-at-login toggle in Settings (uses SMAppService)
- Shows: last-scan summary, reclaimable size, pending alerts count
- Actions: open main window, run quick scan, snooze alerts
- Icon respects Dark/Light/Reduced-transparency modes

## Todo

- [ ] MenuBarExtra SwiftUI scene with compact view
- [ ] Observable connecting to scan service + alert store
- [ ] Launch-at-login via SMAppService
- [ ] Icon asset set (template icon for monochrome menu bar)
- [ ] Settings toggle to enable/disable entirely
- [ ] Accessibility labels + VoiceOver behavior
