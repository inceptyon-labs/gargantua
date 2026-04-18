---
# gargantua-cbi1
title: 'Uninstall UI polish: subtitle activity indicator, phase transition, sortable results'
status: completed
type: task
priority: normal
created_at: 2026-04-18T13:27:58Z
updated_at: 2026-04-18T13:37:16Z
---

Three UX issues on the Smart Uninstaller flow:

1. On bigger apps the scanning/executing phase feels stuck — the `⟳` next to the subtitle ("Surveying nearby star systems", "Crossing the event horizon") is a static glyph and the main accretion-disk indicator in the header is easy to miss. Need guaranteed motion next to the phase text.
2. Transition from the uninstall sequence to the results summary feels like it "pops up" — current `.opacity` fade at 0.30s reads as an instant cut to users.
3. Summary view shows only a count of succeeded items and a flat list of failed items with no sort control. User wants to inspect results sorted by name or size.

## Scope

- [x] Replace static `⟳` in EventHorizonConsoleView.subtitleLine with a small AccretionDiskView so motion is always adjacent to the phase text; add a subtle animated trailing ellipsis
- [x] In SmartUninstallerView.phaseTransition, use opacity+scale asymmetric transition with a longer duration; preserve reduce-motion fallback
- [x] In CleanupSummaryView, add name/size sort picker + disclosure to reveal sorted succeeded-items list; apply same sort to failed list
- [x] Verify existing tests still pass (no direct tests for these views)

## Summary of Changes

### Files changed
- `Sources/GargantuaCore/Views/SmartUninstaller/EventHorizonConsoleView.swift` — replaced the static `⟳` in the subtitle with a small `AccretionDiskView` (always frame-clocked so motion is present regardless of event volume) and added a TimelineView-driven 3-dot animated ellipsis gated to in-progress phases (`.loadingApps`, `.scanning`, `.executing`). Reduce-motion renders a static `…` in a matching fixed-width frame so toggling the accessibility setting doesn't shift the baseline.
- `Sources/GargantuaCore/Views/SmartUninstaller/SpaghettifyEventRow.swift` — new file. Extracted `SpaghettifyEventRow` and `SingularitySession` out of `EventHorizonConsoleView.swift` to get the file back under the 400-line lint threshold after my additions.
- `Sources/GargantuaCore/Views/SmartUninstaller/SmartUninstallerView.swift` — phase transition upgraded from `.opacity` / 0.30s to asymmetric `.opacity + .scale(0.97)` on insertion (outgoing still just fades) at 0.45s. Reduce-motion still collapses to `.identity`.
- `Sources/GargantuaCore/Views/CleanupSummaryView.swift` — added `SummarySort` enum (`.name`, `.size`), segmented sort picker with stable anchor in the success-section header (never jumps between sections on expand/collapse), size-sort uses name as deterministic tiebreaker, disclosure toggle to show/hide succeeded items in a scrollable (capped 180pt) inline list. Reduce-motion gates the disclosure animation. Accessibility: chevron hidden, sort picker labelled "Sort cleanup items".

### Review outcome

Ran an independent Codex review pass. Fixed:
- reduce-motion branch width mismatch on activity ellipsis
- `withAnimation` disclosure toggle bypassing reduce-motion
- sort picker relocating between success/failure sections on expand — now anchored in success header
- size-sort lacking deterministic tiebreaker
- chevron icon not marked decorative
- size-text layout priority so long app names truncate before the byte count does
- sort picker a11y label made more specific

Left open: `AccretionDiskView` always animates regardless of reduce-motion (pre-existing, out of scope); a couple soft `type_body_length` lint warnings on the two heaviest views (+4 to +7 lines over the 250 limit — would require extracting phase-string helpers into an extension).

### Verification
- `swift build` clean
- 452/452 tests pass
- `swiftlint` clean except the pre-existing body-length warnings noted above

### UI verification caveat

Could not visually verify on a running macOS app from this session — changes were validated only via build and test. Recommend launching the app and running an uninstall on a big app (e.g. Xcode, Chrome) to confirm: (1) ellipsis + disk motion visible during long scans, (2) fade+scale transition on executing→summary feels like a transition rather than a cut, (3) sort picker and Show items disclosure behave correctly with a partial-failure result.
