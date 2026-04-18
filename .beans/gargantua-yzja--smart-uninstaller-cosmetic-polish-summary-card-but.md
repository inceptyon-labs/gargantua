---
# gargantua-yzja
title: 'Smart Uninstaller cosmetic polish: summary card, buttons, error state'
status: completed
type: task
priority: normal
created_at: 2026-04-18T12:50:08Z
updated_at: 2026-04-18T13:03:44Z
---

Three independent cosmetic improvements surfaced while reviewing the Smart Uninstaller surface post-transition-fix. Each is small and can be done independently; grouped here because they're all visible polish on the same feature.

## 1. Summary layout: integrate heading into the card

Currently `SmartUninstallerView.summaryState` renders the outcome heading and flavor line as a loose `VStack` floating above `CleanupSummaryView`. It looks disconnected — two stacked cards with unrelated visual weights.

Tighter treatment: pull the heading + flavor line *into* the `CleanupSummaryView` card header, or give the card a colored top-border (accretion amber / protected red) keyed to outcome so the heading feels like a banner for the card rather than a label hovering above it.

- [x] Heading + flavor line visually bound to the summary card (banner, top-border, or moved into the card header)
- [x] Outcome color visible on the card itself (success green / partial amber / failure red) — not just the heading text
- [x] Reduce-motion: no new animation added here; static visual treatment only

## 2. Confirmation modal buttons match Gargantua button system

`ConfirmationModalView` (when present) has Done / Cancel-style buttons that don't match the accent-button treatment used in `CleanupSummaryView.footerActions` (the "Done" button at right) or the picker surfaces. Audit + align.

- [x] Primary action uses `GargantuaColors.accent` background, white label, `GargantuaRadius.small`, standard padding
- [x] Destructive action (if any) uses `GargantuaColors.protected_` background
- [x] Secondary / cancel uses border-outlined treatment matching "Reveal Trash" in the summary footer
- [x] Focus ring respects `GargantuaColors.borderFocus`
- [x] No behavior change — purely visual

## 3. Error state (`.failed(message:)`) matches console aesthetic

`SmartUninstallerView.errorState` renders a plain SF Symbol, heading, message, and button on void background. Compared to the Event Horizon Console / summary polish, it feels like a dropped ball — generic SwiftUI modal instead of space-horror aesthetic.

Bring it up to the bar. Treat it as a "catastrophic signal lost" state: uppercase tracked heading (`SIGNAL LOST`), italic flavor body, dim mono detail for the underlying error, retry button matching the accent system.

- [x] Heading uses `GargantuaFonts.sectionLabel` with tracking, `protected_` color
- [x] Body uses italic flavor line above the raw error message
- [x] Raw error surfaced in `GargantuaFonts.monoPath` / `ink3` so it reads as diagnostic detail, not user-facing copy
- [x] Retry button matches the button system from item 2
- [x] Layout respects `maxWidth: 480` so long error messages don't stretch full-screen

## Acceptance (overall)

- [x] All 3 sections complete
- [x] Tests: add at least one unit test covering any pure logic extracted (e.g., outcome → color mapping helper if introduced)
- [x] Lint/build/tests all green

## Non-goals

- New animations beyond what's already there (spaghettify, phase crossfade)
- Refactoring the underlying `CleanupSummaryView` (used by Deep Clean too — out of scope)
- Any change to the button-system tokens in `DesignTokens.swift`

## Summary of Changes

1. **Summary banner** — `CleanupSummaryView` gains a defaulted `outcomeAccent: Color?` param that renders a 3px colored bar at the top of the card (decorative, `accessibilityHidden`). `SmartUninstallerView.summaryState` passes the outcome-keyed color (safe/accretion/protected) and tightens heading↔card spacing so they read as a single unit. Deep Clean / DevArtifact callers unchanged (default nil).

2. **Confirmation buttons** — `ConfirmationButtons` primary bg is now `accent` for non-destructive trash and `protected_` for delete; both buttons gain standard horizontal padding and a `@FocusState` 2px `borderFocus` stroke; stale-focus reset on disable.

3. **Error state** — `.failed` phase redone: tracked "SIGNAL FAILED" heading (with natural-language a11y label), italic flavor line, raw error in dim mono in a subtle surface2 chip (`.textSelection(.enabled)` so users can copy), retry button matches the accent system with its own focus ring, maxWidth: 480.

4. **Testable piece** — `SingularityCloseMessage.Outcome.accent` returns a semantic `OutcomeAccent` role mapped to colors at the view layer. Unit test guards the mapping.

Review: SC cascade. Sonnet caught a11y and stale-focus issues (fixed). Codex caught the error-state button missing the focus ring (fixed) and a pre-existing 'SIGNAL LOST banner over Partially Complete card' contradiction — filed as follow-up since CleanupSummaryView refactor was an explicit non-goal.

Commits: 0246b9c, a897f47, 351e397
