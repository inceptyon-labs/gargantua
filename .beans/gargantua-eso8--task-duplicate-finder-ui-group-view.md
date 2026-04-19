---
# gargantua-eso8
title: 'Task: Duplicate Finder UI (group view)'
status: in-progress
type: task
priority: high
created_at: 2026-04-18T22:18:18Z
updated_at: 2026-04-19T02:12:38Z
parent: gargantua-4nb9
---

Build the Duplicate Finder UI surface: duplicate-group list, per-group file rows with short hash + size, review-by-default selection model, reclaimable bytes per group and total, action to send selected to trash. Must not execute destructive ops until Trust Layer confirmation flow is in place. Reference: Sources/GargantuaCore/Views/, FclonesAdapter.swift ScanResult output.
