---
# gargantua-7sge
title: Classification Advisory surface (flag items; never rewrite safety)
status: todo
type: task
priority: normal
created_at: 2026-04-20T14:06:22Z
updated_at: 2026-04-20T14:06:22Z
parent: gargantua-8igf
---

Add an advisory pass that reviews `review` (🟡) scan results and *suggests*
the user might want to reclassify, without ever changing the YAML-assigned
safety level. PRD §2.5 and §6.2 are explicit that AI is advisory-only.

## Scope

- New surface on `LocalAIService` (or a small sibling service that owns
  this) along the lines of:

  ```swift
  func advisory(for results: [ScanResult], rules: [String: ScanRule])
      async throws -> [ScanResultAdvisory]
  ```

  where `ScanResultAdvisory` carries the result id, a short text
  rationale, and the AI's *suggested* alternative safety level — never
  applied automatically.
- Drive the advisory through the same `AIInferenceEngine` boundary so it
  benefits automatically when MLX lands. Template engine produces a
  structured "review this" suggestion from rule metadata; real engine
  produces something grounded in file path / source.
- Caller surface: a new UI row or toolbar action on review-tier items
  that shows the advisory when the user asks. Do not auto-display.

## Safety invariant

- Advisory must never mutate `ScanResult.safety` or any persisted model
  record. A unit test pins this invariant.

## Out of scope

- UI polish / visual design — functional stub is fine; design review
  happens separately.
- Writing advisories for `safe` or `protected` items; scope is `review`
  only for v1.

## Acceptance

- [ ] `advisory(for:rules:)` returns well-formed `ScanResultAdvisory`
      values for review-tier inputs
- [ ] Test: advisory invocation does not mutate input `ScanResult.safety`
- [ ] Falls back to YAML rule text on engine failure (same pattern as
      `explain`)
