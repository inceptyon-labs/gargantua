# Release pipeline

Produces a signed, notarized, stapled `Gargantua-<version>.dmg` from the
SPM sources. Canonical entry point is `Scripts/release.sh`. Full design:
[`docs/designs/2026-04-19-macos-release-pipeline.md`](../../docs/designs/2026-04-19-macos-release-pipeline.md).

## One-time setup

1. **Provision a `Developer ID Application` cert** in the login Keychain.
   Verify with:

   ```sh
   security find-identity -v -p codesigning
   ```

   You should see an entry like:

   ```text
   1) ABC123…  "Developer ID Application: Your Name (TEAMID1234)"
   ```

2. **Store notarytool credentials** in a keychain profile (do this once):

   ```sh
   xcrun notarytool store-credentials "gargantua-notary" \
     --apple-id you@example.com \
     --team-id TEAMID1234 \
     --password <app-specific-password>
   ```

   Generate the app-specific password at <https://appleid.apple.com/>.

3. **Create `.env.release`** from the template and lock it down:

   ```sh
   cp .env.release.example .env.release
   chmod 600 .env.release
   # Edit: TEAM_ID, SIGNING_IDENTITY, NOTARY_PROFILE,
   #       SPARKLE_PUBLIC_ED_KEY, SPARKLE_FEED_URL
   ```

   The pipeline refuses to source `.env.release` unless it's mode `0600`
   (sourced as shell code; 0644 would let any local user run arbitrary
   commands in your release shell). `.env.release` is gitignored.

4. **Optional: install create-dmg** for a polished drag-to-Applications layout:

   ```sh
   brew install create-dmg
   ```

   Without it, the pipeline falls back to plain `hdiutil` (functional, not
   polished).

   Optional: install `cmark` or `pandoc` if you want the appcast step to
   convert changelog markdown to HTML release notes. Without either tool,
   Sparkle 2.9 renders the staged markdown notes directly.

5. **Generate Sparkle EdDSA keys** once on the release machine:

   ```sh
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   Put the printed public key in `SPARKLE_PUBLIC_ED_KEY`. Keep the private
   key in Keychain or CI secrets only; never commit it.

## Cutting a release

```sh
git tag v0.1.0
./Scripts/release.sh
```

Outputs:

- `dist/Gargantua.app`              — signed, notarized, stapled
- `dist/Gargantua-0.1.0.dmg`        — stapled, ready to distribute
- `dist/sparkle-updates/appcast.xml` — signed Sparkle appcast plus staged DMG

## Dev builds

```sh
./Scripts/release.sh --snapshot
```

No tag required. Version becomes `0.0.0-<short-sha>`. Still fully signs
and notarizes — useful for validating the whole pipeline between real
release cuts.

## Smoke testing the pipeline itself

```sh
./Scripts/release.sh --snapshot --dry-run
```

Exercises every code path, logs every command, and executes none of the
destructive ones. No `codesign`, no `notarytool`, no filesystem writes.
Great for CI smoke or debugging on a machine without a valid Developer ID
cert.

## Flags

| Flag            | Effect                                                          |
|-----------------|-----------------------------------------------------------------|
| `--snapshot`    | Allow untagged HEAD; VERSION becomes `0.0.0-<sha>`.             |
| `--dry-run`     | Log all commands, execute none of the destructive ones.         |
| `--allow-dirty` | Allow a dirty git tree.                                         |
| `--ci`          | Non-interactive; removes `dist/` unconditionally; implies `--allow-dirty`. |

## Pipeline stages

Each stage is a separate script under `Scripts/release/` and can be run
standalone for debugging (after the preceding stages have succeeded):

| Stage           | Script                       | What it does                                        |
|-----------------|------------------------------|-----------------------------------------------------|
| Environment     | `_env.sh`                    | Resolves VERSION, paths, identities; sourced.       |
| Build           | `build.sh`                   | `swift build -c release --arch arm64`.              |
| Assemble        | `assemble-app.sh`            | Lays out `dist/Gargantua.app`; renders Info.plist.  |
| Sign            | `sign.sh`                    | Strip shipped Mach-O executables, then codesign.    |
| Notarize (app)  | `notarize.sh $APP_BUNDLE`    | ditto-zip → notarytool submit --wait → staple app.  |
| DMG build       | `dmg.sh`                     | create-dmg (or hdiutil), via staging directory.     |
| Notarize (DMG)  | `notarize.sh $DMG_PATH`      | notarytool submit --wait → staple DMG.              |
| Verify          | (inline in `release.sh`)     | `spctl --assess` on both app and DMG.               |
| Appcast         | `appcast.sh`                 | stages DMG + markdown notes; runs `generate_appcast`. |

**Why two notarizations?** The `.app` gets its own ticket so it stays
Gatekeeper-clean once extracted to `/Applications` — including offline.
The DMG gets its own ticket so the *downloaded artifact* is also
verifiable (stapling only works on the specific thing that was submitted;
a notarized `.app` inside a fresh DMG doesn't make the DMG notarized).
Apple's notary caches by hash, so the second submission is typically
fast.

## Troubleshooting

### `SIGNING_IDENTITY not found in keychain`

Run `security find-identity -v -p codesigning` and copy the **exact**
string (quotes included, without the leading index number) into
`.env.release`.

### `notarytool submit` failed

The script prints the submission ID and the `notarytool log` command to
fetch the Apple-side rejection details. Most rejections are:

- Missing / bad hardened-runtime flag (`--options runtime`).
- Unsigned helper binary inside the bundle.
- Stale `get-task-allow=true` entitlement.

### `stapler staple` failed

Apple hasn't issued the ticket yet. Re-run `notarize.sh` alone after a
minute; notarytool returns the cached verdict instantly on re-submit.

### `spctl` rejects the app

Inspect:

```sh
codesign -dv --verbose=4 dist/Gargantua.app
xcrun stapler validate dist/Gargantua.app
```

## Fresh-install smoke (user-performed)

Automated verification reaches as far as `spctl --assess`. After dragging
the app into `/Applications`, verify embedded helper selection and signing:

```sh
Scripts/smoke/verify-vendored-bins.sh /Applications/Gargantua.app
```

Then finish the user-facing smoke manually:

1. Fresh user account or VM with no Gargantua history.
2. Transfer `Gargantua-<version>.dmg` via Finder / browser download.
3. Mount; drag `Gargantua.app` to `/Applications`.
4. Run the vendored helper smoke script above.
5. Launch. Expect no quarantine prompt and no "unidentified developer"
   dialog.
6. Trigger a Duplicate Finder scan on `~/Downloads` — macOS should
   prompt for Downloads access (via TCC) using our `NSDownloadsFolder…`
   string from `Info.plist`, then scan without further prompts.

This is what `gargantua-vzuz` tracks as its final acceptance.
