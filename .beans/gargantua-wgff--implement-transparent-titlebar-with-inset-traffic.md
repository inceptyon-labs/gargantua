---
# gargantua-wgff
title: Implement transparent titlebar with inset traffic lights
status: in-progress
type: task
priority: high
tags:
    - area:frontend
    - pasiv
    - size:M
created_at: 2026-04-15T00:47:06Z
updated_at: 2026-04-15T19:23:26Z
parent: gargantua-vxjo
---

Configure NSWindow for transparent titlebar with standard traffic lights. Set --void background. Hide default title. Position traffic lights correctly for custom title bar region.

## Acceptance Criteria
- [ ] Window uses .titlebarAppearsTransparent and .fullSizeContentView
- [ ] Traffic lights visible and functional in correct position
- [ ] --void (hsl(220, 14%, 9%)) background fills entire window
- [ ] No visible system chrome besides traffic lights

---
**Size:** M
