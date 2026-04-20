---
# gargantua-ssu4
title: Wire LocalAIService into scan result UI (Explain button)
status: in-progress
type: feature
priority: normal
created_at: 2026-04-20T19:42:51Z
updated_at: 2026-04-20T19:48:33Z
---

## Context

`LocalAIService` is implemented, tested, and the scan views (`ScanBucketListView`, `DenseScanItemRow`, `FileHealthView`) already accept an `onExplain: ((ScanResult) -> Void)?` callback surface. But every top-level container (`DeepCleanView`, `DevArtifactScanView`, `DuplicateFinderContainerView`, `FileHealthContainerView`) passes `nil` — so the hover-revealed Explain button on `DenseScanItemRow` and the "Explain" context-menu item on `FileHealthView` never render. The AI download now works (gargantua-lyc1) but there's no UI to actually trigger inference.

## Scope

1. Introduce a shared `LocalAIService` owner at the app level — probably a `@StateObject` on `MainContentView` backed by `MLXInferenceEngine` and the app's `ModelDownloadManager`. One instance per app launch; respects the existing idle-unload lifecycle.
2. Build an `AIExplanationSheet` (sheet or popover) that:
   - Shows "Generating…" with a cancel button while the engine runs.
   - Renders the returned `AIExplanation.text`, clearly labelled AI vs YAML-rule fallback.
   - Surfaces errors (e.g. model not loaded, RAM guard tripped) via a readable message.
3. Derive a synthetic `ScanRule` from a `ScanResult` at the call site (every field `explain` consumes is already on `ScanResult`). No schema change.
4. Wire `onExplain` handlers on the four top-level containers so the hover button / context menu actually fires.
5. If no model is downloaded, the button should still work and surface the YAML rule text (current `LocalAIService` fallback behavior), with a secondary CTA to open Settings.

## Out of scope

- New engine selection settings (`gargantua-6xce`).
- Rewriting the grouping / detail UI — reuse what's there.
- Streaming token-by-token rendering. V1 shows the whole response when done.

## Acceptance

- [ ] `MainContentView` owns a shared `LocalAIService` that all scan views can invoke.
- [ ] `AIExplanationSheet` (or popover) exists with Loading / Loaded / Error / Cancel states.
- [ ] Hover-revealed Explain button on `DenseScanItemRow` fires and opens the sheet in Deep Clean.
- [ ] `FileHealthView` context-menu "Explain" fires and opens the sheet.
- [ ] `DuplicateFinderView` and `DevArtifactScanView` paths do the same.
- [ ] With no model on disk, the sheet shows the YAML rule explanation labelled as such + "Download model" CTA.
- [ ] Manual smoke: click Explain on a scan result → real AI-generated text appears → closes the sheet returns to list.
