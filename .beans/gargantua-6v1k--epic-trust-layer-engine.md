---
# gargantua-6v1k
title: 'Epic: Trust Layer Engine'
status: in-progress
type: epic
priority: critical
tags:
    - area:backend
    - pasiv
created_at: 2026-04-15T00:44:21Z
updated_at: 2026-04-15T11:11:05Z
---

The safety classification system, YAML rule parser, and audit trail. This is the foundational architecture — the PRD calls it "not a feature, an architectural decision that permeates every scan result."

## Vision
Every item surfaced by any scan receives a SafetyLevel (safe/review/protected) with explainability, confidence scoring, and full audit trail. YAML rules are the sole authority — AI can never change a classification.

## Features
- YAML scan rule schema with safety metadata, confidence, explanations
- Rule parser and file organization (system/, browser/, developer/, apps/)
- SafetyLevel classification with profile-aware overrides
- Audit trail (JSON log, Trash-based undo, 90-day retention)

## Success Criteria
- [ ] YAML rules parse correctly with all Trust Layer fields
- [ ] Safety classification produces correct safe/review/protected levels
- [ ] Profile overrides correctly reclassify stale items
- [ ] Audit log captures every destructive operation with full metadata
- [ ] Undo via Trash works for recent operations
