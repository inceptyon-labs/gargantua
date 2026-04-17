---
# gargantua-t114
title: 'Task: NativeScanAdapter integration tests'
status: todo
type: task
priority: normal
created_at: 2026-04-17T02:00:03Z
updated_at: 2026-04-17T02:00:24Z
parent: gargantua-l9dk
---

PathExpander is well-covered in isolation, but there are no tests for NativeScanAdapter itself. Codex SC review of gargantua-guga called this out.

Should cover:
- profile scoping (devPurge produces only dev_artifacts/docker/homebrew results; light excludes dev rules)
- cross-rule path de-duplication
- cap-warning propagation through ScanProgress
- `rule.pattern` file filtering (e.g., `~/Downloads` + `*.dmg`)
- loadDefaults(profile:scanRoots:) override honored
