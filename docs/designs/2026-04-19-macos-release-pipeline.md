# macOS Release Pipeline Design

**Date:** 2026-04-19
**Status:** Validated
**Bean:** `gargantua-9495`

## Summary

Turn the SPM-only repo into one that produces a signed, notarized, stapled `Gargantua-<version>.dmg` via a single command. Canonical entry point is `Scripts/release.sh`; a GitHub Actions wrapper lands later as its own bean but changes no script contract. Scoped to Developer ID distribution outside the App Store, hardened runtime on, App Sandbox off.

## Goals

- Single-command local release: `git tag vX.Y.Z && ./Scripts/release.sh` produces a ready-to-distribute stapled DMG.
- Package.swift remains the single source of truth for sources and targets; no Xcode project checked in.
- Team-ID codesigning of the app and every embedded helper binary (today `bin/fclones`, tomorrow `bin/czkawka_cli`).
- Env-var-driven contract so a future CI wrapper calls the same script with zero changes.
- Fail fast on any misconfiguration: missing identity, dirty tree, untagged HEAD, notarization rejection.

## Non-Goals (Out of Scope)

- Universal / Intel fclones — owned by `gargantua-vzuz`.
- GitHub Actions release workflow — separate bean.
- Sparkle auto-update feed / appcast.
- App Store (MAS) distribution.
- Real app icon artwork — placeholder `.icns` only.
- Crash reporting / telemetry.
- Byte-reproducible signatures across machines.
- Localized TCC usage strings — English-only for v1.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| App shell | SPM + packaging script | Keeps Package.swift canonical; no pbxproj drift. |
| Execution | Local script canonical, CI wrapper later | No CI burden before shipping; script designed CI-ready. |
| Signing cert | Developer ID Application (user has one) | Required for notarization + Gatekeeper outside MAS. |
| Shell artifacts | Owned by this bean | Single atomic landing; no half-shippable intermediate. |
| Runtime | Hardened runtime on, App Sandbox off | Duplicate Finder needs broad filesystem access. |
| Distribution | DMG | Standard macOS install UX; ticket staples to DMG. |
| Versioning | Git tag (`git describe --tags --abbrev=0`) | Zero drift; maps cleanly to future GH Releases. |

## Architecture

### Repo additions

```
Scripts/
├── release.sh                  ← canonical entry point
├── fetch-fclones.sh            ← exists; unchanged
└── release/
    ├── _env.sh                 ← resolves VERSION, TEAM_ID, SIGNING_IDENTITY, NOTARY_PROFILE, BUNDLE_ID
    ├── build.sh                ← swift build -c release --arch arm64
    ├── assemble-app.sh         ← lays out dist/Gargantua.app; renders Info.plist; copies resources
    ├── sign.sh                 ← codesign inside-out (helpers → resource bundle → app)
    ├── notarize.sh             ← ditto-zip → notarytool submit --wait → stapler staple
    └── dmg.sh                  ← create-dmg (fallback: hdiutil) → staple DMG

AppShell/
├── Info.plist.in               ← template; @VERSION@, @BUILD@, @BUNDLE_ID@ substitution
├── Gargantua.entitlements      ← hardened runtime; no sandbox
└── AppIcon.icns                ← placeholder
```

### Env contract (`_env.sh`)

| Var | Source (local) | Source (future CI) |
|---|---|---|
| `VERSION` | `git describe --tags --abbrev=0` (or `0.0.0-<sha>` with `--snapshot`) | same |
| `BUILD` | `git rev-parse --short HEAD` | same |
| `TEAM_ID` | `.env.release` (gitignored) | GH secret |
| `SIGNING_IDENTITY` | `"Developer ID Application: … (TEAM_ID)"` | GH secret |
| `NOTARY_PROFILE` | `notarytool` keychain profile name | imported from secret at job start |
| `BUNDLE_ID` | constant in `_env.sh` | same |

### Signing order

Inside-out, always:

1. Every embedded helper binary (`Contents/Resources/Gargantua_GargantuaCore.bundle/bin/*`)
2. The GargantuaCore resource bundle itself (if bundle-shaped)
3. The top-level `.app`

Implemented in `sign.sh` as `find Contents/Resources -type f -perm +111` then sign each before the top-level pass. Designed for N helpers out of the gate.

### Info.plist contents

- `CFBundleIdentifier` → `$BUNDLE_ID`
- `CFBundleShortVersionString` → `$VERSION`
- `CFBundleVersion` → `$BUILD`
- `LSMinimumSystemVersion` → matches Package.swift `.macOS(...)` min
- `NSHumanReadableCopyright` → static
- TCC usage strings: `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription`

