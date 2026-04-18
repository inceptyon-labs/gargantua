---
# gargantua-2xod
title: 'Task: MCP analyze + status tool handlers'
status: todo
type: task
priority: high
created_at: 2026-04-18T22:18:41Z
updated_at: 2026-04-18T22:18:41Z
parent: gargantua-2h06
blocked_by:
    - gargantua-xc7m
---

Implement analyze handler populating MCPAnalyzeOutput from SystemMetricCollector + disk usage summary. Implement status handler from SystemMetrics (percent fields x100, bytes formatted). Reference: MCPToolSchemas.swift MCPAnalyzeOutput/MCPStatusOutput, SystemMetricCollector.swift.
