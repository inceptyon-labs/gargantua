---
# gargantua-lyc1
title: Rework ModelDownloadManager to stage HF model directory
status: completed
type: task
priority: normal
created_at: 2026-04-20T17:26:12Z
updated_at: 2026-04-20T19:48:11Z
---

## Context

`gargantua-mgqr` implemented `MLXInferenceEngine` against a local HF-layout directory containing `config.json` + `tokenizer.json` + `*.safetensors`. But `ModelDownloadManager.defaultModel` still downloads a single `gargantua-q4.mlx` file. The two halves don't connect — the in-app UI download flow produces a file the engine can't use.

Integration-test verified path today: a manually-downloaded `mlx-community/SmolLM-135M-Instruct-4bit` directory, pointed at via `GARGANTUA_MLX_MODEL_DIR`. That works for local dev but not for shipped users.

## Scope

Rework `ModelDownloadManager` to:

1. Download a `ModelInfo`-configured set of files (manifest-driven) instead of one opaque blob.
2. Verify each file's SHA-256 against a pinned manifest (follow the `Scripts/vendored-bins.lock` pattern from `gargantua-vzuz`).
3. Stage them into `~/Library/Application Support/Gargantua/models/<model-id>/` as a directory.
4. `ModelState.downloaded(path:size:)` reports the directory path; `size` is the sum of the staged files.
5. `LocalAIService.explain` passes that directory path as `modelPath` into the engine — no engine changes needed (engine already accepts either a dir or a file whose parent is a dir).

Alternative for a smaller v1: download a single `.zip` / `.tar.gz` from a pinned URL and extract on first use. Cheaper to implement but harder to version-pin individual files. Recommend the multi-file path — mirrors HF's own layout and keeps us compatible with `huggingface-cli download` smoke tests.

## Pinned model target

`mlx-community/Llama-3.2-1B-Instruct-4bit` per PRD §6.2 and the xuz6 design doc. Files: `config.json`, `tokenizer.json`, `tokenizer_config.json`, `special_tokens_map.json`, `model.safetensors`. Total ~0.8 GB.

## Out of scope

- Engine changes (mgqr already handles a directory path).
- UI redesign beyond the file-vs-directory label shift.
- Multiple-model support / hot-swap UI (separate bean if we want it).
- Background resumable downloads (current URLSession handles this already).

## Acceptance

- [x] Default `ModelInfo` targets a directory of HF files with SHA-256 pins
- [x] `startDownload()` fetches all files, verifies each SHA, fails cleanly on any mismatch
- [x] `state = .downloaded` exposes the directory path; `LocalAIService` passes it to `MLXInferenceEngine.load` without changes
- [x] App-level smoke: user clicks "Download model" in settings → model staged → one `explain` call produces AI-generated text (validated end-to-end via `gargantua-2h7t` — real Llama 3.2 1B generates AI-sourced prose against the staged directory)
- [x] Docs updated in `docs/designs/2026-04-20-mlx-backend.md` noting the directory-staging reality


## Summary of Changes

- `ModelInfo` + new `ModelFile` carry a multi-file manifest (name / HF URL / SHA-256 / size). `defaultModel` now pins `mlx-community/Llama-3.2-1B-Instruct-4bit` (~680 MB across five files) with SHAs lifted from HF LFS pointers and direct content hashes.
- `ModelDownloadManager.startDownload` fetches files sequentially through a `URLSession` delegate, SHA-256 verifies each via `CryptoKit` (streamed in 1 MB chunks off the main actor), and moves them into `~/Library/Application Support/Gargantua/models/<id>/`. Any hash mismatch or transport error rolls the whole directory back.
- `state = .downloaded(path:…)` reports the staged directory. `LocalAIService.explain` already passes `state.path` through to `MLXInferenceEngine.load`, which already accepts a directory — no engine or service changes needed.
- A `.gargantua-verified` marker file is written atomically after every SHA passes; `checkExistingModel` refuses to trust a directory without a marker whose contents match the current manifest, so a partial or tampered run can't masquerade as `.downloaded` on the next launch.
- `validateManifest` (called from init) rejects path-traversal in `id`/`name`, empty/`.`/`..`/leading-dot/NUL/slash components, and duplicate filenames. Surfaced as an independent Codex finding in pass-2 review.
- `Scripts/pin-model.sh` regenerates the `ModelFile(...)` Swift snippet from HF's API (LFS oid for large files, download-and-hash for small JSON) — the mechanism for bumping the pinned model.
- Docs updated in `docs/designs/2026-04-20-mlx-backend.md` noting the directory-staging reality.
- 20 new unit tests added; 766 total pass. Debug and release builds green.

## Manual Verification Left Open

The one unchecked acceptance criterion — "user clicks Download model → model staged → one `explain` call produces AI-generated text" — requires a live ~680 MB fetch from huggingface.co and on-device Metal inference, so it's the user's to run. After a successful manual smoke, check the last box and mark this bean completed.