## Key Flows

### Flow A: Local release

```
1. git tag v0.1.0
2. ./Scripts/release.sh
     _env.sh       → VERSION=0.1.0, BUILD=<sha>
     build.sh      → swift build -c release --arch arm64
     assemble-app.sh
                   → dist/Gargantua.app with Info.plist + AppIcon + resource bundle
     sign.sh       → inside-out codesign with --options runtime + entitlements
     notarize.sh   → ditto-zip → notarytool submit --wait → staple .app
     dmg.sh        → create-dmg dist/Gargantua-0.1.0.dmg → staple DMG
     verify        → spctl --assess, codesign --verify --deep --strict, stapler validate
3. Ship dist/Gargantua-0.1.0.dmg
```

### Flow B: Snapshot build

`./Scripts/release.sh --snapshot` → `VERSION=0.0.0-<sha>`. Still signs + notarizes. Useful for validating the full pipeline (and `gargantua-vzuz` ACs) without cutting a real tag.

### Flow C: Future CI wrapper (out of scope)

`.github/workflows/release.yml` imports `.p12` into a temp keychain, creates a notarytool profile, then calls `./Scripts/release.sh --ci`. No script edits required — that's the point of `_env.sh`.

### Baked-in verification

After stapling, script runs and must see exit 0 on all three:

- `spctl --assess --verbose=2 --type execute dist/Gargantua.app`
- `codesign --verify --deep --strict dist/Gargantua.app`
- `xcrun stapler validate dist/Gargantua-<version>.dmg`

## Edge Cases

**Preflight (fail fast):**
- Dirty git tree → refuse unless `--snapshot` or `--allow-dirty`.
- No tag on HEAD without `--snapshot` → refuse with hint.
- `SIGNING_IDENTITY` not in Keychain → `security find-identity` check, fail with hint.
- `NOTARY_PROFILE` not found → point at `notarytool store-credentials`.
- Missing tools (`swift`, `codesign`, `xcrun notarytool`, `create-dmg`, `ditto`) → list all missing in one message.

**Build:**
- `swift build` fails → propagate stderr, exit non-zero, `dist/` not populated.
- Missing `bin/fclones` in resource bundle → fail at assemble with pointer to `Scripts/fetch-fclones.sh`.

**Signing:**
- Any embedded binary fails → abort before top-level sign.
- Post-sign identity check: `codesign -dv` Authority line must contain "Developer ID", else abort.

**Notarization:**
- Rejected → print log URL + summary; don't staple; leave `dist/` for inspection.
- Timeout → 30-min upper bound; re-running is idempotent (notarytool dedupes by hash).
- Network failure mid-submit → re-run `release.sh`.

**DMG:**
- `create-dmg` absent → fall back to `hdiutil create -volname Gargantua -srcfolder dist/Gargantua.app -format UDZO`, warn.
- Stapling order enforced: app first, then DMG.

**Cleanup:**
- `dist/` wiped at start of each run (confirm interactively, unconditional with `--ci`).
- Temp notarization zip deleted on success, kept on failure.

## Acceptance Criteria (for the bean)

- [ ] `Scripts/release.sh` produces `dist/Gargantua-<version>.dmg` from a clean checkout on a tagged commit.
- [ ] `AppShell/Info.plist.in`, `AppShell/Gargantua.entitlements`, `AppShell/AppIcon.icns` checked in.
- [ ] App bundle has hardened runtime; App Sandbox off; TCC usage strings present.
- [ ] Codesign is inside-out: helpers → resource bundle → app. Verified by `codesign --verify --deep --strict`.
- [ ] Notarization submission succeeds; ticket stapled to `.app` and to `.dmg`.
- [ ] `spctl --assess --type execute` passes on the produced `.app`.
- [ ] `--snapshot` mode produces a valid signed/notarized DMG from an untagged HEAD.
- [ ] `_env.sh` is the single source of config vars; `.env.release` template committed (with placeholder values) and real file gitignored.
- [ ] Preflight failure modes above each exit non-zero with actionable hints.
- [ ] `gargantua-vzuz` unblocker: updating the blocker chain once this lands.

## Open Questions

None — all resolved in the brainstorm.

## Next Steps

- [ ] Kick `gargantua-9495` with this design as the plan of record.
- [ ] After landing, unblock `gargantua-vzuz` and re-kick it with a concrete signing story.
- [ ] File a separate bean for the GitHub Actions wrapper when release cadence warrants CI.
- [ ] File a bean for real AppIcon artwork when design is ready.
