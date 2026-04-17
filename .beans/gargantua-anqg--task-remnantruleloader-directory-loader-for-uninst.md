---
# gargantua-anqg
title: 'Task: RemnantRuleLoader (directory loader for uninstall rules)'
status: in-progress
type: task
priority: high
created_at: 2026-04-17T21:49:47Z
updated_at: 2026-04-17T23:19:26Z
parent: gargantua-j8a1
---

Implement a RemnantRuleLoader analogous to RuleLoader: walks a directory tree, parses every *.yaml/*.yml file via RemnantRuleParser, collects non-fatal errors, returns a RemnantRuleLoadResult with rules/errors/filesLoaded/isClean.

Scope:
- Mirror the RuleLoader API shape
- Load the bundled Resources/uninstall_rules directory at startup
- Allow a user-override directory (future: ~/Library/Application Support/Gargantua/uninstall_rules)
- Tests: happy path, partial-load with errors, non-YAML ignored, nonexistent dir

Blocked by gargantua-9wxo (merged).
