---
# gargantua-nrfg
title: 'Natural Language Search: NL query to scan filter DSL'
status: todo
type: task
priority: low
created_at: 2026-04-20T14:06:44Z
updated_at: 2026-04-20T14:06:44Z
parent: gargantua-8igf
---

PRD §6.2 Tier 1 use case: "Show me everything related to Xcode" → maps to
scan filters. Lowest priority in the Feature — it's a nice-to-have, and
the UX hasn't been sketched.

## Scope

- Define a small "scan filter" DSL (bundle-id, path glob, category,
  size range, safety) that the UI already supports implicitly.
- Translate an NL query through the `AIInferenceEngine` into that DSL.
- Surface as a small search field that adjusts the currently-displayed
  scan buckets.
- Strict allow-list on DSL output: any AI-suggested filter outside the
  DSL is dropped. AI never writes to `ScanResult.safety` via this path
  (same §2.5 invariant as Advisory).

## Out of scope

- Full natural-language interaction / chat. This Task is single-turn:
  query → filter set → UI applies.
- LoRA fine-tuning.

## Acceptance

- [ ] NL input produces a valid filter set or a graceful "didn't
      understand" fallback
- [ ] Test: filter set emitted by the engine is always a subset of the
      defined DSL (no injected fields)
- [ ] Test: applying the filter set doesn't mutate `ScanResult.safety`
