---
# gargantua-eily
title: 'Task: Replace LocalAIService placeholder with real inference boundary'
status: completed
type: task
priority: normal
created_at: 2026-04-17T18:07:39Z
updated_at: 2026-04-18T02:20:51Z
parent: gargantua-8igf
---

LocalAIService currently lazy-loads model bytes and returns structured/rule fallback text. Define and implement the real MLX or mlx-lm inference boundary, keeping fallback behavior and idle unload semantics.

## Summary of Changes

Extracted a pluggable `AIInferenceEngine` boundary so real MLX/`mlx-lm` inference can slot into `LocalAIService` without touching lifecycle, fallback, or idle-unload code.

### Files
- `Sources/GargantuaCore/Services/AIInferenceEngine.swift` (new) — protocol + `AIInferenceEngineError`
- `Sources/GargantuaCore/Services/TemplateInferenceEngine.swift` (new) — default deterministic engine, preserves prior placeholder behavior
- `Sources/GargantuaCore/Services/MLXInferenceEngine.swift` (new) — stub that throws `notImplemented` until MLX dependency lands
- `Sources/GargantuaCore/Services/LocalAIService.swift` — delegates load/unload/generate to injected engine; adds in-flight inference tracking so idle timer cannot fire mid-generate; adds post-load resident-memory guard (handles engines that expand weights beyond on-disk size)
- `Sources/GargantuaCore/Services/ModelDownloadManager.swift` — internal `_setStateForTesting` seam
- `Tests/GargantuaCoreTests/Services/LocalAIServiceTests.swift` — 9 new tests covering engine injection, generate-failure fallback, load-failure wrapping, idle-timer suspension during inference, resident-memory guard, and MLX stub contract

### Decisions
- `LocalAIService` still owns lifecycle + YAML fallback; engine owns weights + prompting. Swapping engines never changes the caller.
- Generate errors fall back to YAML rule text (advisory-only per PRD §6.2), load errors still throw `AIServiceError.loadFailed`.
- 3 GB RAM guard is now checked against `engine.memoryUsage` after load, not just on-disk size.

### Verification
- `swift test` → 422/422 passing (was 413)
- `swift build` debug + release clean
- SC review: Sonnet pass 1 clean; Codex pass 2 flagged idle-timer-during-inference race and file-size-only RAM guard — both fixed, followup tests added.
