---
# gargantua-nkoz
title: 'Feature: Dashboard View'
status: in-progress
type: feature
priority: high
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-16T11:06:03Z
updated_at: 2026-04-16T13:57:34Z
---

Compose a dashboard landing screen from existing HealthGaugeView, AlertListView, and SystemMetricCollector. App currently opens to Profiles — should open to a dashboard showing system health, disk usage, and actionable alerts.

## Goals
- Dashboard as default landing view (sidebar item + default selection)
- HealthGaugeView showing live health score from SystemMetricCollector
- AlertListView showing reclaimable space alerts with navigation to cleanup screens
- Quick Scan button triggers MoCleanAdapter scan

## Scope
**In Scope:** Dashboard layout, wiring existing components, SystemMetricCollector integration
**Out of Scope:** New dashboard widgets, historical trend charts
