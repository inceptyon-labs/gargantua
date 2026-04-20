---
# gargantua-xuz6
title: Evaluate and add MLX backend dependency
status: completed
type: task
priority: normal
created_at: 2026-04-20T14:05:34Z
updated_at: 2026-04-20T14:53:13Z
parent: gargantua-ddaa
---

Decide between MLX Swift SPM package and `mlx-lm` subprocess, then wire the
chosen dependency into the build so `MLXInferenceEngine` has something to
call. This Task does *not* implement `load`/`generate` — that's the next
child Task.

## Decide

- **MLX Swift (SPM package)**: in-process, no subprocess overhead, can read
  Metal directly. Adds ~tens of MB of dylib weight plus transitive deps
  (`mlx-swift-examples`, tokenizer). Needs to compile cleanly on release
  builds and not break the macOS release pipeline (see design doc
  docs/designs/2026-04-19-macos-release-pipeline.md).
- **`mlx-lm` subprocess**: out-of-process; uses the existing
  `DefaultProcessRunner` plumbing that's already hardened for
  timeout/SIGTERM/SIGKILL/stdin-pipe behavior. Adds a user-side Python
  dependency (or vendored helper), raises a PATH / TCC question similar
  to the developer-tools resolver pattern.

Write a short design note in `docs/designs/YYYY-MM-DD-mlx-backend.md`
capturing the trade-offs, the choice, and why.

## Do

Once picked:
- Add the dependency to `Package.swift` (SPM) or to `scripts/vendor-helpers`
  (subprocess) so release builds include what they need.
- Verify `swift build` debug + release still succeed.
- Verify the app bundle doesn't balloon past the PRD §7 budget.

## Out of scope

- Implementing `MLXInferenceEngine.load` / `generate` (next Task).
- Model file pinning / download manager changes.

## Acceptance

- [x] `docs/designs/2026-04-20-mlx-backend.md` captures the chosen backend + reasoning
- [x] Build graph includes the dependency; `swift build` release is green
- [x] App bundle size delta measured and recorded in the design doc

## Summary of Changes

Picked MLX Swift (in-process SPM) over `mlx-lm` (Python subprocess) as the production inference backend behind `MLXInferenceEngine`. Wired `ml-explore/mlx-swift-lm` 3.31.3 into `Package.swift` and linked `MLXLLM` + `MLXLMCommon` into `GargantuaCore`. No `load`/`generate` body changes in this bean — that's `gargantua-mgqr`.

### Files

- `docs/designs/2026-04-20-mlx-backend.md` (new) — trade-off table, decision rationale, build-size measurements, intended model pin (`mlx-community/Llama-3.2-1B-Instruct-4bit`), risks + mitigations.
- `Package.swift` — added `mlx-swift-lm` dependency; linked `MLXLLM` + `MLXLMCommon` products into the `GargantuaCore` target.

### Decisions

- **MLX Swift over `mlx-lm` subprocess.** Driven by install UX (no user-side Python), PRD §7 bundle budget (vendoring CPython would add 50–100 MB+), API fit with the `@MainActor` `AIInferenceEngine` protocol, and toolchain consistency (SPM-only project, existing fclones/czkawka vendoring pattern is Rust-binary-shaped, not Python-ecosystem-shaped).
- **`mlx-swift-lm` over older `mlx-swift-examples`.** `mlx-swift-lm` 3.31.3 is the current canonical SPM home for `MLXLLM` / `MLXLMCommon`; `mlx-swift-examples` was for app-shaped example projects.
- **Link both `MLXLLM` and `MLXLMCommon` now.** Could have deferred `MLXLLM` to `mgqr`, but linking both here lets the design doc report honest post-implementation build-size numbers in a single place.
- **Pin via `from: "3.31.3"` (`.upToNextMajor`).** Ordinary default. If upstream churn bites during `mgqr`, tighten to `.exact`.

### Verification

- `swift build -c debug`: green (~47 s cold).
- `swift build -c release`: green (~141–170 s cold).
- `swift build -c debug -Xswiftc -warnings-as-errors`: clean.
- `swift test -c debug --parallel`: 731/731 passing (no regressions).
- SwiftLint: clean on touched files.
- Measured release exec: 9.31 MB → 40.25 MB unstripped; 3.60 MB → 20.65 MB stripped. App bundle with vendored helpers projects to ~54 MB stripped, a few MB over PRD §7's upper bound — filed `gargantua-5vv2` to add a strip step to `Scripts/release/*.sh`.

### Follow-ups filed

- `gargantua-5vv2` — Strip release binaries before codesign (prerequisite for staying under PRD §7 50 MB when shipping MLX).

### Next

- `gargantua-mgqr` — Implement `MLXInferenceEngine.load(modelPath:modelSize:)` / `generate(for:rule:)` against `MLXLMCommon` + `MLXLLM`. Now unblocked by this bean.
