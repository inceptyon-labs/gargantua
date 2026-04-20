---
# gargantua-2h7t
title: Opt-in MLX engine end-to-end integration test
status: completed
type: task
priority: normal
created_at: 2026-04-20T19:42:36Z
updated_at: 2026-04-20T19:47:48Z
---

## Context

`gargantua-lyc1` staged the HF model directory and `MLXInferenceEngine` can load/generate from it, but nothing in the project smokes the full chain end-to-end. The existing unit tests stub the engine or the directory — none load the real 680 MB Llama weights and run a real `generate` pass.

## Scope

Add one opt-in integration test, gated on an env var (mirroring the `GARGANTUA_MLX_MODEL_DIR` pattern already in `MLXInferenceEngineTests`), that:

1. Constructs a real `MLXInferenceEngine` + `LocalAIService`.
2. Points it at the user's staged `~/Library/Application Support/Gargantua/models/Llama-3.2-1B-Instruct-4bit/` (via `ModelDownloadManager.defaultModel` or a directly-passed path).
3. Calls `explain(result:rule:)` against a synthetic `ScanResult` / `ScanRule`.
4. Asserts `explanation.source == .ai` and that `explanation.text` is non-trivial (length, word count — not just the YAML fallback string).

Must be skipped by default in CI; only runs when a specific env var is set (e.g. `GARGANTUA_MLX_SMOKE=1`).

## Acceptance

- [x] One new test in `Tests/GargantuaCoreTests/` that follows the `GARGANTUA_MLX_MODEL_DIR` skip pattern.
- [x] Test passes locally when the env var is set and the default model is staged.
- [x] Test is silently skipped when the env var is unset (current CI behavior unchanged).
- [x] Fails loudly (not silently to YAML fallback) if the engine is broken — i.e., asserts `source == .ai`, not just "some string came back".


## Summary of Changes

- New `MLXExplainSmokeTests.swift` — single opt-in test gated on `GARGANTUA_MLX_SMOKE=1`.
- Exercises the real chain: `ModelDownloadManager` → `LocalAIService` → `MLXInferenceEngine` → `explain(result:rule:)` against the staged `mlx-community/Llama-3.2-1B-Instruct-4bit` directory.
- Asserts `source == .ai` (not YAML fallback), text non-empty, ≥ 5 words, and that `unloadModel()` resets lifecycle + memory.
- Passed locally in 4s against the user's staged model.
- Fixed two pre-existing environment-fragile tests in `LocalAIServiceTests` (`fallbackWhenNoModel`, `isModelAvailable`) that assumed `ModelDownloadManager()` is always `.notDownloaded` — they now use a unique unstaged manifest so they don't collide with a real developer-staged default model.
