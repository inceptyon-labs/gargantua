---
# gargantua-u9il
title: 'Feature: MCP clean tool handler'
status: todo
type: feature
priority: high
created_at: 2026-04-23T20:54:06Z
updated_at: 2026-04-23T20:54:06Z
---

Add the missing `clean` tool to the MCP server so agents can execute cleanup, not just scan/analyze. Closes a Phase 2 gap from PRD §7.3.

## Context

PRD §7.3 lists `clean` as a Phase 2 MCP tool. Current server (Sources/GargantuaMCP) ships scan, analyze, status, explain, list_profiles — no clean handler. Without it, agents can't finish the cleanup loop.

## Requirements (from PRD §7.3)

- Tool name: `clean`
- Input: list of item IDs from a prior `scan` response + `profile` (developer|light|deep|custom)
- Default: move to Trash (not permanent delete)
- Enforce safety floor: refuse any item whose YAML classification is `protected`
- Return: per-item outcome (moved | skipped | failed) with reason, total bytes reclaimed
- Emit an audit log entry (~/Library/Logs/Gargantua/audit.json) identical to GUI path

## Todo

- [ ] Define JSON schema for clean tool input/output (match existing handler style)
- [ ] Implement CleanToolHandler wired through existing cleanup service used by GUI
- [ ] Reject `protected` items server-side, regardless of AI reasoning
- [ ] Audit log entry includes transport=mcp + client identifier
- [ ] Dry-run mode (`dryRun: true`) returning what would be cleaned without touching filesystem
- [ ] Unit tests: happy path, protected-item rejection, dry-run, unknown IDs
- [ ] Integration test via stdio transport
- [ ] Update MCP tool list docs / README
