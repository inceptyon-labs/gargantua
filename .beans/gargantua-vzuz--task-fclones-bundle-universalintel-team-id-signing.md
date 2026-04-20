---
# gargantua-vzuz
title: 'Task: fclones bundle — universal/Intel, team-ID signing, fresh-install smoke'
status: completed
type: task
priority: normal
created_at: 2026-04-19T03:31:22Z
updated_at: 2026-04-20T12:41:43Z
parent: gargantua-4nb9
blocking:
    - gargantua-4nb9
blocked_by:
    - gargantua-vchj
---

Follow-up to `gargantua-vchj` (which vendored aarch64-only fclones 0.35.0 into `Sources/GargantuaCore/Resources/bin/`). Scope here covers everything deferred from that bean so the Duplicate Finder is shippable to the full macOS user base, not just Apple Silicon.

## Context

`gargantua-vchj` got an aarch64-apple-darwin fclones into `Bundle.module/bin/fclones` and fixed the resolver to use `Bundle.module`. But PRD §8.3 (bundle-size budget) and §9 (permissions/security) still want:

- Intel coverage (either a universal binary or a second arch-specific binary with runtime selection)
- Team-ID code-signing of the bundled binary so Gatekeeper / TCC inheritance behaves
- Integrity pinning (SHA-256) on the upstream source so the vendored blob is reproducible
- A real smoke test on a fresh macOS install (no brew, no env override)

`czkawka_cli` (PRD §8.3, ~10 MB) needs the same treatment — factor a shared "vendored CLI" script/pattern if the signing approach lands here.

## Design

Validated design: `docs/designs/2026-04-20-vendored-helper-binaries.md`

Scope was recalibrated in the 2026-04-20 brainstorm after `gargantua-9495` landed the release pipeline. Team-ID signing and notarization of embedded helpers are now handled infrastructurally by `Scripts/release/sign.sh` (inside-out codesign) and `Scripts/release/notarize.sh` (two-stage: .app then DMG) — no per-binary work required. Intel / universal coverage is deferred to its own follow-up bean.

Decisions resolved in brainstorm:
- **Intel coverage:** deferred to follow-up bean (no CI yet, no real users yet).
- **SHA-256 pin:** stored in a single lockfile (`Scripts/vendored-bins.lock`) covering all vendored binaries.
- **Fetch script:** generalized from `fetch-fclones.sh` to `fetch-vendored-bins.sh`; iterates fclones + czkawka_cli from the lockfile.
- **Smoke:** lightweight bash script (`Scripts/smoke/verify-vendored-bins.sh`) + README checklist. No VM automation.
- **czkawka_cli:** same bean — vendor binary, fix resolver (`Bundle.main` → `Bundle.module` + `bin/`), add mirror tests.
- **Binary storage:** stays checked-in (lockfile is audit receipt, not a download trigger).

## Acceptance Criteria

- [x] `Scripts/vendored-bins.lock` committed with version + SHA-256 stanzas for `fclones` and `czkawka_cli`.
- [x] `Scripts/fetch-vendored-bins.sh` committed (replaces `fetch-fclones.sh`): downloads `.crate` from crates.io, verifies SHA-256 against lockfile, `cargo install --locked`, strips, writes to `Sources/GargantuaCore/Resources/bin/<name>`.
- [x] `Sources/GargantuaCore/Resources/bin/czkawka_cli` committed as a freshly-fetched, stripped aarch64 binary.
- [x] `CzkawkaBinaryResolver.swift` updated: `Bundle.main` → `Bundle.module.url(forResource: "bin/czkawka_cli", withExtension: nil) ?? Bundle.module.resourceURL?.appendingPathComponent("bin/czkawka_cli")`.
- [x] `CzkawkaBinaryResolverTests` adds `vendoredBinaryResolvable` + `vendoredBinaryResolvesWhenPathEmpty`, mirroring the fclones fixes from `gargantua-vchj`.
- [x] `Gargantua --selfcheck-binaries` CLI flag wired: prints resolved paths for both helpers and exits 0.
- [x] `Scripts/smoke/verify-vendored-bins.sh` committed: asserts both helpers live in the installed `.app`, are team-ID-signed, and win over brew under a neutralized PATH.
- [x] `Scripts/release/README.md` "Fresh-install smoke" section updated to reference the new smoke script.
- [x] Follow-up bean filed for Intel / universal coverage of both helpers (`gargantua-qyqd`).

## Implementation Notes

- MIT license of fclones and czkawka permits redistribution; keep attribution in Credits / About screen when that UI lands.
- `cargo install --locked` already verifies crate SHAs against the crates.io index; the lockfile adds a repo-owned receipt that catches local-cache tampering and serves as reproducibility evidence.
- If czkawka's `cargo install czkawka_cli --locked` misbehaves on certain versions (pkg-config / gtk deps historically), pin to the last-known-good version rather than fighting the build.


## Completed

**Files changed:**
- Scripts/vendored-bins.lock
- Scripts/fetch-vendored-bins.sh (replaces Scripts/fetch-fclones.sh)
- Sources/GargantuaCore/Resources/bin/czkawka_cli
- Sources/GargantuaCore/Services/CzkawkaBinaryResolver.swift
- Sources/GargantuaCore/Services/FclonesBinaryResolver.swift
- Sources/GargantuaCore/Services/VendoredBinarySelfCheck.swift
- Sources/Gargantua/GargantuaApp.swift
- Scripts/smoke/verify-vendored-bins.sh
- Scripts/release/README.md
- Scripts/release/assemble-app.sh
- Resolver/self-check tests under Tests/GargantuaCoreTests/Services/

**Key decisions:**
- Pinned fclones 0.35.0 and czkawka_cli 11.0.1 crates.io checksums in Scripts/vendored-bins.lock.
- Replaced the fclones-only fetcher with a shared fetcher that downloads .crate files, verifies SHA-256, cargo-installs with --locked, strips binaries, and writes Resources/bin/<name>.
- Resolver order now keeps env-var overrides first, then prefers bundled helpers before Homebrew/system fallbacks so release smoke proves the app uses its signed embedded binaries.
- Added Gargantua --selfcheck-binaries through the GUI executable init path and factored output through VendoredBinarySelfCheck for unit coverage.

**Notes for next task:**
- Scripts/smoke/verify-vendored-bins.sh requires a signed installed .app; it checks helper TeamIdentifier against the app and asserts selfcheck paths remain inside the app bundle under PATH=/usr/bin:/bin.
- Full-project swiftlint still has pre-existing violations; the touched Swift files lint clean.

---
*Auto-generated by PASIV*
