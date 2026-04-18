---
# gargantua-cbi1
title: 'Uninstall UI polish: subtitle activity indicator, phase transition, sortable results'
status: in-progress
type: task
priority: normal
created_at: 2026-04-18T13:27:58Z
updated_at: 2026-04-18T13:27:58Z
---

Three UX issues on the Smart Uninstaller flow:

1. On bigger apps the scanning/executing phase feels stuck — the `⟳` next to the subtitle ("Surveying nearby star systems", "Crossing the event horizon") is a static glyph and the main accretion-disk indicator in the header is easy to miss. Need guaranteed motion next to the phase text.
2. Transition from the uninstall sequence to the results summary feels like it "pops up" — current `.opacity` fade at 0.30s reads as an instant cut to users.
3. Summary view shows only a count of succeeded items and a flat list of failed items with no sort control. User wants to inspect results sorted by name or size.

## Scope

- [ ] Replace static `⟳` in EventHorizonConsoleView.subtitleLine with a small AccretionDiskView so motion is always adjacent to the phase text; add a subtle animated trailing ellipsis
- [ ] In SmartUninstallerView.phaseTransition, use opacity+scale asymmetric transition with a longer duration; preserve reduce-motion fallback
- [ ] In CleanupSummaryView, add name/size sort picker + disclosure to reveal sorted succeeded-items list; apply same sort to failed list
- [ ] Verify existing tests still pass (no direct tests for these views)
