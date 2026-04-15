
## PASIV

### Session Start

Read the latest handoff in docs/handoffs/ if one exists. Load only the files that handoff references. If no handoff exists, check open issues/tasks for context. Before starting work, state what you understand and what you plan to do.

### Rules

1. Check if a PASIV skill applies before working manually. Do not use `EnterPlanMode` during PASIV skills — each has its own planning.
2. Write state to disk, not conversation. Before session end or compaction, run `/handoff`.
3. When switching work types (planning → implementing → reviewing), write a handoff and suggest a new session.
4. Do not silently resolve open questions. Mark them OPEN or ASSUMED.
5. No production code without a failing test first. After 3 failed fix attempts, stop and reassess.
6. Verification gate before every merge. Tests, build, lint, type-check must pass with fresh evidence.

### Where Things Live

- `.pasiv.yml` — task backend config (github, beans, or local)
- `docs/handoffs/` — session handoffs (loaded at session start, archived after use)
- `docs/designs/` — design docs from `/brainstorm`
- `docs/plans/` — implementation plans
- `docs/scans/` — security scan reports from `/repo-scan`
