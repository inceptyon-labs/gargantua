---
# gargantua-2xt6
title: Cleanup Summary narrative via AI (YAML fallback)
status: completed
type: task
priority: normal
created_at: 2026-04-20T14:06:36Z
updated_at: 2026-04-20T23:50:20Z
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

## Summary of Changes

**Files added:**
- Sources/GargantuaCore/Models/CleanupNarrative.swift — CleanupNarrative model, CleanupNarrator env key, and CleanupNarrativeTemplate
- Sources/GargantuaCore/Views/CleanupNarrativeSection.swift — AI-attributed narrative row view
- Tests/GargantuaCoreTests/Services/CleanupNarrativeTests.swift — template, service, PII, and fallback tests

**Files modified:**
- AIInferenceEngine.swift — narrate(cleanup:) protocol method + template default impl
- AIServiceProtocol.swift — non-throwing narrate(cleanup:)
- LocalAIService.swift — narrate with fallback on no-model / load-fail / engine-fail / empty-output
- MLXInferenceEngine.swift — aggregated-only prompt + sanitizeForPrompt to defuse filename-based prompt injection
- CleanupSummaryView.swift — narrative section + cancellation-aware .task
- MainContentView.swift — wires narrator via .environment(\.cleanupNarrator)
- MLXInferenceEngineTests.swift — cleanup-prompt + sanitizer tests

**Key decisions:**
- Narrator exposed via SwiftUI environment value (not direct parameter) so existing call sites stay unchanged.
- Display-only CleanupNarrative carries source (.ai vs .rule) so UI can label the panel correctly.
- MLX prompt sees only aggregated counts/bytes/names, no per-file paths or error strings.
- Singleton groups (count == 1) are suppressed in template prose to tighten the PII surface.
- Empty / whitespace-only engine output falls back to template so the block never renders empty.
- .task(id:) gated on Task.isCancelled so late responses from cancelled narrators can't overwrite newer results.

**Review:** SC (Sonnet → Codex) cascading review. Sonnet flagged a stale-narrative guard in .task; Codex flagged empty-output acceptance, late-task overwrite, singleton PII, and prompt-injection via filename. All addressed.

**Tests:** 818/818 passing.
