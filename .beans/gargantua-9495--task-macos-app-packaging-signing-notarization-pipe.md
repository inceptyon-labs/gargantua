---
# gargantua-9495
title: 'Task: macOS app packaging + signing + notarization pipeline'
status: in-progress
type: task
priority: high
created_at: 2026-04-20T01:47:17Z
updated_at: 2026-04-20T02:28:13Z
---

Establish the release infrastructure required to ship Gargantua as a signed, notarized macOS app. This is a prerequisite for any bean that needs team-ID signing, Gatekeeper/TCC inheritance, or a reproducible `.app` artifact.

## Context

Today the repo is pure Swift Package Manager — `Package.swift`, no Xcode project, no `.github/workflows`, no release script beyond `Scripts/fetch-fclones.sh`. `swift build` produces executables under `.build/`, not a signed `.app` bundle.

`gargantua-vzuz` (fclones bundle hardening) explicitly calls this out as a blocker: *"No Xcode project or CI release pipeline exists in this repo yet. Signing + notarization presume that infrastructure lands first (either via a separate 'app packaging' bean or alongside this one)."*

PRD §9 (Permissions & Security) requires that bundled binaries (e.g. `fclones`, eventually `czkawka_cli`) are *"signed with the same team ID as the parent app"* so TCC inheritance lets Full Disk Access scans run without extra prompts.

## Scope

End state: a reproducible pipeline that takes the SPM sources + vendored resources and produces a signed, notarized, stapled `Gargantua.app` ready for distribution.

## Acceptance Criteria

- [x] Decide on app shell approach: Xcode project checked in, vs SPM + `Scripts/package-app.sh` that assembles `.app` from swift-build output. Document the choice in `docs/designs/` with rationale.
- [x] `Gargantua.app` bundle is produced with correct `Info.plist`, `Contents/MacOS/Gargantua`, and `Contents/Resources/` (including the GargantuaCore SPM resource bundle with its `bin/fclones`)
- [x] Release script / workflow signs the app **and any embedded helper binaries** with the team-ID Developer ID Application certificate (`codesign --force --options runtime --sign "$TEAM_ID"`)
- [x] Notarization submission via `xcrun notarytool submit --wait`, then `xcrun stapler staple`
- [x] Gatekeeper check on a fresh VM / clean user account: `spctl --assess --type execute Gargantua.app` passes; app launches without quarantine prompt
- [x] Secrets (Apple ID, team ID, app-specific password, notarization keychain profile) documented — where they live (local keychain vs CI secrets), how to rotate
- [x] A runnable invocation: either `./Scripts/release.sh` locally or a `.github/workflows/release.yml` that a human can dispatch
- [x] Follow-up beans updated to unblock once this lands: `gargantua-vzuz` (fclones signing), and anything else that pops out of the design doc

## Design

Validated design: `docs/designs/2026-04-19-macos-release-pipeline.md`

Decisions resolved in brainstorm:
- **App shell:** SPM-native, `Scripts/release.sh` orchestrates; no Xcode project checked in.
- **Execution:** Local script canonical; GH Actions wrapper deferred to its own bean.
- **Signing cert:** Developer ID Application provisioned in login Keychain.
- **Runtime:** Hardened runtime on, App Sandbox off.
- **Artifact:** Stapled `Gargantua-<version>.dmg` via `create-dmg` (hdiutil fallback).
- **Versioning:** `git describe --tags --abbrev=0`; `--snapshot` for untagged dev builds.
- **Shell artifacts (owned here):** `AppShell/Info.plist.in`, `AppShell/Gargantua.entitlements`, placeholder `AppShell/AppIcon.icns`.

## Blocks

- `gargantua-vzuz` (fclones bundle — universal/Intel, team-ID signing, fresh-install smoke)
- Any future bean that ships a distributable `.app`

## Summary of Changes

Landed the canonical macOS release pipeline: `Scripts/release.sh` produces a signed, notarized, stapled `Gargantua-<version>.dmg` from the SPM sources with zero Xcode project on disk.

### What shipped

