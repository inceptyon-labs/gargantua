---
# gargantua-0q30
title: 'Feature: File Health via czkawka_cli'
status: completed
type: feature
priority: high
created_at: 2026-04-17T18:07:38Z
updated_at: 2026-04-20T00:40:40Z
parent: gargantua-qe4a
---

Integrate czkawka_cli for similar images/videos, large files, empty files/folders, broken symlinks, temp files, and corrupted files. Map findings through Trust Layer safety defaults.



## Summary of Changes

All three child Tasks shipped. File Health is end-to-end:

- **gargantua-c6s7** — Phase 2 `CzkawkaAdapter` wraps `czkawka_cli`, parses per-category output, maps findings to Trust Layer defaults with injectable `ProcessRunner` for testability.
- **gargantua-o8b5** — File Health UI panel surfaces all eight czkawka categories as safe-first tabs with partial-failure warnings, stale-tab protection, and scan cancellation on view disappear.
- **gargantua-i36a** — `CzkawkaAdapter` findings now route through `SafetyClassifier`, picking up profile-level overrides (age-based auto-safe, etc.) with the same category-gating semantics as `NativeScanAdapter`.

### Deferred / follow-on work
- File Health destructive "Send to Trash" action via `ConfirmationModalView`.
- Per-item selection UI (checkboxes).
- Shared `ScanResult.applying(classified:)` helper to DRY the classifier→ScanResult reconstruction pattern across `NativeScanAdapter` and `CzkawkaAdapter`.
