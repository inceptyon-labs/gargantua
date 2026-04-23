# Design Brief: Gargantua App Shell (Phase 1 MVP)

**Status:** Approved  
**Date:** April 14, 2026  
**Scope:** Full app shell — navigation frame + all Phase 1 screens

---

## 1. Feature Summary

The full application shell for Gargantua — a native macOS system cleaner for developers. Includes the navigation frame, Dashboard, Deep Clean, Dev Artifact Purge, Disk Explorer, and Settings. The shell must establish the product's identity immediately: this is a precision tool that devours junk, not a consumer cleaning app. Custom dark UI throughout — no system chrome beyond the traffic light window controls.

## 2. Primary User Action

**Assess and act.** The user opens Gargantua to answer: "How much junk do I have, and how fast can I safely remove it?" Every screen in the shell either answers that question or supports the answer.

## 3. Design Direction

Raycast's compact utility energy meets the Interstellar deep-space aesthetic from the design system. Custom-drawn dark UI that feels Mac-native in *behavior* (keyboard shortcuts, window management, snappy response) but owns its visual identity completely. The space theme isn't decoration — it's structure. Surfaces are void-dark. Elevation is lightness, not shadow. Safety colors (green/amber/red) are the warmest things in the interface.

Key qualities:
- **Compact, not cramped** — Raycast-density where every pixel earns its space, but with enough breathing room that it doesn't feel like a terminal
- **Fast-feeling** — Minimal animation, instant transitions, no loading spinners where content can be shown progressively
- **Tool, not product** — No marketing language in the UI. No "Get started!" No exclamation marks. The app respects the user's intelligence
- **Native in spirit** — Responds to system keyboard shortcuts, respects macOS window behaviors, feels like it belongs on a developer's Mac alongside Xcode and Terminal

Reference the established design system (`.interface-design/system.md`) for all token values: `--void` through `--surface-4` for elevation, `--safe`/`--review`/`--protected` for Trust Layer classification, `--accent` (Hawking blue) for interactive elements, confidence orbit rings as the signature element.

**Anti-goal:** Must NOT look like an Electron app. Must NOT look like CleanMyMac (glossy, consumer-y, marketing-forward). Must feel native, fast, lightweight.

**Reference energy:** Raycast — compact, fast, utility, dark, Mac-native feel.

## 4. Layout Strategy

**Window:** ~900x600 default, resizable. Custom title bar area (transparent system title bar with traffic lights inset, app title and global actions in the title bar region).

**Navigation (sidebar):**
- 200px width, `--void` background (same as canvas), right border separation
- Grouped sections with `--ink-4` uppercase labels: CLEAN, ANALYZE, TOOLS, CONFIGURE
- Icons: SF Symbols, 16px, monochrome `--ink-2`
- Active state: `--surface-2` background + 2px `--accent` left indicator
- Bottom: compact user/system badge showing macOS version + disk free space

**Content area:**
- `--void` background
- Content max-width ~720px on wider windows, but fills on standard width
- Section headers: 16px, 600 weight, `--ink`
- Dense list layouts for scan results, card layouts only for dashboard metrics

**Information hierarchy within each screen:**
1. Screen identity (what am I looking at)
2. Primary metric or action (the number or the button)
3. Supporting data (the detail that builds trust)
4. Secondary actions (settings, filters, export)

## 5. Key States

### Dashboard
- **Default:** Health score gauge (0-100) centered as the anchor. Reclaimable space summary. Actionable alerts as a dense list below. Hardware info and engine status as compact footer bar.
- **Scanning:** Health score animating, scan progress in the alert area, results populating live
- **Healthy (nothing to clean):** Score at 95-100, green tint, "Your Mac is clean" — not an empty state, a success state
- **Degraded (engine error):** Engine status bar turns amber with specific error, app remains functional

### Deep Clean / Dev Artifact Purge (scan results)
- **Pre-scan:** Category list with estimated sizes from last scan (if available), prominent "Scan" button
- **Scanning:** Live progress — categories lighting up as scanned, items populating in real-time
- **Results (primary):** Three-bucket split, all dense. Safe items expanded and pre-selected. Review items expanded but not selected. Protected items shown, locked, dimmed.
- **Empty scan:** "No items found in [category]. Your Mac is already clean here."
- **Error:** Specific error per category ("Native scan timed out after 30s. Retry or check Tools > Engine Status."), other categories still functional
- **Post-clean:** Summary of what was removed, sizes freed, audit trail link

