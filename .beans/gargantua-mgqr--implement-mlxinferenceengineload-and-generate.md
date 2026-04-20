---
# gargantua-mgqr
title: Implement MLXInferenceEngine.load and generate
status: completed
type: task
priority: normal
created_at: 2026-04-20T14:05:44Z
updated_at: 2026-04-20T17:24:52Z
parent: gargantua-ddaa
blocked_by:
    - gargantua-xuz6
    - gargantua-8fjo
---

Replace the `.notImplemented` stubs in `MLXInferenceEngine.swift` with real
model loading and text generation against the backend chosen in the
preceding Task (see parent Feature `gargantua-ddaa`).

## Scope

- `load(modelPath: String, modelSize: Int64) async throws`: load weights
  from the on-disk file staged by `ModelDownloadManager`, populate
  `isLoaded`, and set `memoryUsage` to the actual resident bytes (not
  on-disk size — `LocalAIService` already checks this against the 3 GB
  RAM guard post-load).
- `generate(for result: ScanResult, rule: ScanRule) async throws -> String`:
  build a prompt from the result/rule, run inference, return text.
- `unload()`: release all model state; `memoryUsage` back to 0.
- Prompt template lives with the engine; `LocalAIService` still labels
  output as `.ai` and falls back to the YAML rule on generation errors
  (advisory-only per PRD §2.5).

## Out of scope

- Model-file pinning / download-manager changes.
- Engine selection UI.
- Latency/perf smoke tests (separate Task).

## Acceptance

- [x] `MLXInferenceEngine.load` succeeds on a real model directory (verified with `mlx-community/SmolLM-135M-Instruct-4bit`)
- [x] `generate` returns non-empty text for a real `ScanResult`/`ScanRule` (integration test passes in 2.86 s on SmolLM-135M)
- [x] `memoryUsage` reflects resident bytes post-load (via `MLX.Memory.activeMemory` delta), back to 0 after `unload()`
- [x] `AIInferenceEngineError.notImplemented` no longer thrown; engine-specific errors live on `MLXInferenceError` (`.modelPathIsNotDirectory`, `.modelDirectoryIncomplete`, `.notLoaded`, `.emptyPrompt`). `notImplemented` remains for any future stub engines
- [x] Existing `LocalAIServiceTests` still pass (updated two .notImplemented tests to match new engine behavior). 14 new `MLXInferenceEngineTests` cover prompt building, path resolution, directory validation, and unloaded-engine lifecycle. Env-gated integration test covers the load + generate + unload happy path; verified against SmolLM-135M

## WIP checkpoint (2026-04-20)

Load/generate/unload wired against `LLMModelFactory.shared.loadContainer(from: URL, using: SwiftTransformersTokenizerLoader)`. Added `swift-transformers` 1.3.0 dep and a local `SwiftTransformersTokenizerLoader` that wraps `Tokenizers.AutoTokenizer.from(modelFolder:)` — cleaner than pulling `MLXHuggingFace`, which requires the macro package. Memory accounting uses `MLX.Memory.activeMemory` delta across load.

14 unit tests (prompt builder, path/directory validation, lifecycle) plus one env-gated integration test at `GARGANTUA_MLX_MODEL_DIR`. All non-integration tests pass.

Discovered during implementation that `swift build` CLI does not compile `.metal` files, so the resulting binary fails at runtime with "Failed to load the default metallib". Filed `gargantua-8fjo` as a blocker — once that lands, this bean can close by running the integration test against a real model directory.

Code on branch `gargantua-mgqr`; do not merge until 8fjo is on main.

## Summary of Changes

Replaced the `MLXInferenceEngine` stub with a real load/generate/unload implementation backed by `LLMModelFactory.shared` from `mlx-swift-lm`. End-to-end verified on `mlx-community/SmolLM-135M-Instruct-4bit` — `Scripts/test.sh` with `GARGANTUA_MLX_MODEL_DIR` set passes the integration test in 2.86 s.

### Files

