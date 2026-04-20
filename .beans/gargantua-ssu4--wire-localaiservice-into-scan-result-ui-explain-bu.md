---
# gargantua-ssu4
title: Wire LocalAIService into scan result UI (Explain button)
status: in-progress
type: feature
priority: normal
created_at: 2026-04-20T19:42:51Z
updated_at: 2026-04-20T20:05:38Z
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

- [x] `MainContentView` owns a shared `LocalAIService` that all scan views can invoke.
- [x] `AIExplanationSheet` (or popover) exists with Loading / Loaded / Error / Cancel states.
- [x] Hover-revealed Explain button on `DenseScanItemRow` fires and opens the sheet in Deep Clean.
- [x] `FileHealthView` context-menu "Explain" fires and opens the sheet.
- [x] `DuplicateFinderView` and `DevArtifactScanView` paths do the same.
- [x] With no model on disk, the sheet shows the YAML rule explanation labelled as such + "Download model" CTA.
- [ ] Manual smoke: click Explain on a scan result → real AI-generated text appears → closes the sheet returns to list.


## Summary of Changes

- New `AIExplanationController` (`Sources/GargantuaCore/Services/`) — `@MainActor` `ObservableObject` that wraps `AIServiceProtocol` with `loading` / `loaded` / `failed` presentation state; synthesizes a `ScanRule` from a `ScanResult` via a pure derivation helper, so the engine receives the metadata it needs without any schema change. Cancellation-safe: a new `explain()` supersedes an in-flight one, and `dismiss()` cancels the underlying task.
- New `AIExplanationSheet` (`Sources/GargantuaCore/Views/`) — sheet view with spinner during generation, AI-generated / YAML-rule source badge on the result, Retry on error, and a "Download Model" CTA when the YAML fallback fires because no model is staged (routes the sidebar to Settings).
- `MainContentView` now owns one `ModelDownloadManager`, one `LocalAIService` (wired to `MLXInferenceEngine`), and one `AIExplanationController` as `@StateObject` — shared across Settings' download button and every scan view's Explain handler. Presents the sheet at the top level via `.sheet(item:)` so any screen can trigger it.
- `DeepCleanView` and `DevArtifactScanView` gained an optional `onExplain:` parameter (nil-default, backwards-compat) and thread it into their `ScanBucketListView`. `DuplicateFinderContainerView` and `FileHealthContainerView` already had the hook — their callers now supply one.
- `SettingsView` accepts an injected `ModelDownloadManager` so the download state observed in Settings is the same instance the scan views consult; the parameterless init stays for previews.
- 6 new `AIExplanationControllerTests` covering `derivedRule`, state transitions, cancel-on-dismiss, newest-request-wins, and `isBusy`. 773 tests total pass; debug + release builds green; swiftlint clean on new files.

## Manual Smoke Left Open

Last acceptance criterion requires a user to click Explain in the running app. Build + launch Gargantua, run a Deep Clean, hover any scan row — the "?" Explain button reveals on hover and opens the sheet with real AI-generated text. Same button via context-menu on File Health, and via the hover button in Duplicate Finder / Dev Purge.
