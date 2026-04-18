---
# gargantua-yzja
title: 'Smart Uninstaller cosmetic polish: summary card, buttons, error state'
status: in-progress
type: task
priority: normal
created_at: 2026-04-18T12:50:08Z
updated_at: 2026-04-18T12:52:26Z
---

Three independent cosmetic improvements surfaced while reviewing the Smart Uninstaller surface post-transition-fix. Each is small and can be done independently; grouped here because they're all visible polish on the same feature.

## 1. Summary layout: integrate heading into the card

Currently `SmartUninstallerView.summaryState` renders the outcome heading and flavor line as a loose `VStack` floating above `CleanupSummaryView`. It looks disconnected — two stacked cards with unrelated visual weights.

Tighter treatment: pull the heading + flavor line *into* the `CleanupSummaryView` card header, or give the card a colored top-border (accretion amber / protected red) keyed to outcome so the heading feels like a banner for the card rather than a label hovering above it.

- [ ] Heading + flavor line visually bound to the summary card (banner, top-border, or moved into the card header)
- [ ] Outcome color visible on the card itself (success green / partial amber / failure red) — not just the heading text
- [ ] Reduce-motion: no new animation added here; static visual treatment only

## 2. Confirmation modal buttons match Gargantua button system

`ConfirmationModalView` (when present) has Done / Cancel-style buttons that don't match the accent-button treatment used in `CleanupSummaryView.footerActions` (the "Done" button at right) or the picker surfaces. Audit + align.

- [ ] Primary action uses `GargantuaColors.accent` background, white label, `GargantuaRadius.small`, standard padding
- [ ] Destructive action (if any) uses `GargantuaColors.protected_` background
- [ ] Secondary / cancel uses border-outlined treatment matching "Reveal Trash" in the summary footer
- [ ] Focus ring respects `GargantuaColors.borderFocus`
- [ ] No behavior change — purely visual

## 3. Error state (`.failed(message:)`) matches console aesthetic

`SmartUninstallerView.errorState` renders a plain SF Symbol, heading, message, and button on void background. Compared to the Event Horizon Console / summary polish, it feels like a dropped ball — generic SwiftUI modal instead of space-horror aesthetic.

Bring it up to the bar. Treat it as a "catastrophic signal lost" state: uppercase tracked heading (`SIGNAL LOST`), italic flavor body, dim mono detail for the underlying error, retry button matching the accent system.

- [ ] Heading uses `GargantuaFonts.sectionLabel` with tracking, `protected_` color
- [ ] Body uses italic flavor line above the raw error message
- [ ] Raw error surfaced in `GargantuaFonts.monoPath` / `ink3` so it reads as diagnostic detail, not user-facing copy
- [ ] Retry button matches the button system from item 2
- [ ] Layout respects `maxWidth: 480` so long error messages don't stretch full-screen

## Acceptance (overall)

- [ ] All 3 sections complete
- [ ] Tests: add at least one unit test covering any pure logic extracted (e.g., outcome → color mapping helper if introduced)
- [ ] Lint/build/tests all green

## Non-goals

- New animations beyond what's already there (spaghettify, phase crossfade)
- Refactoring the underlying `CleanupSummaryView` (used by Deep Clean too — out of scope)
- Any change to the button-system tokens in `DesignTokens.swift`
