---
# gargantua-5fds
title: 'Feature: Dedicated Settings Whitelists pane'
status: todo
type: feature
priority: normal
tags:
    - area:frontend
    - size:S
created_at: 2026-04-23T23:00:29Z
updated_at: 2026-04-23T23:00:29Z
---

PRD §5.2 asks for a dedicated Settings → Whitelists UI. Gargantua currently has whitelist CRUD, but it lives inside the standalone Rules view/detail pane rather than a dedicated Settings section.

## Evidence

- `Sources/Gargantua/MainContentView.swift:101` routes `"rules"` to `RuleViewerView`.
- `Sources/GargantuaCore/Views/RuleViewerView.swift:3` describes the Rule Viewer as including whitelist management.
- `Sources/GargantuaCore/Views/RuleViewerView.swift:265` wires `whitelistSection` inside the rule detail pane.
- `Sources/GargantuaCore/Views/RuleViewerView.swift:404` defines `WhitelistManagementView` with add/remove UI.
- `Sources/GargantuaCore/Views/SettingsView.swift:36` renders AI Model, scan roots, and General sections only; no Whitelists section exists.

## Scope

- Add a first-class Whitelists section/pane under Settings.
- Reuse the existing `PersistenceController` whitelist CRUD and `PersistedWhitelistEntry` model.
- Consider extracting `WhitelistManagementView` from `RuleViewerView` so Rules and Settings can share the same component.
- Keep existing Rules-view whitelist affordance if useful, but Settings must expose the user-managed whitelist directly.

## Acceptance Criteria

- [ ] Settings exposes add/remove/list controls for whitelist entries.
- [ ] Controls use the existing SwiftData persistence path.
- [ ] Empty state and duplicate-entry behavior are clear.
- [ ] Existing Rule Viewer whitelist behavior remains covered or is intentionally redirected to Settings.
