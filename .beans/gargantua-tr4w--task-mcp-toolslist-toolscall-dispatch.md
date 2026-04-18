---
# gargantua-tr4w
title: 'Task: MCP tools/list + tools/call dispatch'
status: in-progress
type: task
priority: high
created_at: 2026-04-18T22:18:34Z
updated_at: 2026-04-18T22:48:10Z
parent: gargantua-2h06
blocked_by:
    - gargantua-xc7m
---

Implement MCP protocol dispatch: initialize handshake, tools/list returning MCPPhase2Tools.all, tools/call routing by MCPToolName. Unknown tools return proper JSON-RPC error. Reference: MCPToolDescriptor.swift MCPPhase2Tools, MCPToolSchemas.swift.
