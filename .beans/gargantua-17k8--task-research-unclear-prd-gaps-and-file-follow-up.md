---
# gargantua-17k8
title: 'Task: Research unclear PRD gaps and file follow-up beans'
status: todo
type: task
priority: normal
created_at: 2026-04-23T20:55:27Z
updated_at: 2026-04-23T20:55:27Z
---

Investigate PRD items whose implementation status couldn't be determined from a surface scan. For each, either confirm it's done (mark this todo item ✅ and cite the code) or file a new bean and link it here.

## Items to investigate

- [ ] **Native SwiftUI treemap view (PRD §5.5)** — Disk Explorer exists; verify whether it renders a proper treemap (weighted rectangles) or only a folder list. Check Views related to Disk Explorer. If missing, file a feature bean.
- [ ] **Whitelists settings pane (PRD §5.2)** — Rule viewer/editor shipped; confirm whether there is a dedicated Settings → Whitelists UI for user-managed whitelist entries, distinct from the YAML rule editor. If missing, file a feature bean.
- [ ] **czkawka broken symlinks feature (PRD §4.2)** — Confirm the czkawka adapter actually exposes broken-symlink detection end-to-end (scan → UI → cleanup) with proper safety classification. If partial, file a bean for the missing piece.
- [ ] **Finder Automation TCC fallback (PRD §9)** — PRD wants Move-to-Trash via Finder automation with direct Trash API as fallback. Verify current path; if Finder automation prompting isn't implemented, file a bean.
- [ ] **Community rules repo (PRD §14)** — PRD calls for a separate MIT `gargantua-rules` repo. `CONTRIBUTING.md` + `docs/rules/` exist in-tree; confirm whether the separate public repo exists and whether in-app links point at it. If not, file a task bean.

## Todo

- [ ] Complete each investigation above
- [ ] For each gap confirmed, create a follow-up bean and link ID here
- [ ] Post summary of findings in this bean's summary section before marking complete
