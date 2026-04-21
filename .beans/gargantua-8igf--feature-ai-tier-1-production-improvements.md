---
# gargantua-8igf
title: 'Feature: AI Tier 1 production improvements'
status: completed
type: feature
priority: normal
created_at: 2026-04-17T18:07:38Z
updated_at: 2026-04-21T11:09:59Z
parent: gargantua-qe4a
---

Move Tier 1 local AI from lifecycle/download scaffolding plus rule fallback toward production inference and Phase 2 advisory use cases. AI remains advisory only and never changes YAML safety classifications.


## Breakdown (2026-04-20)

This Feature was filed as an umbrella. Concrete work is now split out:

- **`gargantua-ddaa`** — Feature: MLX inference backend (sibling, blocks this)
  - `gargantua-xuz6` — Evaluate and add MLX backend dependency
  - `gargantua-mgqr` — Implement MLXInferenceEngine.load and generate (blocked-by xuz6)
  - `gargantua-7k2r` — Latency and memory smoke tests (blocked-by mgqr)

- **Child Tasks on this Feature:**
  - `gargantua-6xce` — Engine selection: Template vs MLX with Settings toggle (blocked-by mgqr)
  - `gargantua-7sge` — Classification Advisory surface (PRD §2.5 invariant)
  - `gargantua-2xt6` — Cleanup Summary narrative via AI (YAML fallback)
  - `gargantua-nrfg` — Natural Language Search → scan filter DSL (low priority)

- **Deferred:** LoRA fine-tuning pipeline — PRD §6.2 calls this "Phase 2+",
  file as a standalone Feature when we're ready.

This Feature closes when all four child Tasks close. The advisory use cases
can be built against the Template engine first; they pick up real intelligence
when `gargantua-ddaa` lands.

## Completed

All child tasks are completed:
- `gargantua-6xce` — Engine selection: Template vs MLX with Settings toggle
- `gargantua-7sge` — Classification Advisory surface
- `gargantua-2xt6` — Cleanup Summary narrative via AI
- `gargantua-nrfg` — Natural Language Search to scan filter DSL

Tier 1 AI now has engine selection, advisory surfaces, cleanup summary narration,
and natural-language scan filtering while preserving the invariant that AI never
mutates YAML-derived safety classifications.
