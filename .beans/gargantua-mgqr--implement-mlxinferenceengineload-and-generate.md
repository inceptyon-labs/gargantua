---
# gargantua-mgqr
title: Implement MLXInferenceEngine.load and generate
status: todo
type: task
priority: normal
created_at: 2026-04-20T14:05:44Z
updated_at: 2026-04-20T14:06:00Z
parent: gargantua-ddaa
blocked_by:
    - gargantua-xuz6
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

- [ ] `MLXInferenceEngine.load` succeeds on a pinned model file
- [ ] `generate` returns non-empty text for a real `ScanResult`/`ScanRule`
- [ ] `memoryUsage` reflects resident bytes post-load, back to 0 after
      `unload`
- [ ] `AIInferenceEngineError.notImplemented` no longer thrown by this
      engine (kept only for other potential stubs)
- [ ] Existing `LocalAIServiceTests` still pass; new tests cover the
      load-succeeds-and-generate-returns-text happy path and the
      resident-memory-guard trip
