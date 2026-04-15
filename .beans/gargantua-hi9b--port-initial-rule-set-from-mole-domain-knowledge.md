---
# gargantua-hi9b
title: Port initial rule set from Mole domain knowledge
status: todo
type: task
priority: high
tags:
    - area:backend
    - pasiv
    - size:L
created_at: 2026-04-15T00:47:32Z
updated_at: 2026-04-15T00:47:32Z
parent: gargantua-5la2
---

Create YAML rules for highest-impact categories: browser caches (Chrome, Safari, Firefox, Arc), developer tools (Xcode, node_modules, Docker, Homebrew), system caches and logs.

## Acceptance Criteria
- [ ] Browser rules: Chrome, Safari, Firefox, Arc (cache + local storage + extensions)
- [ ] Developer rules: Xcode derived data, node_modules, Docker cache, Homebrew
- [ ] System rules: system caches, logs, temp files, Trash
- [ ] Each rule has safety level, confidence, explanation, source
- [ ] File organization matches cleanup_rules/ structure from PRD

---
**Size:** L
