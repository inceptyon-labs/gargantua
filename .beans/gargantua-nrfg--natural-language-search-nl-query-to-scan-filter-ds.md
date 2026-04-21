---
# gargantua-nrfg
title: 'Natural Language Search: NL query to scan filter DSL'
status: completed
type: task
priority: low
created_at: 2026-04-20T14:06:44Z
updated_at: 2026-04-21T11:09:45Z
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

- [x] NL input produces a valid filter set or a graceful "didn't
      understand" fallback
- [x] Test: filter set emitted by the engine is always a subset of the
      defined DSL (no injected fields)
- [x] Test: applying the filter set doesn't mutate `ScanResult.safety`

## Completed

**Files changed:**
- Sources/GargantuaCore/Models/ScanFilter.swift
- Sources/GargantuaCore/Services/ScanFilterTemplate.swift
- Sources/GargantuaCore/Services/AIInferenceEngine.swift
- Sources/GargantuaCore/Services/LocalAIService.swift
- Sources/GargantuaCore/Services/MLXInferenceEngine.swift
- Sources/GargantuaCore/Views/ScanBucketView.swift
- Sources/GargantuaCore/Views/DeepCleanView.swift
- Sources/GargantuaCore/Views/DevArtifactScanView.swift
- Sources/Gargantua/MainContentView.swift
- Tests/GargantuaCoreTests/Models/ScanFilterTests.swift
- Tests/GargantuaCoreTests/Services/LocalAIServiceTests.swift

**Key decisions:**
- Added `ScanFilterSet` as the strict allow-listed DSL for bundle IDs, path globs, categories, size bounds, and safety levels.
- Routed natural-language resolution through `AIInferenceEngine.scanFilter(for:)`, with Template fallback mappings for common tool queries and MLX parsing constrained to JSON-only DSL output.
- Applied filters inside `ScanBucketListView` and trimmed hidden selections when a filter activates so cleanup cannot operate on invisible rows.

**Notes for next task:**
- The v1 template fallback intentionally covers common product terms (Xcode, Docker, Homebrew, Chrome, Safari) plus explicit safety words; broader semantics are left to the MLX engine.
- `ScanFilterSet.decodeAllowListed(from:)` ignores unknown JSON fields and returns nil for empty/invalid model output, which drives the UI's "Didn't understand" fallback.
