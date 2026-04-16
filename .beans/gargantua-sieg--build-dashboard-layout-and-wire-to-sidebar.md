---
# gargantua-sieg
title: Build dashboard layout and wire to sidebar
status: todo
type: task
priority: high
tags:
    - area:frontend
    - pasiv
    - size:M
created_at: 2026-04-16T11:06:11Z
updated_at: 2026-04-16T11:06:11Z
parent: gargantua-nkoz
---

Create DashboardView composing HealthGaugeView + AlertListView. Add 'dashboard' sidebar item to CLEAN section (or as top-level). Set as default selection in MainContentView. Wire SystemMetricCollector for live health score.

## Acceptance Criteria
- [ ] DashboardView exists composing HealthGaugeView and AlertListView
- [ ] 'dashboard' sidebar item added and wired in MainContentView switch
- [ ] Default sidebar selection changed from 'profiles' to 'dashboard'
- [ ] SystemMetricCollector called on appear, health score passed to HealthGaugeView
- [ ] Alert navigation callbacks route to correct sidebar items
