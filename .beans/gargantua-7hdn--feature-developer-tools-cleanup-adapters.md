---
# gargantua-7hdn
title: 'Feature: Developer Tools cleanup adapters'
status: completed
type: feature
priority: normal
created_at: 2026-04-17T18:07:38Z
updated_at: 2026-04-20T01:23:26Z
parent: gargantua-qe4a
---

Add runtime-detected Homebrew and Docker cleanup/introspection flows. Hide tools when not installed. Keep destructive operations behind preview and confirmation.



## Summary of Changes

All child Tasks completed:
- gargantua-rwpi — Homebrew/Docker detection + DeveloperToolPreviewAdapter with dry-run previews
- gargantua-apnw — Developer Tools UI panel with availability gating and preview panes

Feature delivers read-only introspection only. Destructive prune/cleanup
execution is deferred to Phase 3 behind the Trust Layer / ConfirmationModalView.
