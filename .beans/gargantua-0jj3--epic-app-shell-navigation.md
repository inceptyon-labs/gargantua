---
# gargantua-0jj3
title: 'Epic: App Shell & Navigation'
status: todo
type: epic
priority: high
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-15T00:44:08Z
updated_at: 2026-04-15T00:44:08Z
---

The foundational app frame — custom dark window chrome, sidebar navigation, and first-launch onboarding.

## Vision
Custom dark UI that feels Mac-native in behavior but owns its visual identity. Raycast-energy: compact, fast, utilitarian.

## Features
- Custom window chrome with transparent titlebar and traffic lights
- Grouped sidebar navigation (CLEAN / ANALYZE / TOOLS / CONFIGURE)
- First-launch permission onboarding flow
- Permission-denied degradation banners

## Success Criteria
- [ ] Custom dark window renders correctly on macOS 14+
- [ ] Sidebar navigates between all Phase 1 screens with keyboard shortcuts
- [ ] First-launch flow requests FDA and Automation permissions
- [ ] App degrades gracefully when permissions are denied
