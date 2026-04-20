# MLX Backend Dependency

**Date:** 2026-04-20
**Status:** Accepted
**Bean:** `gargantua-xuz6` (wires the dep; `gargantua-mgqr` implements `load`/`generate`)

## Summary

Pick MLX Swift (in-process SPM) over `mlx-lm` (Python subprocess) as the production inference backend behind `MLXInferenceEngine`. Add `ml-explore/mlx-swift-lm` to `Package.swift` and link `MLXLLM` + `MLXLMCommon` into `GargantuaCore`. No `load`/`generate` wiring in this bean — that's the next child Task.

## Context

`gargantua-eily` landed the `AIInferenceEngine` boundary (protocol + `TemplateInferenceEngine` default + `MLXInferenceEngine` stub that throws `.notImplemented`). The boundary is `@MainActor`, exposes `load(modelPath:modelSize:)` / `unload()` / `generate(for:rule:)` / `memoryUsage: Int64`, and sits inside `LocalAIService` which already handles lifecycle, idle-unload, YAML-rule fallback on engine errors, and a 3 GB RAM guard against `engine.memoryUsage`.

The two production-inference paths the bean lists as candidates:

- **MLX Swift (SPM)** — in-process. `ml-explore/mlx-swift-lm` re-exports `MLXLLM` / `MLXLMCommon` over `ml-explore/mlx-swift`. Direct Metal.
- **`mlx-lm` (Python subprocess)** — spawn `python3 -m mlx_lm.generate …` via the existing `DefaultProcessRunner` (hardened for timeout/SIGTERM/SIGKILL/stdin-pipe; already runs `fclones` and `czkawka_cli`).

## Decision

**MLX Swift (in-process) via `ml-explore/mlx-swift-lm` v3.31.3.**

### Trade-off

| Axis | MLX Swift (SPM) | `mlx-lm` subprocess |
|---|---|---|
| Install UX | Nothing extra; comes with the DMG | User-installed Python OR vendor CPython (~50–100 MB + many dylibs) |
| Bundle budget (PRD §7: 35–50 MB) | +~5–15 MB of Swift dylibs in the binary | Blown if we vendor Python; otherwise external dep |
| API boundary fit | `@MainActor` Swift; `memoryUsage`/`unload()` are direct | Need to wrap subprocess lifecycle + RSS polling |
| Toolchain consistency | Native SPM; mirrors existing `Yams` dep | New vendoring pattern (Python ≠ single Rust binary like `fclones`/`czkawka_cli`) |
| Per-call latency | In-process Metal | Subprocess cold-start unless we keep a long-running helper (adds IPC protocol design) |
| Notarization | Swift dylibs covered by existing inside-out signing in `Scripts/release/sign.sh` | Notarizing a Python bundle is 100s of dylibs and TCC headaches |
| Intel/x86 | ARM64-only; matches current product scope (Intel deferred in `gargantua-vzuz`) | Subprocess is portable in theory; moot today |
| Churn risk | `mlx-swift-lm` versioned releases; pinnable | Python + user env = wider surface |
| Crash isolation | In-process (process dies if Metal dies) | Out-of-process |

### Why MLX Swift wins for this product

1. **Install UX.** We ship a signed/notarized DMG. Requiring users to have Python + `mlx-lm` in PATH is not a credible consumer install story. Vendoring CPython would let us ship a self-contained `.app` but adds 50–100 MB+ and a notarization story that looks nothing like the existing fclones/czkawka vendoring pattern.
2. **Bundle budget.** PRD §7 budgets 35–50 MB without bundled models. Resources/bin/ is already ~32 MB (`fclones` 5.1 MB + `czkawka_cli` 27 MB). SPM adds Swift dylibs that link into the main executable — manageable. Python vendoring does not fit.
3. **API fit.** `AIInferenceEngine` is `@MainActor` Swift. `memoryUsage` reads resident bytes from the engine; `unload()` releases weights synchronously. In-process matches these semantics natively. Subprocess would need a long-running daemon + IPC + cross-process RSS polling to come close.
4. **Toolchain consistency.** Project is SPM-only (no pbxproj). `ml-explore/mlx-swift-lm` is a first-class SPM package with `macOS(.v14)` support — our minimum. The existing vendoring pattern (`Scripts/fetch-fclones.sh`, `Scripts/vendored-bins.lock` designed in `gargantua-vzuz`) is Rust-binary-shaped, not Python-ecosystem-shaped; reusing it for Python would mean inventing a new pattern.
5. **Release pipeline compatibility.** `Scripts/release/sign.sh` already signs inside-out (helpers → resource bundle → app). Swift dylibs linked into the main executable ride in under the top-level sign; no new plumbing. Python vendoring would require signing every `.so` individually.
6. **Crash-isolation cost is acceptable.** A Metal OOM here kills the app, but `LocalAIService` already treats engine failures as advisory (YAML rule fallback), so a crash manifesting as process death is a worse UX than a single failed explanation but not data-destructive.

### Why `mlx-lm` loses

The `DefaultProcessRunner` hardening is a real asset, but it's solving a different problem (running well-behaved single-binary Rust helpers for one-shot scans). LLM inference wants long-lived model weights, token streaming, and in-process memory visibility — none of which the runner is shaped for. The Python dependency problem dominates.

## Scope of this bean

In scope:
- Design doc (this file).
- Add `ml-explore/mlx-swift-lm` to `Package.swift`.
- Link `MLXLLM` and `MLXLMCommon` into the `GargantuaCore` target.
- `swift build` debug + release green; no regressions in `swift test`.
- Measure and record bundle-size delta.