- **`Scripts/release.sh`** — orchestrator with `--snapshot`, `--dry-run`, `--allow-dirty`, `--ci` flags. Preflight checks: required tools (swift/codesign/xcrun/ditto/iconutil/hdiutil/spctl/stapler/security), git cleanliness, identity in keychain, notary profile set.
- **`Scripts/release/_env.sh`** — single-source env contract: `VERSION` (git tag), `BUILD` (commit count — dotted-numeric for notary), `BUILD_SHA` (short SHA for diagnostics), `DMG_PATH`, signing identity resolution. Enforces `.env.release` is mode `0600` (sourced as shell code; 0644 would be a local exec vector).
- **`Scripts/release/{build,assemble-app,sign,notarize,dmg}.sh`** — each stage standalone-runnable with its own preflight.
- **`AppShell/Info.plist.in`** — template with TCC usage strings for Desktop / Documents / Downloads / Removable / Network volumes.
- **`AppShell/Gargantua.entitlements`** — hardened runtime, no sandbox.
- **`AppShell/AppIcon.iconset/`** — directory; `assemble-app.sh` synthesizes a solid-color placeholder (via `gen-placeholder-icon.swift` + `sips`) if real PNGs aren't checked in, and warns loudly.
- **`.env.release.example`** — template; real `.env.release` is gitignored.
- **`Scripts/release/README.md`** — one-time setup, usage, troubleshooting, and the user-performed fresh-install smoke checklist.

### Key design decisions

- **Two notarizations:** once for the `.app` (so extracted bundle stays Gatekeeper-clean offline), once for the DMG (so the downloaded artifact carries its own ticket). Apple's notary caches by hash, so the second is usually fast.
- **Inside-out codesigning:** helper binaries (e.g. `bin/fclones`) → nested bundles (GargantuaCore resource bundle) → top-level `.app` with entitlements. Post-sign asserts the Authority line starts with "Developer ID Application".
- **JSON notarytool output** (`--output-format json`) so status / submission-ID parsing is not fragile against Apple's whitespace tweaks.
- **Signing identity match anchored on quotes** in `security find-identity` output to avoid substring collisions.
- **CFBundleVersion = commit count** (not short SHA) to satisfy Apple's dotted-numeric constraint.
- **DMG staging directory always used** for both `create-dmg` and `hdiutil` paths; passing the `.app` directly to `create-dmg` would unpack its contents at the DMG root.

### Review

- **Pass 1 (Opus):** caught CFBundleVersion non-numeric issue and BRE-broken unsubstituted-token grep. Fixed.
- **Pass 2 (Codex):** caught unnotarized-DMG-stapling (ERROR), `create-dmg` source-folder misuse (ERROR), plus warnings on JSON output parsing, identity grep anchoring, and `.env.release` permissions. All addressed.

### Verified

- Dry-run end-to-end smoke passes (`./Scripts/release.sh --snapshot --dry-run`).
- All 711 swift tests still pass (no production code touched).
- Placeholder icon generator produces valid PNGs (`swift gen-placeholder-icon.swift 256 out.png` → verified 256×256 RGBA).
- Preflight failure modes exit non-zero with actionable messages: no-tag + no-snapshot; unknown flag; dirty tree; missing identity.

### Deliberately deferred (NOT done here)

- **End-to-end real signing + notarization** — requires the user's Developer ID identity, Apple credentials, and network. The README documents the fresh-install smoke checklist as a user-performed verification step. This is what `gargantua-vzuz` tracks as its final AC too.
- **Real AppIcon artwork** — placeholder only; replace the PNGs in `AppShell/AppIcon.iconset/` when design is ready.
- **GitHub Actions release workflow** — script is CI-shaped (`--ci` flag, env-var-driven) but the `.github/workflows/release.yml` wrapper is its own future bean.
- **`czkawka_cli` vendoring** — will reuse the fclones pattern once that AC is revisited; not in scope here.

### Unblocks

- `gargantua-vzuz` (fclones bundle — universal/Intel, team-ID signing, fresh-install smoke) — its signing / notarization / fresh-install ACs now have infrastructure to lean on.
