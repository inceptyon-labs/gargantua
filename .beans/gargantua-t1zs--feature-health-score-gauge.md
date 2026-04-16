---
# gargantua-t1zs
title: 'Feature: Health Score Gauge'
status: completed
type: feature
priority: high
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-15T00:45:58Z
updated_at: 2026-04-16T01:40:44Z
parent: gargantua-qne2
---

The anchor element. 0-100 gauge derived from CPU, memory, disk, and temperature metrics.

## Goals
- [x] Immediately communicates system health on app open
- [x] Score is meaningful: 95-100 = healthy (green tint), sub-50 = attention needed
- [x] Real-time updates when dashboard is visible

## Scope
**In Scope:** Gauge visualization, metric collection via sysctl/IOKit/mo status, score calculation algorithm, healthy/degraded states
**Out of Scope:** Trends over time (sparklines are dashboard v2)



---
**Completed:** All sub-issues completed
