---
# gargantua-8fjo
title: Compile default.metallib for MLX runtime (unblocks MLX inference)
status: todo
type: task
priority: high
created_at: 2026-04-20T16:17:01Z
updated_at: 2026-04-20T16:17:01Z
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

- [ ] `Scripts/release/build.sh` produces `default.metallib` and places it so `load_default_library` finds it.
- [ ] The signed/notarized `.app` runs an MLX op without the "Failed to load the default metallib" error (smoke test: `GARGANTUA_MLX_MODEL_DIR` + one `explain` call through the CLI).
- [ ] `swift test` — or a `scripts/run-tests.sh` wrapper that callers use in its place — works end-to-end on a branch that exercises MLX. Document the chosen shape in the design doc `docs/designs/2026-04-20-mlx-backend.md` or its successor.
- [ ] Follow-up plan noted for mlx-swift version bumps (how to regenerate when upstream shader list changes).

## Blocks

`gargantua-mgqr` — MLXInferenceEngine implementation can't satisfy its happy-path acceptance (load + generate returning non-empty text) until this lands.
