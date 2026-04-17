---
# gargantua-4xkj
title: 'Task: NSWorkspace/LaunchServices app scanner'
status: completed
type: task
priority: high
created_at: 2026-04-17T21:49:38Z
updated_at: 2026-04-17T22:50:52Z
parent: gargantua-j8a1
---

Implement a service that enumerates installed macOS apps via NSWorkspace + LaunchServices and produces AppInfo instances.

Scope:
- Enumerate apps from /Applications, ~/Applications, and Launch Services
- Populate AppInfo: bundleID, name, displayName, version strings, bundlePath, executablePath, install/lastUsed dates, isRunning (NSRunningApplication), isSystemApp, sizeOnDisk, teamIdentifier, signatureValid
- Code-signature verification via SecStaticCode / SecCode APIs
- Respect Trust Layer — never mutate SafetyLevel
- Tests: mock-backed unit tests plus one smoke test against /System/Applications

Blocked by gargantua-9wxo (merged).



## Summary of Changes

Implemented the NSWorkspace/LaunchServices app scanner for the Smart Uninstaller pipeline (Phase 2).

**Files added**
- `Sources/GargantuaCore/Services/AppScanner.swift` — `AppScanning` protocol, `DefaultAppScanner` orchestrator, `RunningAppChecking` + `DefaultRunningAppChecker` (NSRunningApplication-backed)
- `Sources/GargantuaCore/Services/AppBundleEnumerator.swift` — `AppBundleEnumerating` protocol + `DefaultAppBundleEnumerator` (walks /Applications, ~/Applications, augments with NSWorkspace.runningApplications)
- `Sources/GargantuaCore/Services/AppBundleReader.swift` — `AppBundleReading` protocol + `DefaultAppBundleReader` (Info.plist extraction, FS metadata, recursive size)
- `Sources/GargantuaCore/Services/CodeSignatureVerifier.swift` — `CodeSignatureVerifying` protocol + `DefaultCodeSignatureVerifier` (SecStaticCode-backed, returns validity + team identifier)
- `Tests/GargantuaCoreTests/Services/AppScannerTests.swift` — 8 mock-backed unit tests
- `Tests/GargantuaCoreTests/Services/AppScannerSmokeTests.swift` — smoke test against /System/Applications
- `Tests/GargantuaCoreTests/Services/AppBundleReaderTests.swift` — 6 synthetic-bundle reader tests

**Key decisions**
- `isSystemApp` is path-based only (`/System/` prefix). An earlier team-identifier fallback was removed during OC review because Apple-signed apps in /Applications (Keynote, Pages, Xcode) are user-installable and must remain uninstallable.
- Scanner is read-only — never mutates `SafetyLevel` or any other Trust Layer state. Consumers are responsible for downstream classification.
- Dedup by `bundleID`, first-seen wins so /Applications entries take precedence over bundles surfaced via NSRunningApplication.
- `SecStaticCode` uses default flags (offline validation only — no Apple-notarisation network calls).
- All macOS-framework touchpoints (NSWorkspace, NSRunningApplication, SecStaticCode, FileManager) sit behind protocols so unit tests run with stubs.

**Notes for next task (RemnantRuleLoader, gargantua-anqg)**
- `AppScanning.scanApps()` returns `[AppInfo]` ready for remnant rule matching.
- `AppInfo.teamIdentifier` is populated from the signing cert (may be nil for system apps).
- The `AppBundleMetadata` intermediate shape is internal; consumers use `AppInfo` only.
- No public API currently emits progress — if scanning grows slow, consider adding an `AsyncStream<AppInfo>` variant.

**Tests**: 373/373 passing (baseline 358 + 15 new).
