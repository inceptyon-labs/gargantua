---
# gargantua-dr23
title: 'Trash cleanup fails: delete tries to remove ~/.Trash directory itself'
status: in-progress
type: bug
priority: high
created_at: 2026-04-18T02:32:37Z
updated_at: 2026-04-18T02:33:59Z
---

## Symptoms

User ran Deep Clean with a single 29 GB "Trash" result selected, chose **Delete Permanently**, and got:

- "Cleanup Partially Complete — 0 bytes freed"
- "1 item failed — \"Trash\" couldn't be removed because you don't have permission to access it."

See screenshots in original report (2026-04-17).

## Root cause

Two bugs compound:

### 1. YAML rule targets the Trash container, not its contents
`Sources/GargantuaCore/Resources/cleanup_rules/system/trash.yaml:5` sets `paths: ["~/.Trash"]`. The scanner presents `~/.Trash` itself as a single scan result, so at cleanup time `CleanupEngine.deleteSingle` ends up calling `FileManager.default.removeItem(at: ~/.Trash)` — which macOS refuses (removing the user's Trash container is not permitted; even the `.trash` method would try to move Trash into itself).

### 2. CleanupEngine has no special case for the Trash container
`Sources/GargantuaCore/Services/CleanupEngine.swift:113-124` (`deleteSingle`) blindly calls `FileManager.removeItem` on whatever URL it was given. For Trash, this should instead iterate `~/.Trash` and remove the children (i.e. empty the Trash). Same problem for the `.trash` (`recycle`) method — you can't trash items that are already in Trash.

## Proposed fix (smallest viable)

Pick one of:

**A. Glob the rule** — change `trash.yaml` to `paths: ["~/.Trash/*"]` so each top-level item in Trash becomes its own scan result. `PathExpander` already supports this. Downside: a Trash with hundreds of items becomes hundreds of scan rows.

**B. Special-case in CleanupEngine** — keep the rule as-is so the UI shows one "Trash — 29 GB" item. When the cleanup target path resolves to `~/.Trash`, enumerate its children and remove each instead of the container. Simultaneously make `.trash` (recycle) a no-op/force-delete for items already under `~/.Trash`. Preferred — preserves the "empty the trash" UX.

## Acceptance criteria

- [ ] Deep Clean → Delete Permanently on the Trash item actually empties `~/.Trash` (all children removed, container kept)
- [ ] Cleanup summary reports bytes freed equal to the sum of removed children
- [ ] Items already inside `~/.Trash` cannot use the "Move to Trash" method (UI-hidden or force-delete fallback)
- [ ] If the app lacks permission to enumerate/remove Trash contents (TCC / Full Disk Access not granted), surface a clear actionable error instead of a generic "permission denied"
- [ ] Regression test: `CleanupEngineTests` covers the Trash-container delete path using a temp-directory stand-in
- [ ] No regression for non-Trash paths (still uses the existing removeItem flow)

## Files likely involved

- `Sources/GargantuaCore/Resources/cleanup_rules/system/trash.yaml`
- `Sources/GargantuaCore/Services/CleanupEngine.swift`
- `Tests/GargantuaCoreTests/Services/CleanupEngineTests.swift`
- Possibly `CleanupMethodPresentation` to hide "Move to Trash" for items under `~/.Trash`

## Environment

- macOS 14, app not sandboxed (no `.entitlements` in repo)
- Deep Clean scan, grouped result view
- Cleanup method: Delete Permanently
