---
# gargantua-i36a
title: 'Task: Wire CzkawkaAdapter through SafetyClassifier for composed Phase 2 scans'
status: completed
type: task
priority: high
created_at: 2026-04-18T22:18:23Z
updated_at: 2026-04-20T00:40:26Z
parent: gargantua-0q30
blocked_by:
    - gargantua-c6s7
---

Extend SafetyClassifier (or its composition point) so CzkawkaAdapter findings run through the same Trust Layer overrides (age-based, protected paths, etc.) currently applied only at NativeScanAdapter. Child task gargantua-c6s7 notes: 'Czkawka adapter produces base classifications only. Can be added when Phase 2 UI composes multiple adapters.' Reference: Sources/GargantuaCore/Services/SafetyClassifier.swift, CzkawkaAdapter.swift.



## Summary of Changes

Wired `CzkawkaAdapter` output through `SafetyClassifier` so czkawka findings honour the same profile-driven Trust Layer overrides (age-based auto-safe, etc.) that `NativeScanAdapter` applies to YAML-driven rule results.

### New files
- `Tests/GargantuaCoreTests/Services/SafetyClassifierRulelessTests.swift` — 5 tests covering the new rule-less classify overload (no match, profile age override, adapter-override precedence, nil lastAccessed, recent-file no-op).
- `Tests/GargantuaCoreTests/Services/CzkawkaAdapterClassifierTests.swift` — 5 tests covering adapter-level profile wiring: no-profile back-compat, deep-profile downgrade for in-scope `similar_images` > 7d, recent `similar_images` stays review, out-of-scope `big_files` under developer stays review (category gating), light-profile no-op.

### Modified files
- `Sources/GargantuaCore/Services/SafetyClassifier.swift` — New `classify(result:ruleOverrides:profile:now:)` overload reads base safety/confidence/explanation from the `ScanResult` itself, so adapters without a `ScanRule` (Czkawka, Fclones) can reach the same override pipeline.
- `Sources/GargantuaCore/Services/CzkawkaAdapter.swift` — Added optional `profile: CleanupProfile?` + `classifier: SafetyClassifier` init params (default `nil` preserves prior behaviour). In `makeResult`, routes the base ScanResult through the classifier when a profile is set AND the finding's category is in `profile.categories` (or the profile has no categories). Matches NativeScanAdapter semantics: findings outside the profile's scope keep base Trust Layer defaults.
- `Sources/GargantuaCore/Views/FileHealthContainerView.swift` — Accepts a `CleanupProfile` (default `.deep`) and threads it into the default engine factory which now passes it into `CzkawkaAdapter.autoDetect`.
- `Sources/Gargantua/MainContentView.swift` — Passes `activeDeepCleanProfile` to `FileHealthContainerView` so File Health shares the same profile resolution as Deep Clean.

### Review
- SC pipeline: Sonnet + Codex (per .pasiv.yml size:M default).
- Codex flagged two WARNINGs, both fixed:
  1. Test fixture was only setting `.modificationDate` and relying on APFS atime-disabled fallback; test helper now uses `utimes(2)` via `Darwin` to stamp both atime and mtime explicitly, and the key test asserts `lastAccessed != nil` before testing the override so silent fallback failures can't pass.
  2. Applying profile-level overrides to all czkawka categories drifted from NativeScanAdapter's `profile.categories` gate; added category gating in `makeResult` so overrides are only applied to findings whose category is in the active profile's scope.
- Codex SUGGESTIONs (public `engineFactory` signature change, `ScanResult` reconstruction helper) deferred — internal module, no package clients; reconstruction pattern matches existing NativeScanAdapter style and can be DRY'd in a later refactor if `ScanResult` gains fields.

### Stats
- Full suite: 691/691 passing (+10 new tests).
- Lint: clean on all touched files.

### Deferred / not in this bean
- Destructive "Send to Trash" action for File Health (depends on `ConfirmationModalView` routing; same reason Duplicate Finder's `onSendToTrash` is `nil` today).
- Per-item selection UI.
- A `ScanResult.applying(classified:)` helper to replace the manual reconstruction in both `NativeScanAdapter` and `CzkawkaAdapter` — non-blocking, can land alongside next `ScanResult` schema change.
