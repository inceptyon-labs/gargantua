---
# gargantua-qyqd
title: 'Task: Intel/universal coverage for vendored helper binaries'
status: draft
type: task
priority: deferred
created_at: 2026-04-20T12:29:01Z
updated_at: 2026-04-20T12:29:01Z
blocked_by:
    - gargantua-vzuz
---

Add Intel coverage to the checked-in `fclones` and `czkawka_cli` helpers so the Duplicate Finder and File Health features work on Intel Macs running macOS 14+.

## Context

`gargantua-vzuz` landed the vendoring pattern (lockfile, generic fetcher, smoke script) for aarch64 only. Intel was deferred because:

- No CI runner exists, and the current dev host is Homebrew-managed rustc (won't `rustup target add x86_64-apple-darwin`).
- macOS 26 Tahoe (current) dropped Intel entirely; macOS 15 Sequoia supports a narrowing list. Intel relevance is shrinking.
- No real users yet → zero Intel bug reports to triage.

When those conditions change (someone files an Intel bug, or CI with an x86_64 runner lands), reopen this.

## Scope

- Switch the host to rustup-managed rustc OR stand up a CI runner with both targets.
- Extend `Scripts/fetch-vendored-bins.sh` to produce either a `lipo`-merged universal binary OR two arch-specific binaries (e.g. `bin/fclones-arm64`, `bin/fclones-x86_64`) with runtime selection in the resolver.
- Update `FclonesBinaryResolver` and `CzkawkaBinaryResolver` if runtime selection is chosen.
- Re-verify SHA-256 semantics — universal binaries have their own content-hash story; the lockfile may need a per-arch pin or a post-`lipo` checksum.
- Update `Scripts/smoke/verify-vendored-bins.sh` to assert architecture match.
- PRD §8.3 budget recheck: universal roughly doubles the bundle (~10 MB fclones, ~30 MB czkawka); decide if the budget tolerates it or the two-arch-binaries approach wins.

## Open Questions (resolve in a brainstorm before kicking)

- Universal binary via `lipo` vs. two arch-specific blobs with runtime selection? Universal is smaller operationally; two-blob is smaller per-arch for distribution.
- Does `cargo install --locked --target x86_64-apple-darwin` produce a reproducible blob usable on Apple Silicon hosts via Rosetta-at-build-time? Or does it require a real x86_64 host?
- If CI lands first, does this move to CI-only and stop being checked-in?

## Blocks / blocked by

- Blocked by `gargantua-vzuz` (need the vendoring pattern in place before extending).
- May want a CI-pipeline bean as a parallel prerequisite when that exists.
