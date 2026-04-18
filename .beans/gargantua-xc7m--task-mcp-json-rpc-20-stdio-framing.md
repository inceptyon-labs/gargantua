---
# gargantua-xc7m
title: 'Task: MCP JSON-RPC 2.0 stdio framing'
status: todo
type: task
priority: high
created_at: 2026-04-18T22:18:28Z
updated_at: 2026-04-18T22:18:28Z
parent: gargantua-2h06
blocked_by:
    - gargantua-6an3
---

Replace Sources/GargantuaMCP/main.swift stub with JSON-RPC 2.0 message framing over stdio (Content-Length-style or newline-delimited per MCP spec). stdout reserved for protocol messages; logging goes to stderr. No dispatch yet. Reference: main.swift stub, MCPToolDescriptor.swift.
