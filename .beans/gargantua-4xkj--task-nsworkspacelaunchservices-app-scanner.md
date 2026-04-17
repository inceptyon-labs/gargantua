---
# gargantua-4xkj
title: 'Task: NSWorkspace/LaunchServices app scanner'
status: in-progress
type: task
priority: high
created_at: 2026-04-17T21:49:38Z
updated_at: 2026-04-17T22:41:08Z
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
