---
# gargantua-fn4q
title: 'Epic: AI Tier 2 — Claude API cloud analysis'
status: todo
type: epic
priority: high
created_at: 2026-04-23T20:54:42Z
updated_at: 2026-04-23T20:54:42Z
---

Bring up cloud-based AI analysis backed by the Anthropic Claude API. Phase 3 gap from PRD §6.3; also the core monetization hook.

## Context

PRD §6.3 defines Tier 2 as opt-in cloud analysis using claude-sonnet-4-20250514 for features that exceed the local MLX 1B model: deep multi-file reasoning, anomaly detection, target-based cleanup ("free up 20 GB"), duplicate conflict resolution, scan-rule suggestions. Nothing exists yet in-repo.

## Constraints (from PRD)

- API key entry is user-supplied and stored in Keychain — never hardcoded or bundled
- Hard cap on monthly spend with clear UI
- AI remains advisory only (PRD §2.5): can never override YAML safety classification
- Opt-in only; defaults off; visible indicator when cloud is reasoning on user data
- Redact file contents before sending; send paths + metadata unless the user explicitly consents

## Scope (break into child beans)

- [ ] Keychain-backed API key flow (entry, validation, revocation)
- [ ] Cost estimator + monthly cap UI with rolling usage visible on Dashboard
- [ ] Transport layer (streaming support, retries, cancellation, request logging)
- [ ] Prompt/redaction pipeline enforcing path-only vs. content-consent boundaries
- [ ] Deep analysis feature: multi-file reasoning on a scan result
- [ ] Target-based cleanup: "free up N GB" → proposed item set, confirmation required
- [ ] Duplicate conflict resolution suggestions
- [ ] Scan-rule suggestion flow that writes to a proposed-rules file (never live rules)
- [ ] Dashboard integration: Tier 2 status, last run, cost-to-date
