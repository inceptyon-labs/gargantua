---
# gargantua-72yf
title: 'Confirm Cleanup modal: rows render at huge fixed height when not scrolling'
status: completed
type: bug
priority: high
created_at: 2026-04-18T15:53:46Z
updated_at: 2026-04-18T15:53:46Z
parent: gargantua-6383
---

## Symptom

When a Confirm Cleanup modal contains a small number of items (1–10), each `ConfirmationItemRow` renders ~250pt tall with the text vertically centered in mostly-empty space. Visible in screenshots from the Smart Uninstaller summary tier (gargantua-2g77 vibetunnel example).

## Root Cause

`ConfirmationItemRow` and `AcknowledgeableItemRow` placed the safety-color bar as a sibling `Rectangle()` inside an `HStack`. `Rectangle()` has no intrinsic height and is greedy in both axes. When the row sits inside a non-scrolling `VStack` (the `else` branch in `SummaryDialogContent.reviewItemList` for `count <= 10`), SwiftUI treats each row as a flexible-vertical child and divides the parent VStack's available height equally between them.

`SummaryDialogContent` only wrapped the list in a `ScrollView { ... }.frame(maxHeight: 300)` for `reviewItems.count > 10`, so the small-count case had nothing to constrain row heights.

## Fix

Refactored both row variants to render the safety bar as an `.overlay(alignment: .leading) { Rectangle().fill(safetyColor).frame(width: 3) }` instead of as an HStack sibling. The row's height is now driven by its content (text + 16pt vertical padding) and the bar fills the row's actual height through the overlay.

## Verification

- swift build clean.
- 452/452 tests passing.
- Manual: rows now render ~50pt tall regardless of how many items are in the list.
