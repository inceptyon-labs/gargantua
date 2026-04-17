---
# gargantua-guga
title: 'Feature: Wire Dev Purge to native dev-artifact scanner'
status: in-progress
type: feature
priority: critical
created_at: 2026-04-17T01:06:45Z
updated_at: 2026-04-17T01:46:30Z
parent: gargantua-l9dk
---

Replace MoPurgeAdapter in the Dev Artifact Purge view with a native scanner path that walks configured project roots for glob rules like node_modules, .gradle, target, DerivedData, etc.

## Acceptance Criteria
- [ ] `MainContentView.swift:57-60` — `DevArtifactScanView(adapter:)` no longer takes `MoPurgeAdapter`
- [ ] Native dev-artifact scan honors the `dev_artifacts`, `docker`, `homebrew` categories from `CleanupProfile.developer`
- [ ] Glob rules like `**/node_modules` actually match — requires bounded glob walker (sibling task)
- [ ] User-configurable scan roots (parity with `mo purge --paths`) default to: `~/Projects`, `~/GitHub`, `~/dev`, `~/www` (whatever exist) — persisted in SwiftData
- [ ] Confirmation + `CleanupEngine` flow unchanged
- [ ] `swift build` clean; smoke test finds at least one node_modules result on this machine

## Wiring Checklist
- [ ] Update `MainContentView.swift:57-60` to construct a native-backed adapter
- [ ] Update `DevArtifactScanView.swift` init + scan trigger
- [ ] Add scan-roots setting to SwiftData + Settings UI (or reuse existing profiles screen)
- [ ] Route scan through `NativeScanAdapter` (possibly with a "roots" parameter added to its signature)
- [ ] Delete / deprecate `MoPurgeAdapter` once no callers remain

## Out of Scope
- Glob walker implementation itself (separate task)
- Homebrew / Docker sub-commands (Phase 2 feature per PRD §11)
