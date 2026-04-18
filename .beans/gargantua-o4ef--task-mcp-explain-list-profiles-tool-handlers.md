---
# gargantua-o4ef
title: 'Task: MCP explain + list_profiles tool handlers'
status: todo
type: task
priority: normal
created_at: 2026-04-18T22:18:43Z
updated_at: 2026-04-18T22:18:43Z
parent: gargantua-2h06
blocked_by:
    - gargantua-xc7m
---

Implement explain handler (path or item_id mutual exclusion already enforced in input type) returning an AI-free explanation shell that can be backed by AIInferenceEngine later. Implement list_profiles handler returning available scan profiles. Reference: MCPToolSchemas.swift MCPExplainInput/Output, MCPListProfilesOutput.
