# Vendored Helper Binaries Design

**Date:** 2026-04-20
**Status:** Validated
**Bean:** `gargantua-vzuz`

## Summary

Harden the fclones vendoring pattern and extend it to `czkawka_cli`, so both helper binaries ship checked-in, SHA-256-pinned against crates.io, and exercised by a lightweight post-install smoke script. Signing and notarization are already handled by the release pipeline (`gargantua-9495`) and are explicitly out of scope here.

## Goals

- One canonical lockfile (`Scripts/vendored-bins.lock`) records version + SHA-256 for every checked-in helper binary.
- One generic fetcher (`Scripts/fetch-vendored-bins.sh`) verifies against the lockfile, builds via `cargo install --locked`, strips, and writes to `Sources/GargantuaCore/Resources/bin/`.
- `czkawka_cli` is vendored at the same rung as `fclones` today — checked into the resource bundle, reachable via `Bundle.module`.
- A lightweight smoke script verifies that the installed `.app` uses its own helpers (not brew) and that both are signed by our team ID.

## Non-Goals (Out of Scope)

- **Intel / universal builds** — spawn `gargantua-<new>` tracking it; no current bean is blocked on Intel.
- **Team-ID signing** — already handled by `Scripts/release/sign.sh` (inside-out).
- **Notarization + stapling** — already handled by `Scripts/release/notarize.sh` (app + DMG).
- **SwiftPM build-phase integration** — binaries stay checked in; fetcher is maintainer-invoked.
- **czkawka trust-layer / safety-classifier wiring** — tracked in `gargantua-c6s7` / `gargantua-i36a`.
- **Hard enforcement of PRD §8.3 bundle budget** — fetcher logs sizes; no blocking ceiling.
- **GitHub Actions CI smoke of the DMG** — natural home is the future release-workflow bean.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Intel coverage | Deferred to its own bean | No CI yet; no real users yet; YAGNI. |
| SHA-256 pin storage | Lockfile (`Scripts/vendored-bins.lock`) | Single-line bumps; mirrors Cargo.lock idiom; extensible to N binaries. |
| Smoke artifact | Lightweight bash script (`Scripts/smoke/verify-vendored-bins.sh`) + README checklist | Repeatable; no infrastructure needed; complements human-eye steps. |
| czkawka scope | Same bean as fclones | Pattern is only "reusable" once it's applied twice; delta is mechanical. |
| Binary storage | Checked into git (status quo) | `swift test` works offline; fetcher runs only on bumps; 25 MB is tolerable. |

## Architecture

### Repo additions / changes

```
Scripts/
├── vendored-bins.lock                        ← NEW: single source of truth
├── fetch-vendored-bins.sh                    ← NEW: generic fetcher (replaces fetch-fclones.sh)
├── fetch-fclones.sh                          ← DELETED (covered by the generic fetcher)
└── smoke/
    └── verify-vendored-bins.sh               ← NEW: post-install smoke

Sources/GargantuaCore/
├── Resources/bin/
│   ├── fclones                               ← existing; no re-vendor needed for this bean
│   └── czkawka_cli                           ← NEW: checked-in blob
└── Services/
    └── CzkawkaBinaryResolver.swift           ← Bundle.main → Bundle.module + "bin/" fix

Tests/GargantuaCoreTests/Services/
└── CzkawkaBinaryResolverTests.swift          ← +2 cases mirroring FclonesBinaryResolverTests

Sources/Gargantua/
└── main.swift (or CLI dispatch entry)        ← new --selfcheck-binaries flag
```

### Lockfile format

Shell-sourceable key=value. Zero parser dependencies.

```
# Scripts/vendored-bins.lock
# Bump a version → regenerate SHA-256 → commit lockfile delta + new blob together.

FCLONES_VERSION=0.35.0
FCLONES_SHA256=<64-hex from https://crates.io/api/v1/crates/fclones/0.35.0>

CZKAWKA_CLI_VERSION=<pinned at landing>
CZKAWKA_CLI_SHA256=<64-hex from crates.io>
```

### Fetcher contract

`Scripts/fetch-vendored-bins.sh` iterates a known list. For each binary:
1. Download the `.crate` tarball from `https://static.crates.io/crates/<name>/<name>-<version>.crate`.
2. Verify SHA-256 against the lockfile value; abort on mismatch (no lockfile write).
3. `cargo install <name> --version <version> --locked --root <tmp> --quiet`.
4. `cp` to `Sources/GargantuaCore/Resources/bin/<name>`; `chmod 0755`; `strip` (best-effort).
5. Log size + path.

Retains the aarch64-only host guard from `fetch-fclones.sh`. Explicit "Intel deferred" header comment.

### Resolver fix

Apply the same Bundle-fallback shape as the fclones fix already in main:

