---
# gargantua-u6gm
title: Reduce stripped release app below 50 MB
status: completed
type: task
priority: normal
tags:
    - area:release
    - size:S
created_at: 2026-04-21T01:25:17Z
updated_at: 2026-04-21T01:48:39Z
---

## Context

While implementing gargantua-5vv2, the release pipeline now strips shipped Mach-O executables before codesign and the main executable drops from 53,631,912 B to 26,538,488 B.

Actual assembled stripped app size is still 60M (`du -sh`), over PRD §7's 50 MB ceiling. Size contributors from the verified local assemble:

- czkawka_cli: 27M (28,019,544 B)
- Gargantua: 25M (26,538,488 B)
- fclones: 5.1M (5,327,800 B)
- mlx.metallib: 3.0M (3,135,866 B)

## Scope

Find a product-safe way to reduce the shipped app bundle below 50 MB without removing required functionality. Likely candidates: smaller czkawka packaging, optional/on-demand helper distribution, different helper build flags, or revisiting the PRD budget now that MLX + helper binaries are both included.

## Acceptance

- [x] `du -sh dist/Gargantua.app` is under 50M after release build, assemble, strip, and ad-hoc local sign: 48M.
- [x] File-size breakdown is documented with before/after numbers.
- [x] Duplicate Finder/File Health helper functionality remains available in the shipped app.


## Completion Notes

Implemented by rebuilding the vendored Rust helpers with size-oriented release flags in `Scripts/fetch-vendored-bins.sh`:

- `RUSTFLAGS=-C opt-level=z -C panic=abort -C link-arg=-Wl,-dead_strip`
- Ad-hoc sign the checked-in helper binaries after strip so they remain runnable from the repo before the release pipeline applies the Developer ID signature.

Size results:

- `czkawka_cli`: 28,019,544 B -> 16,906,144 B
- `fclones`: 5,327,800 B -> 3,462,784 B
- Final assembled, stripped, ad-hoc signed `dist/Gargantua.app`: 48M (`du -sk`: 48,944 KiB)
- Final app contributors: `Gargantua` 25,784 KiB, `czkawka_cli` 16,512 KiB, `fclones` 3,384 KiB, `mlx.metallib` 3,064 KiB

Related release-signing fixes found during verification:

- `Scripts/release/sign.sh` now signs non-main `Contents/MacOS` code assets such as `mlx.metallib` before the top-level app.
- `Scripts/release/sign.sh` skips plain SwiftPM resource `.bundle` directories that `codesign` rejects as non-code bundles; the top-level app signature seals them as resources.
- `AppShell/Gargantua.entitlements` no longer contains XML comments because `codesign` entitlement parsing rejected the commented plist even though `plutil` accepted it.

Verification:

- `Scripts/fetch-vendored-bins.sh` reproduced the optimized helpers successfully.
- Source helper smoke: `fclones group --format json` found duplicate temp files; `czkawka_cli empty-files` found an empty temp file with exit 11.
- Release build + assemble + strip + ad-hoc sign passed `codesign --verify --deep --strict --verbose=2`.
- `./Scripts/release.sh --snapshot --dry-run --ci` passed and shows the updated four-phase signing order.
- `swift test`: 830 tests passed.
- `bash -n`, `plutil -lint`, and `git diff --check` passed.

Not run locally:

- Real Developer ID signing, notarization, stapling, and `spctl` assessment still require `.env.release` / exported `SIGNING_IDENTITY`, `NOTARY_PROFILE`, and `TEAM_ID`, which are not configured in this environment.
