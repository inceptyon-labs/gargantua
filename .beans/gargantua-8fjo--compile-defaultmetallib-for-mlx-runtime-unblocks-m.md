---
# gargantua-8fjo
title: Compile default.metallib for MLX runtime (unblocks MLX inference)
status: completed
type: task
priority: high
created_at: 2026-04-20T16:17:01Z
updated_at: 2026-04-20T21:34:48Z
blocking:
    - gargantua-mgqr
---

## Context

`gargantua-xuz6` integrated mlx-swift into Package.swift. The build passes but the resulting binary is non-functional for inference: mlx-swift needs a compiled `default.metallib` at runtime (the SWIFTPM_BUNDLE mechanism, see `mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/device.cpp` `load_default_library`). `swift build` CLI cannot compile `.metal` files — only Xcode's build system knows how to turn `.metal` into `.metallib`. Discovered while implementing `gargantua-mgqr` when the test suite hit "MLX error: Failed to load the default metallib" as soon as a test touched `MLX.Memory.clearCache()` on an unloaded engine.

Upstream confirms (ml-explore/mlx-swift issues #36, #89): if you consume mlx-swift via SPM from the CLI, you must produce `default.metallib` yourself. Xcode-backed apps get it for free.

## Scope

Produce `default.metallib` during the release build and during test runs, and place it where MLX's runtime finds it (colocated with the executable, or in a bundle named `mlx-swift_Cmlx.bundle`).

### Release build

In `Scripts/release/build.sh` (or a new `Scripts/release/build-metallib.sh` it calls), after `swift build -c release`:

1. Locate mlx-swift's Metal source tree: `.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/` (shaders) and any headers it needs.
2. Invoke `xcrun metal -c <shader files> -o <.air files>`, then `xcrun metallib *.air -o default.metallib`.
3. Place the resulting `default.metallib` next to `Gargantua` (colocated `Gargantua.app/Contents/MacOS/default.metallib`), or inside a generated `mlx-swift_Cmlx.bundle` inside the app's Resources. MLX's `load_default_library` tries both; pick the simpler (colocated) first.
4. Verify: run the signed app with `GARGANTUA_MLX_MODEL_DIR` pointing at a tiny model, confirm no metallib-missing error.

### Test runs

For `swift test`, the test executable's `.bundle` path is different. Options:
1. A `scripts/run-tests.sh` wrapper that compiles `default.metallib` to the expected path before invoking `swift test`. Document in CONTRIBUTING that the test suite requires this wrapper if you want to run MLX integration tests locally.
2. A test helper that skips MLX-touching tests when `default.metallib` is absent (we already env-gate the integration test; extend to cover `MLX.Memory` access).

Recommend option 1 — one script, repeatable, doesn't hide failures.

### Out of scope

- Switching the release pipeline to Xcode — explicitly rejected in `docs/designs/2026-04-19-macos-release-pipeline.md` (no pbxproj checked in).
- Rewriting mlx-swift upstream to ship a precompiled metallib.
- Handling future mlx-swift releases that change the shader layout — revisit with each pin bump.

## Acceptance

- [x] `Scripts/release/build.sh` produces `default.metallib` and places it so `load_default_library` finds it.
- [x] The signed/notarized `.app` runs an MLX op without the "Failed to load the default metallib" error (smoke test: `GARGANTUA_MLX_MODEL_DIR` + one `explain` call through the CLI).
- [x] `swift test` — or a `scripts/run-tests.sh` wrapper that callers use in its place — works end-to-end on a branch that exercises MLX. Document the chosen shape in the design doc `docs/designs/2026-04-20-mlx-backend.md` or its successor.
- [x] Follow-up plan noted for mlx-swift version bumps (how to regenerate when upstream shader list changes).

## Blocks

`gargantua-mgqr` — MLXInferenceEngine implementation can't satisfy its happy-path acceptance (load + generate returning non-empty text) until this lands.

## Summary of Changes

All four acceptance criteria were satisfied by work that landed on main prior to this close-out; the bean was simply left in `todo` after the implementation merged. No new code required.

- **Release build produces metallib** — `Scripts/release/assemble-app.sh` (lines 88-89) invokes `Scripts/build-metallib.sh` after `build.sh` and writes `mlx.metallib` to `$APP_BUNDLE/Contents/MacOS/`. MLX's `load_default_library` (mlx/backend/metal/device.cpp) checks that colocated path first, so the `mlx-swift_Cmlx.bundle` path was not needed. Name chosen is `mlx.metallib` (upstream convention for colocated override), not `default.metallib` — functionally equivalent for this search path. Commit: 0575a36.
- **Signed app runs MLX ops without metallib-load errors** — `Tests/GargantuaCoreTests/Services/MLXExplainSmokeTests.swift` is an opt-in (`GARGANTUA_MLX_SMOKE=1`) end-to-end test that drives the full `LocalAIService.explain` path against a staged Llama-3.2-1B-4bit model. Validated under gargantua-2h7t and again during gargantua-lyc1 once the HF-layout download landed.
- **`swift test` works end-to-end with MLX** — `Scripts/test.sh` wraps `swift test`, runs `swift build --build-tests`, and stages `mlx.metallib` into the xctest bundle's `Contents/MacOS/` before exec'ing. `Scripts/run.sh` (commit a25ae9f) does the same for `swift run Gargantua`, so local debug runs of the UI are also covered. Documented in `docs/designs/2026-04-20-mlx-backend.md` line 90.
- **Shader-list drift follow-up documented** — `docs/designs/2026-04-20-mlx-backend.md` line 91 spells out the version-bump procedure: diff `mlx/backend/metal/kernels/CMakeLists.txt` `build_kernel(...)` invocations against the `SHADERS` array in `Scripts/build-metallib.sh` and update. Requires the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`); the build script fails with a clear install hint if absent.

Unblocks: gargantua-mgqr (which has since landed — MLXInferenceEngine load/generate merged in b7c13df).
