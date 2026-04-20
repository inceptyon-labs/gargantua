---
# gargantua-7k2r
title: Latency and memory smoke tests for MLX backend
status: todo
type: task
priority: low
created_at: 2026-04-20T14:05:52Z
updated_at: 2026-04-20T14:06:01Z
parent: gargantua-ddaa
blocked_by:
    - gargantua-mgqr
---

Once `MLXInferenceEngine` runs real inference, measure and document the
latency + memory envelope so we can size the idle-unload timer, the 3 GB
RAM guard, and the UX around the "?" explain button.

## Scope

- Pick 5–10 representative `ScanResult` inputs drawn from the existing
  YAML ruleset (cache, app, log, remnant, etc.).
- Run the real engine against the pinned model and record:
  - Cold-load time (first `load`)
  - Warm `generate` latency (p50 / p95 over N runs)
  - Resident memory after load
  - Token count per output
- Write the numbers into `docs/designs/…-mlx-backend.md` alongside the
  backend-choice rationale from the first Task.
- If numbers are out of budget (e.g. generate p95 > several seconds, or
  memory over 3 GB), surface it as a follow-up bean rather than widening
  the guard silently.

## Out of scope

- UI surfacing of perf metrics.
- LoRA fine-tuning or model-swap tooling.

## Acceptance

- [ ] Measurements recorded in the backend design doc
- [ ] Verdict documented: are the pinned model + backend combination
      usable under the existing idle-timeout + RAM guard, or do they
      need adjustment?
