---
# gargantua-fuml
title: Build YAML rule viewer and whitelist editor
status: completed
type: task
priority: normal
tags:
    - area:frontend
    - pasiv
    - size:M
created_at: 2026-04-15T00:49:31Z
updated_at: 2026-04-16T00:05:19Z
parent: gargantua-5hch
---

Read-only rule viewer with syntax highlighting. Whitelist add/remove interface.

## Acceptance Criteria
- [x] Rule viewer: browse rules by category (browser/, developer/, system/)
- [x] Syntax highlighting for YAML content
- [x] Rule detail: shows safety level, confidence, explanation, source
- [x] Whitelist: add path/pattern via text input
- [x] Whitelist: remove existing entries
- [x] Whitelist persists via SwiftData

---
**Size:** M

## Summary of Changes\n\nAdded YAML rule viewer and whitelist editor (commit c918e72):\n- RuleViewerView with category browser (browser/developer/system)\n- YAML syntax highlighting with color-coded keys, values, safety levels\n- Rule detail pane: safety badge, confidence, source, paths, excludes\n- Whitelist management: add/remove path patterns persisted via SwiftData\n- PersistedWhitelistEntry model + CRUD in PersistenceController\n- Wired into sidebar under CONFIGURE section
