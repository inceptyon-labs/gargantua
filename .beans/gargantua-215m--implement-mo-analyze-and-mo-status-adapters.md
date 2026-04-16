---
# gargantua-215m
title: Implement mo analyze and mo status adapters
status: completed
type: task
priority: normal
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:48:07Z
updated_at: 2026-04-16T01:06:22Z
parent: gargantua-jj6r
---

mo analyze for Disk Explorer, mo status --json for system metrics (health score inputs).

## Acceptance Criteria
- [x] mo analyze output mapped to disk usage tree structure
- [x] mo status --json provides CPU, memory, disk, temperature metrics
- [x] Both adapters handle timeout and partial output gracefully

---
**Size:** M

## Summary of Changes

Files changed:
- Sources/GargantuaCore/Services/MoAnalyzeAdapter.swift (new)
- Sources/GargantuaCore/Services/MoStatusAdapter.swift (new)
- Tests/GargantuaCoreTests/Services/MoAnalyzeAdapterTests.swift (new)
- Tests/GargantuaCoreTests/Services/MoStatusAdapterTests.swift (new)

Key decisions:
- Used JSONSerialization (untyped) matching SystemMetricCollector's existing pattern
- CPU percentage (0-100) from mo status converted to 0.0-1.0 fraction for SystemMetrics
- Recursive convertEntry for tree parsing with nil children for leaf nodes
- Partial output handling: missing fields default to 0/nominal/false

Notes for follow-up:
- MoAnalyzeAdapter.analyze(path:depth:) returns [DirectoryItem] for Disk Explorer
- MoStatusAdapter.status() returns SystemMetrics for health gauge
- Both use MoleRunner with timeout support inherited from MoleRunnerConfig