### Disk Explorer
- **Default:** Treemap or sorted list of disk consumers
- **Loading:** Progressive — show top-level volumes immediately, drill down loads on expand
- **Permission denied:** Specific paths grayed out with "Requires Full Disk Access" inline

### Settings
- **Default:** Grouped list, similar to macOS System Settings density but with Gargantua's dark chrome
- **Sections:** Cleanup profiles (list + edit), Scan rules (YAML viewer for bundled rules plus community-contribution visibility), Whitelists (add/remove), Tool versions (status indicators), AI config (tier selector + model download), MCP (running/stopped toggle), Audit log (scrollable timeline)

### Global States
- **First launch:** Permission onboarding flow — one screen per permission, explains exactly what it unlocks, "Skip" is always available, no guilt
- **No Full Disk Access:** Banner at top of relevant screens (not a modal, not blocking) explaining what's limited
- **Update available:** Subtle badge in sidebar, not a modal

## 6. Interaction Model

**Navigation:** Click sidebar items. Keyboard: Cmd+1 through Cmd+5 for main sections. Cmd+, for Settings (macOS convention).

**Scan flow:** Click "Scan" -> results populate live -> review buckets -> select/deselect items -> "Clean" -> confirmation dialog -> execution -> summary. The entire flow happens in-place, no modal steps until confirmation.

**Item interaction:** Click row to select/deselect. Hover reveals "?" explain button (triggers AI Tier 1 or YAML explanation). Right-click for context menu: reveal in Finder, copy path, whitelist, view rule.

**Confirmation dialog:** Modal only for the final "Clean" action. Lists exact items being cleaned, total size, method (Trash vs delete). Destructive button is `--protected` colored. Cancel is always the visually dominant escape route.

**Keyboard-first:** Tab through items, Space to select, Enter to confirm, Escape to cancel. Arrow keys navigate the list. Cmd+A selects all safe items.

## 7. Content Requirements

### Dashboard copy
- Health score label: just the number (85) with "Health" as caption
- Reclaimable: "34.2 GB reclaimable" — no "You can free up!" language
- Alerts: declarative statements. "23 GB of stale dev artifacts (>30 days)" not "We found dev artifacts you might want to clean!"
- Hardware: "MacBook Pro M4 . macOS 15.2 . 380 / 500 GB used"

### Scan results copy
- Bucket headers: "Safe to Clean . 18.2 GB" / "Review Required . 5.3 GB" / "Protected . 3 items"
- Item: name, size (monospace, right-aligned), file path (truncated, monospace), confidence orbit, one-line explanation
- Explanation tone: factual. "Browser cache files. Regenerated automatically." Not "These files are safe because..."

### Empty states
Factual, not emotional. "No developer artifacts found." Period. No illustrations. No "Nothing to see here!"

### Error messages
Specific and actionable. "Native scan timed out after 30s. Retry or check Tools > Engine Status." Not "Something went wrong."

### Confirmation dialog
"Clean 45 items (18.2 GB) . Move to Trash" with itemized list below.

## 8. Recommended References

For implementation, consult:
- `spatial-design.md` — Layout structure, sidebar proportions, content area rhythm
- `interaction-design.md` — Scan flow, keyboard navigation, confirmation patterns
- `motion-design.md` — Minimal: scan progress animation, list population, state transitions
- `color-and-contrast.md` — Safety palette contrast ratios on dark surfaces, accessible text hierarchy
- `typography.md` — Monospace data formatting, tabular numbers, type scale application

## 9. Open Questions

1. **Window style:** Full custom titlebar (like Raycast) or transparent titlebar with inset traffic lights (like Tower)? Both are valid for a custom dark UI.
2. **Disk Explorer visualization:** Treemap (like GrandPerspective/WinDirStat) or sorted list with size bars? Treemap is more powerful but harder to implement well. PRD says "SwiftUI treemap view" for Phase 2 — for Phase 1, a sorted expandable list may be sufficient.
3. **Sidebar collapse:** Should the sidebar be collapsible to icons-only for smaller windows? At 900px default with 200px sidebar, that's 700px for content — likely sufficient.
4. **Menu bar widget (Phase 3):** Worth shaping the app shell to accommodate a detached menu bar popover later, or design that when it arrives?
