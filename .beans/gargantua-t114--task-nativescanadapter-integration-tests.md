---
# gargantua-t114
title: 'Task: NativeScanAdapter integration tests'
status: completed
type: task
priority: normal
created_at: 2026-04-17T02:00:03Z
updated_at: 2026-04-17T17:38:15Z
parent: gargantua-l9dk
---

PathExpander is well-covered in isolation, but there are no tests for NativeScanAdapter itself. Codex SC review of gargantua-guga called this out.

Should cover:
- profile scoping (devPurge produces only dev_artifacts/docker/homebrew results; light excludes dev rules)
- cross-rule path de-duplication
- cap-warning propagation through ScanProgress
- `rule.pattern` file filtering (e.g., `~/Downloads` + `*.dmg`)
- loadDefaults(profile:scanRoots:) override honored



## Summary of Changes

Added NativeScanAdapter integration coverage in `Tests/GargantuaCoreTests/Services/NativeScanAdapterTests.swift` for:
- profile scoping between Dev Purge and Light
- cross-rule path de-duplication
- `rule.pattern` file filtering
- PathExpander cap warning propagation through ScanProgress
- `loadDefaults(profile:scanRoots:)` scan roots override wiring

## Verification

- `swift test --filter NativeScanAdapter` passed: 5 tests
- `swift test` passed: 243 tests across 32 suites
- `swift build` passed
- `swiftlint lint` completed with 29 warnings, all pre-existing and not introduced by the new test file

## Review

SC review selected by workflow. Diff review found no blocking issues.
