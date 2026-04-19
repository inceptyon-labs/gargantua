---
# gargantua-vchj
title: 'Task: Bundle fclones binary with app (Phase 2 ship)'
status: todo
type: task
priority: high
created_at: 2026-04-19T02:57:42Z
updated_at: 2026-04-19T02:57:42Z
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

- [ ] Bundled `fclones` binary available at `Contents/Resources/fclones` in built `.app`
- [ ] Binary is code-signed with the app's team ID (not the upstream Rust release signature)
- [ ] Architectures cover both Apple Silicon and Intel (universal), or document the minimum supported target
- [ ] `Package.swift` (or Xcode target) wires the binary via `.copy("fclones")` so SPM doesn't treat it as a Swift source
- [ ] `FclonesBinaryResolver` smoke test verifies bundled fallback resolves on a clean install (no brew, no env var)
- [ ] Smoke test of Duplicate Finder on a fresh macOS VM or user with no local fclones
- [ ] Bundle size stays within PRD §8.3 budget (~5 MB added; total app bundle < 50 MB)

## Implementation Notes

- Upstream releases: https://github.com/pkolaczk/fclones/releases — MIT license permits redistribution
- Options for arch handling: ship one universal binary (larger), or ship two and pick at runtime in the resolver (more code)
- Signing approach: re-sign as part of CI release pipeline rather than storing a pre-signed binary in the repo (keeps repo clean of large blobs and matches team-id requirement)
- `czkawka_cli` (also cited in PRD §8.3 at ~10 MB) will need the same treatment — consider factoring a generic "vendored CLI" Package.swift pattern that both can use.
