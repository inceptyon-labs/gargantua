---
# gargantua-5e10
title: 'Feature: AI Tier 3 — Claude Code agent integration'
status: todo
type: feature
priority: normal
created_at: 2026-04-23T20:54:50Z
updated_at: 2026-04-23T20:56:32Z
blocked_by:
    - gargantua-fn4q
    - gargantua-u9il
    - gargantua-hrym
---

Ship Tier 3 agent-mode integration via the `claude -p` CLI. Phase 3 gap from PRD §6.4.

## Context

PRD §6.4 describes Tier 3 as the agentic mode: investigative cleanup, project archaeology, custom script generation, scheduled AI audits, MCP-integrated agent loops. No implementation yet; depends on MCP server being mature and on Tier 2 API plumbing.

## Requirements

- User-configured path to `claude` CLI or auto-detect from PATH
- Surface agent sessions in a dedicated UI pane with transcript + approve/deny gates for every destructive step
- Agent must call the Gargantua MCP server (not bypass it) so the safety floor still applies
- Every agent action lands in the same audit log as GUI actions
- Kill-switch to cancel an in-flight agent

## Todo

- [ ] CLI discovery + configurable path in Settings
- [ ] Session runner that launches `claude -p` with MCP server wired in
- [ ] Live transcript UI with step-level approve/deny (default deny for destructive steps)
- [ ] Built-in prompts: "investigate what's taking space", "archaeology on project X", "generate a custom cleanup script"
- [ ] Scheduled AI audits hook (depends on scheduled-scans bean)
- [ ] Tests: session lifecycle, cancellation, safety-floor enforcement
