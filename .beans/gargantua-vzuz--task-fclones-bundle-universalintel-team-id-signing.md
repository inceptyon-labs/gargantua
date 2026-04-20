---
# gargantua-vzuz
title: 'Task: fclones bundle — universal/Intel, team-ID signing, fresh-install smoke'
status: draft
type: task
priority: normal
created_at: 2026-04-19T03:31:22Z
updated_at: 2026-04-20T01:47:21Z
parent: gargantua-4nb9
blocking:
    - gargantua-4nb9
blocked_by:
    - gargantua-vchj
    - gargantua-9495
---

Follow-up to `gargantua-vchj` (which vendored aarch64-only fclones 0.35.0 into `Sources/GargantuaCore/Resources/bin/`). Scope here covers everything deferred from that bean so the Duplicate Finder is shippable to the full macOS user base, not just Apple Silicon.

## Context

`gargantua-vchj` got an aarch64-apple-darwin fclones into `Bundle.module/bin/fclones` and fixed the resolver to use `Bundle.module`. But PRD §8.3 (bundle-size budget) and §9 (permissions/security) still want:

- Intel coverage (either a universal binary or a second arch-specific binary with runtime selection)
- Team-ID code-signing of the bundled binary so Gatekeeper / TCC inheritance behaves
- Integrity pinning (SHA-256) on the upstream source so the vendored blob is reproducible
- A real smoke test on a fresh macOS install (no brew, no env override)

`czkawka_cli` (PRD §8.3, ~10 MB) needs the same treatment — factor a shared "vendored CLI" script/pattern if the signing approach lands here.

## Acceptance Criteria

- [ ] `Scripts/fetch-fclones.sh` produces a universal binary (`lipo`-merged aarch64 + x86_64) OR two arch-specific binaries with resolver runtime selection
- [ ] Script pins a SHA-256 of the fclones source crate / prebuilt input and verifies before use
- [ ] Binary is re-signed with the app's team ID as part of the release pipeline (`codesign --force --sign <team-id>`)
- [ ] Notarization + stapling story documented for the bundled binary (Gatekeeper unquarantine on first launch)
- [ ] Smoke test on a fresh macOS install (VM or clean user account) verifying Duplicate Finder runs with no brew/no env override
- [ ] If universal: bundle still fits within PRD §8.3 budget (~10 MB allowance for fclones alone)
- [ ] Same script/pattern reusable for `czkawka_cli` follow-up

## Blockers / prerequisites

- No Xcode project or CI release pipeline exists in this repo yet. Signing + notarization presume that infrastructure lands first (either via a separate "app packaging" bean or alongside this one).
- Intel cross-compilation needs either `rustup target add x86_64-apple-darwin` with a rustup-managed toolchain (current host has Homebrew-managed rustc which doesn't take target add), or building on a CI runner that has both targets.

## Implementation Notes

- Team-ID signing approach: sign the embedded binary at release-pipeline time (`codesign --force --options runtime --sign "$TEAM_ID" Gargantua_GargantuaCore.bundle/Contents/Resources/bin/fclones`) before notarizing the parent app
- Consider whether to flip the vendored binary from a checked-in blob to a release-pipeline artifact (smaller repo, higher CI coupling) — worth deciding once CI exists
- MIT license of fclones permits redistribution; keep attribution in `Credits` / About screen when that UI lands
