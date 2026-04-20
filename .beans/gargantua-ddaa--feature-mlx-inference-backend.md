---
# gargantua-ddaa
title: 'Feature: MLX inference backend'
status: todo
type: feature
priority: normal
created_at: 2026-04-20T14:05:12Z
updated_at: 2026-04-20T14:05:12Z
parent: gargantua-qe4a
blocking:
    - gargantua-8igf
---

Replace the `MLXInferenceEngine` stub (throws `.notImplemented`) with a real
on-device LLM inference backend so Tier 1 AI explanations are genuinely
generated rather than deterministic template text.

Context: `gargantua-eily` established the `AIInferenceEngine` boundary and
wired `LocalAIService` to delegate. `MLXInferenceEngine.swift` is a stub.
This Feature is the production inference dependency that `gargantua-8igf`
("AI Tier 1 production improvements") needs before its advisory use cases
are worth building out in anger.

## Scope

- Pick the concrete backend: MLX Swift SPM package vs `mlx-lm` subprocess.
  Trade-off is bundle size / build complexity vs. subprocess overhead and
  launchd/PATH issues on user machines.
- Pin a quantized sub-3B model compatible with the choice above (PRD §6.2
  suggests 4-bit Llama 3.2 1B or 3B).
- Wire `MLXInferenceEngine.load(modelPath:modelSize:)` / `generate(for:rule:)`
  against the chosen backend. Must honor the existing `LocalAIService`
  contract: `memoryUsage` reflects resident bytes post-load, `unload()`
  releases all weights, and `generate` respects the 60s idle timer that's
  suspended during in-flight inference.

## Out of scope

- Engine selection UI / Settings toggle (`gargantua-8igf` child Task).
- LoRA fine-tuning (PRD §6.2 "Phase 2+").
- Tier 2 (Claude API) and Tier 3 (Claude Code agent) work.

## Done when

- Real inference runs on device with the chosen backend.
- `swift build` stays within the stated app bundle budget (PRD §7: ~35–50 MB
  without bundled models).
- Latency / token-count budget documented and smoke-tested.
- `AIInferenceEngineError.notImplemented` removed.
