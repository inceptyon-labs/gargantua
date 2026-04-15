---
# gargantua-aek3
title: 'Epic: Scan & Clean Views'
status: todo
type: epic
priority: high
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-15T00:44:42Z
updated_at: 2026-04-15T00:44:42Z
---

The core scan-review-act flow: Deep Clean, Dev Artifact Purge, and Disk Explorer. Three screens sharing the same three-bucket pattern but with distinct data sources.

## Vision
Dense, information-rich scan results. File paths, sizes, confidence orbits, explanations — all visible. Developers want the data. The Scan → Preview → Act flow is universal across all scan screens.

## Features
- Three-bucket scan results (Safe/Review/Protected)
- Dense item rows with confidence orbit signature element
- Clean execution with confirmation modal and Trash
- Dev Artifact Purge (Mole mo purge + profile overrides)
- Disk Explorer (sorted expandable list with size bars)

## Success Criteria
- [ ] Three-bucket split correctly separates items by safety level
- [ ] Item rows show name, size, path, confidence, explanation
- [ ] Confirmation modal lists exact items and total size
- [ ] Post-clean summary shows freed space and audit link
- [ ] Disk Explorer progressively loads and drills down