Out of scope (next Task: `gargantua-mgqr`):
- Replacing the `throw .notImplemented` bodies in `MLXInferenceEngine.load(modelPath:modelSize:)` / `generate(for:rule:)`.
- Model-file download-manager changes.
- Any Settings toggle for engine selection (`gargantua-6xce`).
- Latency / memory smoke tests (`gargantua-7k2r`).

## Dependency pin

```
.package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3")
```

`mlx-swift-lm` 3.31.3 transitively pulls `mlx-swift` 0.31.x and `swift-syntax`. Products linked:

- `MLXLMCommon` — token loop, KV-cache, prompt formatting, tokenizer loader. The minimum needed to host a model.
- `MLXLLM` — the decoder-only architectures (Llama 3.2 1B/3B, Qwen, etc.) we'll pin from in `gargantua-mgqr`.

(`MLXVLM`, `MLXEmbedders`, `MLXHuggingFace` deliberately left unlinked — not needed for Tier 1 explanation generation, and keeping them out shrinks the final binary.)

## Intended model pin (for `gargantua-mgqr`)

Per PRD §6.2: 4-bit Llama 3.2 1B. Target `mlx-community/Llama-3.2-1B-Instruct-4bit` (~0.8 GB on disk). Selection is documented here so the download-manager work in `mgqr` has a canonical target; pin lives in code there, not in this bean.

## Risks + mitigations

- **Swift-compile time regression.** First build fetches + compiles mlx-swift. Recorded below. Release pipeline allots a cold build; cache survives across incremental builds.
- **Transitive dep drift.** `mlx-swift-lm` pins `mlx-swift` via `.upToNextMinor`, which we inherit via `from: "3.31.3"` (`.upToNextMajor`). Upstream minor bumps can churn the API; planned response is to pin harder (`.exact`) if we see churn during `mgqr`.
- **swift-syntax transitive.** `mlx-swift-lm` pulls `swift-syntax` (used by their macros). `swift-syntax` is heavyweight to compile but shipped by Apple; acceptable.
- **Binary symbol name collisions.** `MLX`-prefixed; no conflict with `GargantuaCore` types.
- **Metal availability on notarization CI.** Release build does not need to run Metal — it only needs to link against the MLX Swift frameworks. CI on Apple Silicon is fine.
- **`default.metallib` not produced by `swift build` CLI.** mlx-swift's `.metal` shader sources are not compiled by SwiftPM — only Xcode's build system knows how to emit `.air`/`.metallib` artifacts. Discovered during `gargantua-mgqr` when tests first exercised MLX. Mitigation landed in `gargantua-8fjo`: `Scripts/build-metallib.sh` calls `xcrun metal` on the 9 shaders listed in mlx's `kernels/CMakeLists.txt` and links `mlx.metallib` into `Gargantua.app/Contents/MacOS/` (colocated with the executable, MLX's first search path). Same pattern for test runs via `Scripts/test.sh`. Requires the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
- **Shader list drift on mlx-swift version bumps.** `Scripts/build-metallib.sh` hardcodes the shader list from `mlx/backend/metal/kernels/CMakeLists.txt`. When bumping `mlx-swift-lm`'s pin, diff the CMakeLists' `build_kernel(...)` invocations and update the `SHADERS` array.

## Build-size measurement

Measured on this bean's branch (`gargantua-xuz6`), clean `.build` each side, Apple Silicon / macOS 14.

| Artifact | Before (main) | After (this branch) | Delta |
|---|---:|---:|---:|
| `Gargantua` release exec, unstripped | 9,761,256 B (9.31 MB) | 42,205,320 B (40.25 MB) | +32,444,064 B (+30.94 MB) |
| `Gargantua` release exec, `strip -u -r` | 3,772,048 B (3.60 MB) | 21,657,976 B (20.65 MB) | +17,885,928 B (+17.06 MB) |
| `swift build -c release` cold wall time | ~42 s | ~141 s (first build), ~170 s (second with `MLXLLM` fully elaborated) | +~100–128 s (one-time; cached afterward) |
| `swift build -c debug` cold wall time | — | ~47 s | — |
| `swift test -c debug --parallel` | 731 tests / 59 s | 731 tests / 59 s | no regression |

### Bundle-budget reading

PRD §7 target: ~35–50 MB without bundled models. Current vendored helpers (`fclones` + `czkawka_cli`) already cost ~32 MB of the budget. Post-MLX `.app` bundle, assuming `strip` is applied in `Scripts/release.sh`:

- exec (stripped) ~21 MB + helpers ~32 MB + Info.plist/icon/etc ≈ **~54 MB**
- exec (unstripped) ~40 MB + helpers ~32 MB ≈ ~74 MB (over budget)

Stripped keeps us within a few MB of the upper 50 MB PRD bound. Release pipeline does not currently strip (grepped `Scripts/release/*.sh` — no `strip` invocation). **Follow-up:** file a bean to add a `strip -u -r` pass in `Scripts/release/sign.sh` ahead of codesigning the app, or add `-Xlinker -S -Xlinker -x` to the release build flags in `Scripts/release/build.sh`. That bean is a prerequisite for staying under PRD §7 once MLX is real.

(Optional further wins: drop `MLXLLM` if we later decide the architecture set is too heavy and only ship `MLXLMCommon` + a single hand-ported model arch. Deferred; not needed for `mgqr`.)

## Acceptance

- [ ] This design doc captures the chosen backend + reasoning.
- [ ] `Package.swift` lists `mlx-swift-lm` and links `MLXLLM` + `MLXLMCommon` into `GargantuaCore`.
- [ ] `swift build -c debug` and `swift build -c release` succeed on the branch.
- [ ] `swift test` passing count stays ≥ the pre-change baseline (no regressions).
- [ ] Bundle-size delta measured and recorded in the table above.
