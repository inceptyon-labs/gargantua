---
# gargantua-w7pe
title: 'Epic: Settings & AI Tier 1'
status: todo
type: epic
priority: normal
tags:
    - area:frontend
    - area:backend
    - pasiv
created_at: 2026-04-15T00:44:50Z
updated_at: 2026-04-15T00:44:50Z
---

Settings screens and on-device AI integration. Cleanup profiles, scan rule viewer, tool configuration, and MLX-based AI explanations.

## Vision
Settings are a developer tool, not a consumer preferences screen. Profile editing is powerful. Rule viewing is transparent. AI is optional, lazy-loaded, and advisory-only.

## Features
- Cleanup profile manager (Developer, Light, Deep, Custom)
- YAML scan rule viewer and whitelist editor
- Tool versions and engine status display
- AI tier selector with model download management
- MLX integration: lazy load, eager unload, explain button

## Success Criteria
- [ ] All four default profiles selectable and editable
- [ ] YAML rules viewable with syntax highlighting
- [ ] Whitelist add/remove works and persists
- [ ] AI model downloads to correct location and lazy-loads
- [ ] Explain button generates useful output or falls back to YAML string
