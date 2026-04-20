---
# gargantua-m9y3
title: 'File Health: per-item selection (checkboxes)'
status: todo
type: task
priority: normal
created_at: 2026-04-20T23:00:08Z
updated_at: 2026-04-20T23:00:08Z
parent: gargantua-qe4a
---

`FileHealthView` currently renders czkawka findings grouped by category with no per-item selection — there is no way to pick which findings to act on. Prerequisite for the Send-to-Trash action (see sibling task).

Defer/follow-on work noted in `gargantua-0q30` summary; never got filed as its own bean. Filing now.

## Scope

- Add a `Set<String>` of selected result ids, mirroring `DeepCleanSessionState.selectedResultIDs`, owned by `FileHealthContainerView` or a session-state struct.
- Render a checkbox per row in `FileHealthView`. Use `DenseScanItemRow` or a Health-specific compact row — consistency with Deep Clean is preferred.
- Default selection state: matches Trust Layer defaults (safe-tier pre-selected, review/protected not pre-selected), same policy Deep Clean uses.
- Category tabs should surface per-category total-selected / total-bytes counts in the tab header so users see the impact before switching categories.
- Read-only categories (where czkawka findings are always advisory, e.g., Similar Images for a first pass) can be marked non-selectable if appropriate; otherwise every tier is selectable subject to safety gating.

## Out of scope

- The destructive action itself (Send-to-Trash via `ConfirmationModalView`) — tracked by sibling bean. This task lands the selection UI; the action wires in next.

## Acceptance

- [ ] Checkbox per row in every File Health category tab
- [ ] Selection state defaults follow Trust Layer safety tiers
- [ ] Per-tab selected-count and reclaimable-bytes visible in tab header
- [ ] Selection persists across tab switches within a single scan session
- [ ] Tests cover default-selection policy and cross-tab selection persistence
