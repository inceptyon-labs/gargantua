---
# gargantua-6an3
title: 'Task: Define stdio MCP server target and tool schemas'
status: in-progress
type: task
priority: high
created_at: 2026-04-17T18:07:39Z
updated_at: 2026-04-17T21:57:21Z
parent: gargantua-2h06
---

Add the executable target shape and concrete JSON schemas for PRD Phase 2 MCP tools: scan, analyze, explain, list_profiles, and status. Keep scan dry-run only.


## Plan

Scope: define executable target + Codable tool schemas (Phase 2, stdio). No dispatch logic yet.

### Todos
- [x] Add GargantuaMCP executable target to Package.swift
- [x] Create Sources/GargantuaMCP/main.swift stub (not-implemented notice)
- [x] Create Sources/GargantuaCore/Models/MCP/MCPToolDescriptor.swift (tool registry + JSON Schema descriptor)
- [x] Create Sources/GargantuaCore/Models/MCP/MCPToolSchemas.swift (Codable input/output for scan, analyze, explain, list_profiles, status; scan.dry_run always true)
- [x] Tests: encoding round-trip + enforce scan dry-run invariant
- [ ] Verification gate (tests, build, lint)
