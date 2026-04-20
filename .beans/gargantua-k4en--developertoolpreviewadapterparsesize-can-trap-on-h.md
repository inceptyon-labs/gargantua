---
# gargantua-k4en
title: DeveloperToolPreviewAdapter.parseSize can trap on huge or malformed size tokens
status: completed
type: bug
priority: low
created_at: 2026-04-20T01:24:40Z
updated_at: 2026-04-20T13:40:33Z
parent: gargantua-qe4a
---

DeveloperToolPreviewAdapter.swift:367 does `Int64(value * multiplier)` where `value` is a Double parsed from brew/docker output and `multiplier` is up to 1e12. A malformed or maliciously-large size token (e.g. `1e308 TB`) overflows Double.multiplication or exceeds Int64 range and traps at the Int64 cast.

Related: DeveloperToolPreview.reclaimableBytes (line 90) sums per-item Int64s with `reduce(0, +)` — also overflow-traps if multiple huge items slip through parseSize.

Fix:
- Range-check the Double product against Int64.max before the cast (clamp or return nil).
- Swap `reduce(0, +)` for `addingReportingOverflow` and clamp to Int64.max on overflow (the reclaimable total is display-only — a saturated "a lot" beats a crash).

Tests:
- Add parser cases at the boundaries: `9999 TB`, `1e308 MB`, negative tokens, non-finite Double (NaN/Inf), and a multi-item preview whose sum exceeds Int64.max.
- Cover both brew cleanup (`parseFirstSize`) and docker system df (`parseDockerReclaimable`) paths.

Surfaced during gargantua-apnw review (Codex SC pass, 2026-04-19).


## Summary of Changes

Hardened `DeveloperToolPreviewAdapter` against overflow traps on malformed or
large size tokens.

- `parseSize` now range-checks `value * multiplier` before the `Int64` cast:
  rejects non-finite, negative, or `>= Double(Int64.max)` products by returning
  `nil` instead of trapping.
- `DeveloperToolPreview.reclaimableBytes` swaps `reduce(0, +)` for
  `addingReportingOverflow` and saturates at `Int64.max` on sum overflow.
  This is a display-only number — a capped "a lot" beats a crash.
- Made `parseSize`, `parseFirstSize`, and `parseDockerReclaimable`
  `internal static` (was `private`) so the overflow behavior is directly
  unit-testable via `@testable`.

Acceptance:
- [x] Range-check Double product against Int64.max before the cast
- [x] Swap `reduce(0, +)` for `addingReportingOverflow` and clamp to Int64.max on overflow
- [x] Boundary parser cases covered: `9999 TB` (large but fitting), `99999999999999 TB` (overflow → nil), `1e308 MB` (regex-rejected → nil), negative, `NaN`/`Inf`, empty
- [x] Both brew (`parseFirstSize`) and docker (`parseDockerReclaimable`) paths tested
- [x] Multi-item preview whose sum exceeds Int64.max saturates to Int64.max

Files:
- `Sources/GargantuaCore/Services/DeveloperToolPreviewAdapter.swift`
- `Tests/GargantuaCoreTests/Services/DeveloperToolPreviewAdapterParserTests.swift` (new)

Baseline 719 → 731 tests pass (12 new).
