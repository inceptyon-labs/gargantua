---
# gargantua-sbg6
title: 'Task: MCP scan tool handler (dry-run enforced)'
status: todo
type: task
priority: high
created_at: 2026-04-18T22:18:37Z
updated_at: 2026-04-18T22:18:37Z
parent: gargantua-2h06
blocked_by:
    - gargantua-xc7m
---

Implement scan tool handler wired to the real scan pipeline. Must enforce dry_run=true at the type boundary (MCPScanInput rejects false). No destructive side effects possible via MCP scan. Emit results shaped per MCPScanOutput. Reference: MCPToolSchemas.swift MCPScanInput/Output.
