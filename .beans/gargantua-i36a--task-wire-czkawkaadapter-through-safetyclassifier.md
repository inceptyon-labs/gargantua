---
# gargantua-i36a
title: 'Task: Wire CzkawkaAdapter through SafetyClassifier for composed Phase 2 scans'
status: in-progress
type: task
priority: high
created_at: 2026-04-18T22:18:23Z
updated_at: 2026-04-20T00:24:30Z
parent: gargantua-0q30
blocked_by:
    - gargantua-c6s7
---

Extend SafetyClassifier (or its composition point) so CzkawkaAdapter findings run through the same Trust Layer overrides (age-based, protected paths, etc.) currently applied only at NativeScanAdapter. Child task gargantua-c6s7 notes: 'Czkawka adapter produces base classifications only. Can be added when Phase 2 UI composes multiple adapters.' Reference: Sources/GargantuaCore/Services/SafetyClassifier.swift, CzkawkaAdapter.swift.
