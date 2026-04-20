---
# gargantua-9495
title: 'Task: macOS app packaging + signing + notarization pipeline'
status: todo
type: task
priority: high
created_at: 2026-04-20T01:47:17Z
updated_at: 2026-04-20T02:00:14Z
---

Establish the release infrastructure required to ship Gargantua as a signed, notarized macOS app. This is a prerequisite for any bean that needs team-ID signing, Gatekeeper/TCC inheritance, or a reproducible `.app` artifact.

## Context

Today the repo is pure Swift Package Manager — `Package.swift`, no Xcode project, no `.github/workflows`, no release script beyond `Scripts/fetch-fclones.sh`. `swift build` produces executables under `.build/`, not a signed `.app` bundle.

`gargantua-vzuz` (fclones bundle hardening) explicitly calls this out as a blocker: *"No Xcode project or CI release pipeline exists in this repo yet. Signing + notarization presume that infrastructure lands first (either via a separate 'app packaging' bean or alongside this one)."*

PRD §9 (Permissions & Security) requires that bundled binaries (e.g. `fclones`, eventually `czkawka_cli`) are *"signed with the same team ID as the parent app"* so TCC inheritance lets Full Disk Access scans run without extra prompts.

## Scope

End state: a reproducible pipeline that takes the SPM sources + vendored resources and produces a signed, notarized, stapled `Gargantua.app` ready for distribution.

## Acceptance Criteria

- [ ] Decide on app shell approach: Xcode project checked in, vs SPM + `Scripts/package-app.sh` that assembles `.app` from swift-build output. Document the choice in `docs/designs/` with rationale.
- [ ] `Gargantua.app` bundle is produced with correct `Info.plist`, `Contents/MacOS/Gargantua`, and `Contents/Resources/` (including the GargantuaCore SPM resource bundle with its `bin/fclones`)
- [ ] Release script / workflow signs the app **and any embedded helper binaries** with the team-ID Developer ID Application certificate (`codesign --force --options runtime --sign "$TEAM_ID"`)
- [ ] Notarization submission via `xcrun notarytool submit --wait`, then `xcrun stapler staple`
- [ ] Gatekeeper check on a fresh VM / clean user account: `spctl --assess --type execute Gargantua.app` passes; app launches without quarantine prompt
- [ ] Secrets (Apple ID, team ID, app-specific password, notarization keychain profile) documented — where they live (local keychain vs CI secrets), how to rotate
- [ ] A runnable invocation: either `./Scripts/release.sh` locally or a `.github/workflows/release.yml` that a human can dispatch
- [ ] Follow-up beans updated to unblock once this lands: `gargantua-vzuz` (fclones signing), and anything else that pops out of the design doc

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
