---
# gargantua-8cs1
title: 'Task: Placeholder expander + remnant filesystem scanner'
status: todo
type: task
priority: high
created_at: 2026-04-17T21:49:55Z
updated_at: 2026-04-17T21:49:55Z
parent: gargantua-j8a1
blocked_by:
    - gargantua-anqg
    - gargantua-4xkj
---

Expand {bundleID}/{appName}/{teamID} placeholders in RemnantRule.pathTemplates against a concrete AppInfo, then scan the filesystem and emit RemnantItem instances grouped into an UninstallPlan.

Scope:
- Template expander with escaping rules for spaces, special chars in appName
- Tilde expansion + glob (**) matching consistent with ScanRule behaviour
- Apply RemnantRule.appliesTo scoping per app
- Apply per-rule exclude patterns
- Populate RemnantItem: size, lastAccessed, ruleID, source (resolve {appName} in source.name)
- Return UninstallPlan with optional appBundle + remnants + totalBytes
- Tests: template expansion matrix, scoping, glob semantics, missing-path graceful handling

Blocked by gargantua-anqg (loader) and gargantua-4xkj (app scanner).
