---
# gargantua-2xt6
title: Cleanup Summary narrative via AI (YAML fallback)
status: completed
type: task
priority: normal
created_at: 2026-04-20T14:06:36Z
updated_at: 2026-04-20T23:48:59Z
parent: gargantua-8igf
---

Post-cleanup narrative from PRD §6.2: "Cleaned 23 GB: Chrome cache (10 GB),
Xcode sims (8 GB)…". Today the summary is strictly structured UI; this
Task adds an AI-generated narrative row that sits alongside the existing
card data.

## Scope

- Take a `CleanupResult` and ask the current `AIInferenceEngine` for a
  short narrative (1–2 sentences) describing what was cleaned and any
  notable groupings.
- Render the narrative in `CleanupSummaryView` as a new, clearly-attributed
  "AI" block — not a replacement for the succeeded/failed item lists.
- Fall back to a deterministic template when no model is available or
  the engine fails (same pattern as `explain`).

## Out of scope

- Natural-language cleanup *planning* (that's Tier 2, Claude API).
- Audit-trail changes; the narrative is display-only and is not persisted
  with the audit record.

## Acceptance

- [x] AI narrative renders when a model is available and engine succeeds
- [x] Template/YAML-style narrative renders when not (no empty block,
      no error banner)
- [x] Test: narrative never contains PII beyond what `CleanupResult`
      already exposes (e.g., no raw file contents)
