---
# gargantua-0zll
title: 'Feature: Wire Deep Clean & Dev Purge'
status: in-progress
type: feature
priority: high
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-16T11:06:19Z
updated_at: 2026-04-16T12:39:21Z
---

Wire the two unwired sidebar items. DevArtifactScanView already exists for devPurge. Deep Clean needs a new view using MoCleanAdapter + ScanBucketListView.

## Goals
- deepClean sidebar item navigates to a functional scan view
- devPurge sidebar item navigates to DevArtifactScanView
- Both flows use the three-bucket pattern (ScanBucketListView)

## Scope
**In Scope:** DeepCleanView, wiring devPurge to DevArtifactScanView, MoleRunner instantiation
**Out of Scope:** Cleanup execution (separate feature), confirmation modals
