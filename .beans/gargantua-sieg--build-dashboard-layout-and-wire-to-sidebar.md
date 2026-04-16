---
# gargantua-sieg
title: Build dashboard layout and wire to sidebar
status: completed
type: task
priority: high
tags:
    - area:frontend
    - pasiv
    - size:M
created_at: 2026-04-16T11:06:11Z
updated_at: 2026-04-16T14:02:48Z
parent: gargantua-nkoz
---

Create DashboardView composing HealthGaugeView + AlertListView. Add 'dashboard' sidebar item to CLEAN section (or as top-level). Set as default selection in MainContentView. Wire SystemMetricCollector for live health score.

## Acceptance Criteria
- [ ] DashboardView exists composing HealthGaugeView and AlertListView
- [ ] 'dashboard' sidebar item added and wired in MainContentView switch
- [ ] Default sidebar selection changed from 'profiles' to 'dashboard'
- [ ] SystemMetricCollector called on appear, health score passed to HealthGaugeView
- [ ] Alert navigation callbacks route to correct sidebar items

## Summary of Changes

Files changed:
- Sources/GargantuaCore/Views/DashboardView.swift (new)
- Sources/GargantuaCore/Views/SidebarView.swift (added OVERVIEW section with dashboard item)
- Sources/Gargantua/MainContentView.swift (added dashboard case, changed default selection)
- Tests/GargantuaCoreTests/Views/SidebarTests.swift (updated for 5 sections)

Key decisions:
- Dashboard is default landing view (sidebar selection = 'dashboard')
- HealthGaugeView size 140px with 10px stroke for dashboard prominence
- Disk usage bar color-coded: green (<75%), amber (75-90%), red (>90%)
- Alert navigation maps AlertDestination enum to sidebar selection strings
- Quick Scan uses MoCleanAdapter, results aggregated into AlertItems

Notes for next task:
- DashboardView takes @Binding sidebarSelection for cross-view navigation
- Alerts populate via Quick Scan only (no auto-scan on dashboard load yet)
