---
# gargantua-8fjo
title: Compile default.metallib for MLX runtime (unblocks MLX inference)
status: completed
type: task
priority: high
created_at: 2026-04-20T16:17:01Z
updated_at: 2026-04-20T17:20:45Z
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

- [x] Release pipeline produces `mlx.metallib` and colocates it with the executable at `Contents/MacOS/mlx.metallib` (first search path in `load_default_library`). Wired into `Scripts/release/assemble-app.sh`.
- [x] Standalone MLX smoke (tiny Swift package importing MLX, running an MLXArray op) succeeds with the colocated metallib present; fails with the "Failed to load the default metallib" error without it. End-to-end `.app` verification with a real model is deferred to `gargantua-7k2r` (the MLX latency/memory smoke-test bean) — that bean will exercise the full `Gargantua.app` inference path.
- [x] `Scripts/test.sh` wrapper stages `mlx.metallib` into the test bundle's `Contents/MacOS/` and delegates to `swift test`. Works on the `gargantua-mgqr` branch where MLX is actually exercised (validated after merge; this bean's branch passes 731/731 without touching MLX runtime). Shape documented in `docs/designs/2026-04-20-mlx-backend.md` (Risks + mitigations section).
- [x] Follow-up noted in `Scripts/build-metallib.sh` header + design doc: when bumping `mlx-swift-lm`, diff `mlx/backend/metal/kernels/CMakeLists.txt`'s `build_kernel(...)` calls against the `SHADERS` array and update.

## Blocks

`gargantua-mgqr` — MLXInferenceEngine implementation can't satisfy its happy-path acceptance (load + generate returning non-empty text) until this lands.

## Summary of Changes

Produced `mlx.metallib` at release + test time so MLX runtime ops actually work. mlx-swift via SPM CLI does not emit a default metallib (Xcode owns `.metal` compilation), and it was never caught in `gargantua-xuz6` because nothing exercised MLX at runtime. `gargantua-mgqr`'s tests hit it first.

### Files

- `Scripts/build-metallib.sh` (new) — runs `xcrun metal` on the 9 shaders in mlx's `kernels/CMakeLists.txt` and links them into the caller-specified output path. Preflights the Metal Toolchain install and surfaces a clear hint if missing.
- `Scripts/test.sh` (new) — `swift test` wrapper that stages `mlx.metallib` into the test bundle's `Contents/MacOS/`. Use instead of `swift test` when touching MLX runtime.
- `Scripts/release/assemble-app.sh` — calls `build-metallib.sh` after copying the executable, writing `mlx.metallib` next to `Gargantua` so `load_default_library`'s first-path search (`current_binary_dir() / "mlx.metallib"`) picks it up.
- `docs/designs/2026-04-20-mlx-backend.md` — appended the metallib-runtime risk + mitigation, and a follow-up-on-mlx-bump note.

### Decisions

- **Colocated `mlx.metallib` over SWIFTPM_BUNDLE.** MLX's load order is: colocated `mlx.metallib` → `Resources/mlx` → `mlx-swift_Cmlx.bundle/default.metallib` → `Resources/default` → `default.metallib` in cwd. Colocation is the shortest path and works identically in test and release layouts (both put the binary in a `Contents/MacOS/` directory).
- **Hardcoded shader list.** The list mirrors mlx's CMakeLists exactly. Dynamic discovery (glob `*.metal`) would incorrectly include `steel/attn/kernels/steel_attention.metal` twice (once via its dependencies) and would silently start shipping new shaders on upstream adds without review. Static list with a "diff CMakeLists on version bump" doc note is more auditable.
- **Metal Toolchain is now a developer prerequisite.** Documented in `build-metallib.sh` and enforced by a preflight check. Not worth vendoring — the toolchain is Apple-distributed and multi-GB.
- **Smoke test tiers.** This bean's acceptance validated via an in-repo `Scripts/build-metallib.sh` smoke (produces 3.14 MB metallib) + an out-of-repo minimal Swift package that runs `MLXArray([1,2,3,4]) + 1` and prints the result. End-to-end `.app`-with-real-model verification is explicitly owned by `gargantua-7k2r` (MLX latency/memory smoke tests); out of scope here.

### Verification

- `Scripts/build-metallib.sh --output /tmp/...` produces `mlx.metallib` (3,135,866 bytes) from a fresh `.build/checkouts/mlx-swift`.
- Standalone smoke without the metallib: MLX emits "Failed to load the default metallib" and aborts.
- Standalone smoke with the metallib colocated: `[2.0, 3.0, 4.0, 5.0]` returned, `activeMemory` reports 36 bytes post-eval, `SMOKE_OK` printed.
- `Scripts/test.sh` on this branch: 731/731 tests pass (main's code doesn't exercise MLX runtime; real validation happens when mgqr's code lands on main).
- `swift build -c release` green.

### Unblocks

- `gargantua-mgqr` — MLX inference implementation can now run its env-gated integration test end-to-end against a real model directory.
