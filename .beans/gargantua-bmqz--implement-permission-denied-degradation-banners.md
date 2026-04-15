---
# gargantua-bmqz
title: Implement permission-denied degradation banners
status: todo
type: task
priority: normal
tags:
    - area:frontend
    - pasiv
    - size:S
created_at: 2026-04-15T00:47:32Z
updated_at: 2026-04-15T00:47:32Z
parent: gargantua-38l5
---

Per-feature banners when permissions are missing. Not a modal, not blocking. Specific to each affected screen.

## Acceptance Criteria
- [ ] Banner shows on Deep Clean when FDA denied: "Some system paths are inaccessible. Grant Full Disk Access in System Settings."
- [ ] Banner uses --review-dim background with --review text
- [ ] Includes direct link to System Settings > Privacy
- [ ] Dismissible but reappears on next app launch

---
**Size:** S
