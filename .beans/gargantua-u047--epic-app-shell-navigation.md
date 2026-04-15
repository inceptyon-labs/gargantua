---
# gargantua-u047
title: 'Epic: App Shell & Navigation'
status: todo
type: epic
priority: high
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-15T00:44:03Z
updated_at: 2026-04-15T00:44:03Z
---

The foundational app frame — custom dark window chrome, sidebar navigation, and first-launch onboarding. This epic establishes Gargantua's visual identity and the navigation structure for all Phase 1 screens.

## Vision
A custom dark UI that feels Mac-native in behavior but owns its visual identity. Raycast-energy: compact, fast, utilitarian. Space-theme isn't decoration — it's structure.

## Features
- Custom window chrome with transparent titlebar and traffic lights
- Grouped sidebar navigation (CLEAN / ANALYZE / TOOLS / CONFIGURE)
- First-launch permission onboarding flow
- Permission-denied degradation banners

## Success Criteria
- [ ] Custom dark window with traffic lights renders correctly on macOS 14+
- [ ] Sidebar navigates between all Phase 1 screens with keyboard shortcuts
- [ ] First-launch flow requests FDA and Automation permissions with clear explanations
- [ ] App degrades gracefully when permissions are denied