```swift
bundledURL: Bundle.module.url(forResource: "bin/czkawka_cli", withExtension: nil)
    ?? Bundle.module.resourceURL?.appendingPathComponent("bin/czkawka_cli")
```

Plus two tests in `CzkawkaBinaryResolverTests`:
- `vendoredBinaryResolvable` — `Bundle.module/bin/czkawka_cli` exists + is executable.
- `vendoredBinaryResolvesWhenPathEmpty` — with PATH neutralized, `resolve()` returns the bundled URL.

### Self-check entry point

New `Gargantua --selfcheck-binaries` flag (or equivalent dispatch in the CLI target) that:
1. Runs `FclonesBinaryResolver().resolve()` → prints `fclones: <url>`.
2. Runs `CzkawkaBinaryResolver().resolve()` → prints `czkawka_cli: <url>`.
3. Exits 0 on both success, non-zero on any resolution error.

Exposes the resolver's decision-making from outside the GUI path so the smoke script doesn't need to instrument the full app.

### Smoke script

`Scripts/smoke/verify-vendored-bins.sh` (run by a user on a fresh macOS install, after dragging the `.app` to `/Applications`):

1. Assert `Gargantua.app/Contents/Resources/Gargantua_GargantuaCore.bundle/bin/{fclones,czkawka_cli}` exist and are executable.
2. Assert `codesign -dv` on each helper returns an Authority line starting with `Developer ID Application:`.
3. With `PATH=/usr/bin:/bin`, run `.../MacOS/Gargantua --selfcheck-binaries`; assert both resolved paths are inside the `.app`, not `/opt/homebrew/…`.

## Key Flows

### Bumping a pinned version (maintainer)
```
1. Get new SHA: curl -sL https://crates.io/api/v1/crates/<name>/<version> | jq -r .version.checksum
2. Edit Scripts/vendored-bins.lock (version + sha).
3. Scripts/fetch-vendored-bins.sh
4. swift test            # resolver tests re-verify the new blob
5. git commit both the lockfile delta and the new bin/<name> blob together.
```

### Initial czkawka_cli landing (this bean)
```
1. Pick pinned version; fetch its SHA.
2. Append CZKAWKA_CLI_* stanza to vendored-bins.lock.
3. fetch-vendored-bins.sh → Resources/bin/czkawka_cli.
4. Fix CzkawkaBinaryResolver.swift (Bundle.main → Bundle.module + "bin/").
5. Mirror FclonesBinaryResolverTests → CzkawkaBinaryResolverTests (+2 cases).
6. Wire --selfcheck-binaries into the CLI dispatch.
7. Scripts/smoke/verify-vendored-bins.sh (new).
8. One commit per logical unit: (a) generic fetcher + delete fetch-fclones.sh,
   (b) czkawka vendor + lockfile + blob, (c) resolver fix + tests,
   (d) --selfcheck flag, (e) smoke script + README update.
```

### Post-release smoke (user, fresh account)
```
1. Install Gargantua.app to /Applications.
2. Scripts/smoke/verify-vendored-bins.sh → asserts bundled helpers are team-ID-
   signed and selected in preference to brew.
3. Open the app; drive a Duplicate Finder scan on ~/Downloads; confirm TCC
   prompt text comes from Info.plist's NSDownloadsFolderUsageDescription.
```

## Edge Cases

- **SHA-256 mismatch at fetch** → `die` with expected vs. actual; lockfile untouched; binary unchanged. Caller investigates (network MITM, registry anomaly).
- **Non-aarch64 host** → retain the existing guard; instruct to wait on the Intel follow-up bean.
- **cargo missing** → fetcher fails with install hint; not a concern for clone-and-build users (binaries are checked in).
- **czkawka build failure on certain versions** → surface cargo stderr; pin stays at last-known-good.
- **Self-check resolves to brew path** → smoke fails loudly; indicates the resolver's PATH fallback wrongly out-ranked the bundle — real bug.
- **Blob bumped without lockfile delta** → fetcher re-verifies on next run and fails SHA check; reviewer also catches in `git diff`.
- **PRD §8.3 budget blown by czkawka** → fetcher logs size; warns above ~25 MB threshold; doesn't block.
- **Copy-paste error reintroducing `Bundle.main`** in the resolver → `vendoredBinaryResolvesWhenPathEmpty` test catches it, same guardrail that caught vchj's near-miss.

## Open Questions

None — all resolved in the brainstorm. One minor item to decide at implementation time: the exact czkawka_cli version to pin (latest stable at implementation time; 9.0.0 is typical).

## Next Steps

- [ ] Promote `gargantua-vzuz` out of draft; rewrite its ACs to match this design.
- [ ] File `gargantua-<new>` tracking Intel / universal builds.
- [ ] Kick `gargantua-vzuz` when ready.
