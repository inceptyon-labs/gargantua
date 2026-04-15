---
# gargantua-sx6c
title: Build dev artifact category scan view
status: todo
type: task
priority: normal
tags:
    - area:frontend
    - pasiv
    - size:M
created_at: 2026-04-15T00:49:09Z
updated_at: 2026-04-15T00:49:09Z
parent: gargantua-4nxf
---

Category-based view showing node_modules, Xcode derived data, Docker cache, Homebrew, build artifacts. Reuses three-bucket scan results pattern.

## Acceptance Criteria
- [ ] Category list: node_modules, Xcode, Docker, Homebrew, Python, Rust, Go
- [ ] Each category shows estimated size from last scan
- [ ] Scan button triggers mo purge for selected categories
- [ ] Results displayed using same three-bucket component as Deep Clean
- [ ] Profile-aware overrides visible (e.g., "Auto-classified as safe: >30 days old")

---
**Size:** M