- `Sources/GargantuaCore/Services/MLXInferenceEngine.swift` — real `load` (resolves directory, validates HF layout, loads via `LLMModelFactory`), `generate` (builds a structured prompt, runs through `ChatSession.respond`), `unload` (clears MLX cache, resets state). Memory accounting via `MLX.Memory.activeMemory` delta across load.
- `Sources/GargantuaCore/Services/SwiftTransformersTokenizerLoader.swift` (new) — bridge from `Tokenizers.AutoTokenizer` (swift-transformers) to `MLXLMCommon.Tokenizer`. Mirrors the shape of `MLXHuggingFace`'s `#adaptHuggingFaceTokenizer` macro without pulling the macro package.
- `Sources/GargantuaCore/Services/MLXInferenceError.swift` (inlined into the engine file) — new error enum for engine-domain failures.
- `Package.swift` — added `huggingface/swift-transformers` 1.3.0 and linked `Tokenizers` to `GargantuaCore`.
- `Tests/GargantuaCoreTests/Services/MLXInferenceEngineTests.swift` (new, 15 tests) — prompt builder, path resolution, directory validation, unloaded-engine lifecycle, env-gated integration test (`GARGANTUA_MLX_MODEL_DIR`).
- `Tests/GargantuaCoreTests/Services/LocalAIServiceTests.swift` — replaced the two `AIInferenceEngineError.notImplemented` assertion tests with assertions on the new `MLXInferenceError` surface.

### Decisions

- **Direct dep on `swift-transformers` over `MLXHuggingFace`.** `MLXHuggingFace` re-exports tokenizer loading through a macro that expects a `HubClient`. We only need local-directory tokenizer loading (`ModelDownloadManager` stages the files), so wrapping `AutoTokenizer.from(modelFolder:)` directly is cleaner and avoids pulling `swift-huggingface`'s hub client. Amends the "no additional deps beyond what xuz6 linked" stance from that bean's doc — noted there.
- **`modelPath` accepts a directory OR a file.** `ModelDownloadManager` currently stages a single file; MLX LM expects a directory. The engine resolves a file path to its parent directory so the boundary fits both shapes. When the download manager grows to stage a full HF directory (out of scope; separate follow-up), the engine's contract doesn't change.
- **Directory validation runs before MLX init.** `load` calls `validateModelDirectory` (pure FS checks) before touching `MLX.Memory.activeMemory`. Keeps the non-happy-path cases fast and test-friendly.
- **`unload()` is a no-op when nothing was loaded.** `MLX.Memory.clearCache()` forces Metal device init, which is unnecessary if we never loaded weights. Guarding also kept tests green during the 8fjo window when metallib wasn't yet colocated; defensive even now.
- **Prompt shape.** Structured metadata (item, path, category, source, size, safety, regenerates, rule explanation) followed by an explicit "explain what this is and whether it is safe to delete" directive. System instructions enforce plain-English, no-markdown, 2–4 sentences. Pure function so tests can pin the shape without a model.
- **Generation parameters.** `maxNewTokens: 180` (~3–5 sentences), `temperature: 0.3` (stable advisory text). Exposed as init params so callers can override.

### Verification

- `Scripts/test.sh`: 746/746 passing (up from 731; added 15 MLX tests, replaced 2 notImplemented tests).
- Integration test: `GARGANTUA_MLX_MODEL_DIR=~/models/SmolLM-135M-Instruct-4bit Scripts/test.sh --filter "Integration: load + generate"` → passes in 2.86 s, exercising the full `load → generate → unload` cycle end-to-end.
- `swift build -c debug -Xswiftc -warnings-as-errors`: clean.
- `swift build -c release`: green.
- No linter warnings on touched files.

### Follow-ups

- **`ModelDownloadManager` directory rework** — the default model config downloads a single `gargantua-q4.mlx` file, which no longer matches what the engine expects. File a standalone bean ("Rework ModelDownloadManager to stage HF model directory") so the in-app download flow produces something the engine can consume.
- **`gargantua-7k2r`** (already filed) — latency/memory smoke tests on a production-sized model (Llama 3.2 1B). This bean verifies correctness on SmolLM-135M; 7k2r quantifies performance.
- **Settings engine toggle (`gargantua-6xce`)** — now unblocked; it can switch between `TemplateInferenceEngine` and `MLXInferenceEngine` at runtime.
