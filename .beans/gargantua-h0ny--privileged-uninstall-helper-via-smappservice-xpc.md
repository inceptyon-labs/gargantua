---
# gargantua-h0ny
title: Privileged uninstall helper via SMAppService + XPC
status: in-progress
type: feature
priority: high
created_at: 2026-04-18T12:43:06Z
updated_at: 2026-04-21T23:47:13Z
---

Ship a bundled, signed, notarized privileged helper so the Smart Uninstaller can remove root-owned items in /Applications/ (and eventually /Library/LaunchDaemons/, /Library/PrivilegedHelperTools/). Required before any public distribution outside the Mac App Store.

## Why

Right now Smart Uninstaller calls `NSWorkspace.recycle` directly. When the target is root-owned (e.g. `/Applications/BeFunky.app` installed from a .pkg with `root:wheel`), macOS refuses the move with 'You do not have permission' and surfaces no auth prompt. Any app distributed from a signed installer ends up in this state, so the uninstaller is functionally broken for most real apps without a privileged path.

## Architecture

Swift protocol (already exists: `PrivilegedUninstallHelping`) stays as the call-site API. Back it with a real XPC service to a bundled, signed helper tool installed via `SMAppService.daemon(plistName:)`.

Command surface stays narrow: not 'run rm as root', but structured requests like `removeAppBundle(path:)` with the helper enforcing:
- Path allowlist (e.g. `/Applications/*.app`, `/Library/LaunchDaemons/*.plist`, `/Library/PrivilegedHelperTools/*`)
- Reject symlinks, path traversal, system-protected locations
- Reject anything outside the validated plan passed in by the caller
- Validate the caller's code signature on every XPC connection (`SecCodeCheckValidityWithErrors`) — otherwise anyone on the machine can call the helper as root
- Structured logging of every attempted + completed removal, piped back to the main app for the audit trail

## Scope

- [ ] Move from SwiftPM-only to an Xcode project shell (or post-build bundle-assembly script) so the app produces a real `.app` bundle with embedded helper at `Contents/Library/LaunchDaemons/`
- [ ] New executable target: privileged helper tool, minimal dependencies, single XPC listener
- [ ] XPC protocol definition shared between app and helper (Sendable, typed)
- [ ] Helper registers via `SMAppService.daemon(plistName:).register()`; UI handles the 'approve in System Settings' flow gracefully (including user-declined case)
- [ ] Caller code-signature validation inside the helper on every connection (anchor apple generic + team identifier + designated requirement)
- [ ] Main-app side: `XPCPrivilegedUninstallHelper` implements `PrivilegedUninstallHelping`, replaces any stub; `requiresPrivilegedHelper` predicate updated to catch root-owned `/Applications/*.app` (check writability at plan time, not category)
- [ ] Developer ID Application code signing for both binaries; same team ID; cross-referenced `SMAuthorizedClients` (helper) and designated requirement (app)
- [ ] Notarization pipeline (`notarytool submit --wait`) as a build step or Makefile target
- [ ] Dev-loop escape hatch: keep `swift run` working for non-privileged code paths; only bundle-install workflow is needed when touching the helper
- [ ] Dev cleanup commands (`launchctl bootout`, re-register on helper change, reset approval state between tests)
- [ ] Integration tests: at minimum, a manual test matrix covering (a) approval accepted, (b) approval declined, (c) helper version bump + re-register, (d) non-writable /Applications item success, (e) symlink/traversal rejection, (f) caller-signature-mismatch rejection

## Dev-loop impact

- UI work, scanning, selection, dry-run, non-privileged cleanup: keep using `swift run` ✓
- Privileged-path end-to-end: requires the signed-bundle flow. Budget a script that does `swift build` → assemble `.app` → embed helper + plist → codesign both → launch. Stale-state cleanup commands will become muscle memory.

## References

- Apple SMAppService: https://developer.apple.com/documentation/servicemanagement/smappservice
- alienator88/HelperToolApp (modern macOS 13+ SMAppService sample): https://github.com/alienator88/HelperToolApp
- trilemma-dev/SwiftAuthorizationSample (older SMJobBless but solid XPC architecture reference): https://github.com/trilemma-dev/SwiftAuthorizationSample
- tw93/Mole is NOT a model for this — it's a CLI that shells out to sudo/Touch ID, not a bundled GUI helper. Only the scan rules were worth porting from it.

## Non-goals

- Mac App Store distribution. MAS sandboxing forbids this class of operation entirely; shipping there would require abandoning most of the uninstaller's value.
- `osascript do shell script with administrator privileges` as a long-term path. Fine as a tactical stub if ever needed, rejected here.
- `AuthorizationExecuteWithPrivileges` — deprecated, Apple explicitly points users at SMAppService.
- Sudoers/NOPASSWD carve-outs. Persistent root policy exception that tool integrity/path replacement/updates would all become security-critical for; not worth it for a consumer uninstaller.

## Budget

Solo first-timer with SMAppService: 3-7 days. First working privileged delete ~0.5-1 day; the long tail is signing, notarization, approval UX, version-bump handling, caller-signature validation, and debug loop ergonomics. Costs include time learning `notarytool` failure modes and the launchd inspection commands.

## Gates this release

This is the last thing blocking public distribution. Without it the uninstaller cannot remove any app installed from a signed .pkg (most real apps), which is most of the product's stated value.


## Completed Slice - 2026-04-21

**Files changed:**
- Sources/GargantuaCore/Models/Uninstaller/PrivilegedUninstallRequest.swift
- Sources/GargantuaCore/Services/UninstallExecutor.swift
- Tests/GargantuaCoreTests/Services/UninstallExecutorTests.swift

**Key decisions:**
- Added a typed PrivilegedUninstallRequest boundary so future XPC helper calls receive a bounded plan instead of a raw item array.
- Updated UninstallExecutor to route existing, non-writable /Applications/*.app bundles through PrivilegedUninstallHelping while keeping writable app bundles on the ordinary NSWorkspace Trash path.
- Added filesystem-state injection for path existence and writability so privileged routing is testable without touching real /Applications fixtures.

**Verification:**
- swift test --filter UninstallExecutor passed.
- swift test passed: 851 tests.

**Remaining feature work:**
- Build/install the SMAppService daemon helper and plist.
- Add XPC listener/client implementation, caller code-signature validation, approval UX, signing/notarization scripts, and manual privileged-path test matrix.

---
*Auto-generated by PASIV*
