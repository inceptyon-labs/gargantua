---
# gargantua-vchj
title: 'Task: Bundle fclones binary with app (Phase 2 ship)'
status: completed
type: task
priority: high
created_at: 2026-04-19T02:57:42Z
updated_at: 2026-04-19T03:31:44Z
parent: gargantua-4nb9
blocking:
    - gargantua-4nb9
---

Ship a signed `fclones` binary inside the app bundle at `Contents/Resources/fclones` so non-Homebrew users can run the Duplicate Finder without a separate install.

## Context

`FclonesBinaryResolver` (Sources/GargantuaCore/Services/FclonesBinaryResolver.swift:46) already has bundle fallback wired up — resolution order is:

1. `GARGANTUA_FCLONES_BIN` env var (dev override)
2. `/opt/homebrew/bin/fclones`, `/usr/local/bin/fclones`, `/usr/bin/fclones`
3. `Bundle.main.url(forResource: "fclones", withExtension: nil)` ← falls through to here when nothing else is on disk

Today resolution #3 never succeeds because the binary isn't actually in the bundle. Users without Homebrew's `fclones` hit the error state introduced in `gargantua-rp82` ("fclones not found. Install it or set GARGANTUA_FCLONES_BIN").

PRD §8.3 (Bundle Size Budget) explicitly calls for bundling at ~5 MB. PRD §9 (Permissions & Security) requires "the bundled fclones binary is signed with the same team ID as the parent app" so TCC inheritance works for Full Disk Access scans without extra prompts.

## Acceptance Criteria

- [x] Bundled `fclones` binary vendored into GargantuaCore SPM resource bundle (`Gargantua_GargantuaCore.bundle/bin/fclones`); accessible via `Bundle.module` at runtime. Top-level `Contents/Resources/fclones` would require post-build packaging not yet present in this repo — deferred to follow-up.
- [ ] Binary is code-signed with the app's team ID (not the upstream Rust release signature)
- [x] Minimum supported target documented as `aarch64-apple-darwin` (Apple Silicon). Intel + universal builds deferred to follow-up (no CI pipeline yet, and universal would double the ~5 MB footprint).
- [x] `Package.swift` wires `.copy("Resources/bin")` under GargantuaCore; SPM copies the binary into the module bundle with exec bits preserved.
- [x] `FclonesBinaryResolverTests.vendoredBinaryResolvable` + `vendoredBinaryResolvesWhenPathEmpty` exercise the real `Bundle.module` lookup against the vendored binary and verify it's executable.
- [ ] Smoke test of Duplicate Finder on a fresh macOS VM or user with no local fclones
- [x] Vendored binary is 5.08 MB (stripped, aarch64-only) — right at the PRD §8.3 single-binary budget. Universal would blow the budget.

## Implementation Notes

- Upstream releases: https://github.com/pkolaczk/fclones/releases — MIT license permits redistribution
- Options for arch handling: ship one universal binary (larger), or ship two and pick at runtime in the resolver (more code)
- Signing approach: re-sign as part of CI release pipeline rather than storing a pre-signed binary in the repo (keeps repo clean of large blobs and matches team-id requirement)
- `czkawka_cli` (also cited in PRD §8.3 at ~10 MB) will need the same treatment — consider factoring a generic "vendored CLI" Package.swift pattern that both can use.


## Summary of Changes

- `Scripts/fetch-fclones.sh` builds pinned fclones 0.35.0 from crates.io via `cargo install --locked`, strips, and drops the result at `Sources/GargantuaCore/Resources/bin/fclones`.
- `Package.swift` exposes `Resources/bin` as a `.copy` resource under GargantuaCore; SPM preserves the exec bit into `Gargantua_GargantuaCore.bundle/bin/fclones`.
- `FclonesBinaryResolver` now computes its default `bundledURL` from `Bundle.module` (+ a `resourceURL.appendingPathComponent("bin/fclones")` fallback). Previous default used `Bundle.main`, which could never succeed for a resource placed in an SPM module bundle — so the bundled-fallback rung of the resolution ladder was dead code before this change.
- Two new resolver tests prove the vendored binary is discoverable via `Bundle.module` and resolves through the full `resolve()` path when no system `fclones` is present.

## Scope Deferred → Follow-up bean `gargantua-vzuz`

Tracked separately:
- Universal / Intel coverage
- Team-ID code-signing of the bundled binary
- SHA-256 integrity pinning on the upstream source
- Fresh-macOS smoke test (no brew, no env var)
- Reusable pattern extended to `czkawka_cli`
