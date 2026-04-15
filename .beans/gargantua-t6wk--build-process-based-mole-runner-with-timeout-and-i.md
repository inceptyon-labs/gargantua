---
# gargantua-t6wk
title: Build Process-based Mole runner with timeout and isolation
status: todo
type: task
priority: high
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:48:07Z
updated_at: 2026-04-15T00:48:07Z
parent: gargantua-rsnu
---

Swift Process wrapper that executes bundled mo binary with configurable timeout. Crash/hang caught and logged.

## Acceptance Criteria
- [ ] Process launched with inherited TCC from parent app
- [ ] Configurable timeout per command (default 60s)
- [ ] Crash/hang → error logged, feature disabled with visible warning
- [ ] Bundled binary path resolved from app bundle Resources
- [ ] Works with same team ID code signing

---
**Size:** M
