# Releasing Gargantua

Canonical, end-to-end guide for cutting a Gargantua release from a local Mac.

The release pipeline produces a signed, notarized, stapled `Gargantua-<version>.dmg`, signs a Sparkle appcast, uploads both to a GitHub Release, and pushes a refreshed Homebrew Cask to `inceptyon-labs/homebrew-tap`.

Three scripts, layered:

| Script | What it does |
| --- | --- |
| `Scripts/release-interactive.sh` | **Canonical entry point.** Prompts for the bump type (patch / minor / major / beta / custom), updates `CHANGELOG.md`, creates the tag, calls `publish.sh`, then prompts to push. |
| `Scripts/publish.sh` | Non-interactive: given a `vX.Y.Z` tag on `HEAD`, runs `release.sh`, then `gh release create` with the DMG + appcast, then pushes `Casks/gargantua.rb` to the tap. |
| `Scripts/release.sh` | The build pipeline: build → assemble → sign → notarize app → DMG → notarize DMG → `spctl --assess` → signed Sparkle appcast. Per-stage notes in [`Scripts/release/README.md`](../Scripts/release/README.md). |

GitHub Actions can do the same thing via `.github/workflows/release.yml`, but local is the day-to-day path. The action exists as a backup / reference implementation.

## Distribution shape

| Surface | What it serves | Hosted by |
| --- | --- | --- |
| Homebrew Cask `inceptyon-labs/tap/gargantua` | First install (`brew install --cask gargantua`) | GitHub Release DMG, fetched by Cask |
| GitHub Release `vX.Y.Z` | Distributable `Gargantua-<version>.dmg` + `appcast.xml` | `inceptyon-labs/gargantua` |
| Sparkle appcast at `releases/latest/download/appcast.xml` | In-app updates after install | GitHub Releases redirect |
| Apple notary | Gatekeeper ticket on app + DMG | Apple |

After the first install, **Sparkle owns updates**. Bumping the Cask only changes what *new* users get on `brew install`; existing users update via the in-app Sparkle channel. The Cask in the tap is therefore intentionally minimal (`livecheck :github_latest`, `auto_updates true`, `app "Gargantua.app"`).

## One-time setup

Do this once per release machine. Each item is a hard prerequisite — `Scripts/publish.sh` will refuse to run with any of them missing.

### 1. Apple Developer ID Application certificate

You need a `Developer ID Application` cert (paid Apple Developer membership). This is what notarization signs against and what Gatekeeper checks at first launch.

1. In Xcode → Settings → Accounts → Manage Certificates → `+` → **Developer ID Application**.
2. Verify it's in the login Keychain:
   ```sh
   security find-identity -v -p codesigning
   ```
   You should see something like `1) ABC123… "Developer ID Application: Inceptyon Labs LLC (TEAMID1234)"`.
3. Copy that **exact** quoted string into `.env.release` as `SIGNING_IDENTITY`.

### 2. notarytool keychain profile

Apple's notarization service authenticates either by App Store Connect API key (CI-friendly) or a stored notarytool keychain profile (laptop-friendly). Local builds use the profile.

```sh
xcrun notarytool store-credentials "gargantua-notary" \
  --apple-id you@example.com \
  --team-id TEAMID1234 \
  --password <app-specific-password>
```

Generate the app-specific password at <https://appleid.apple.com/> → Sign-In and Security → App-Specific Passwords. The profile name (`gargantua-notary`) goes into `.env.release` as `NOTARY_PROFILE`.

### 3. Sparkle EdDSA keypair

Sparkle 2 verifies update artifacts and the appcast feed itself with EdDSA signatures. The private key lives in the macOS Keychain on the release machine; the public key is embedded in `Info.plist` and shipped with every build.

```sh
swift package resolve   # materialises Sparkle's helper binaries under .build/artifacts/
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

Copy the printed public key into `.env.release` as `SPARKLE_PUBLIC_ED_KEY`. The private key never leaves the Keychain on this machine.

If you're standing up a second release machine for the same app, **export the existing private key** instead of generating a new one — every existing install has the original public key embedded and will reject anything signed by a different keypair:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-ed.key   # export
.build/artifacts/sparkle/Sparkle/bin/generate_keys -f sparkle-ed.key   # import on the new machine
```

### 4. `.env.release`

Copy the template and lock it down. The pipeline refuses to source it unless mode is `0600` (it's sourced as shell code; world-readable would let any local user run code in your release shell).

```sh
cp .env.release.example .env.release
chmod 600 .env.release
```

Fill in:

| Var | Source |
| --- | --- |
| `TEAM_ID` | <https://developer.apple.com/account> → Membership |
| `SIGNING_IDENTITY` | `security find-identity -v -p codesigning` |
| `NOTARY_PROFILE` | name passed to `notarytool store-credentials` (default `gargantua-notary`) |
| `SPARKLE_PUBLIC_ED_KEY` | printed by `generate_keys` |
| `SPARKLE_FEED_URL` | leave at default (GitHub Releases `latest`) unless self-hosting |

### 5. GitHub CLI + repo authentication

`Scripts/publish.sh` uses `gh release create` to upload artifacts.

```sh
brew install gh
gh auth login                    # GitHub.com → HTTPS → web flow
gh auth status                   # confirm
```

The authenticated account needs **write** access to `inceptyon-labs/gargantua` (to create releases) and **write** access to `inceptyon-labs/homebrew-tap` (to push the cask). For a personal `gh` login on a personal repo this is automatic; for an org repo confirm membership and SSO in the browser.

### 6. `create-dmg` (recommended)

Without it, the pipeline falls back to a plain `hdiutil`-built DMG that works but doesn't render the polished drag-to-Applications layout.

```sh
brew install create-dmg
```

### 7. Optional: `cmark` or `pandoc`

If installed, the pipeline renders the per-version markdown release notes to HTML for Sparkle. Without either, Sparkle 2.9 renders the markdown directly — also fine.

```sh
brew install cmark
```

## Per-release checklist

Use this before every cut. `Scripts/publish.sh` enforces most of it as a preflight but the human-side bits (CHANGELOG, version bump) are on you.

- [ ] `main` is green: `swift test` passes locally; CI is green on the merge commit.
- [ ] `git status` is clean — no uncommitted edits, no untracked release artifacts in `dist/`.
- [ ] `CHANGELOG.md` has an `[Unreleased]` block describing user-visible changes; ready to be retitled to `[X.Y.Z]`.
- [ ] You're on the commit you want to ship.
- [ ] No drafts in flight — `gh release list` is sane.
- [ ] You have a name in mind for the version. Bug-fix → patch, new user-visible feature → minor, breaking → major. Pre-1.0 the policy is looser; document the change in CHANGELOG.

## Cutting a release

```sh
Scripts/release-interactive.sh
```

The interactive script does the whole flow:

1. Reads the current version from the latest `vX.Y.Z` git tag (or `0.0.0` if none reachable).
2. Shows a numbered menu with previewed bumps (Patch / Minor / Major / Beta / Custom / Cancel).
3. Confirms the summary.
4. Refuses to continue if the chosen tag already exists locally or as a GitHub Release.
5. If the working tree is dirty, asks once whether to stage and commit everything as `chore: prepare release X.Y.Z`. Refuse and you commit yourself.
6. Bumps `CHANGELOG.md`: keeps the `## [Unreleased]` heading empty and inserts `## [X.Y.Z] - YYYY-MM-DD` below it, so the previously-`[Unreleased]` content now lives under the new versioned heading. Commits as `docs: update CHANGELOG for X.Y.Z`.
7. Creates an annotated tag `vX.Y.Z`.
8. Runs `Scripts/publish.sh`, which:
   1. Runs `Scripts/release.sh --ci` → builds the DMG, signs, notarizes app + DMG, staples both, runs `spctl --assess`, and stages `dist/sparkle-updates/appcast.xml` plus `dist/Gargantua-X.Y.Z.dmg`.
   2. Computes the DMG SHA-256.
   3. Pulls the previous release's `appcast.xml` (so item entries stay cumulative) before regenerating.
   4. `gh release create vX.Y.Z` with the DMG and the new `appcast.xml` attached, plus per-version markdown release notes.
   5. Renders `Casks/gargantua.rb` via `Scripts/release/render-cask.sh`, clones `inceptyon-labs/homebrew-tap`, and commits + pushes the cask update.
9. Prompts whether to push `main` and the new tag to `origin`. Decline and the tag stays local — you can re-cut without history rewriting.

If the publish step fails partway through, the local tag is left in place. After fixing the cause you can re-run `Scripts/publish.sh` directly (faster, skips the prompts) — Apple's notary caches by hash so re-submission is fast.

### Smoke test the new release

(On a different machine, ideally a clean user account):

   ```sh
   brew update
   brew upgrade --cask gargantua    # or: brew install --cask gargantua
   open -a Gargantua
   ```

   - First-launch should not show "unidentified developer".
   - Settings → About should report the new version.
   - Trigger a Duplicate Finder scan on `~/Downloads`. Expect a TCC prompt for Downloads access (string from `Info.plist` → `NSDownloadsFolderUsageDescription`), then no further prompts.
   - `Scripts/smoke/verify-vendored-bins.sh /Applications/Gargantua.app` confirms `fclones` / `czkawka_cli` resolved correctly.

## Sparkle update flow

1. The app embeds `SUFeedURL = https://github.com/inceptyon-labs/gargantua/releases/latest/download/appcast.xml` and `SUPublicEDKey = <your public key>` in `Info.plist`.
2. On the configured cadence (default daily), Sparkle fetches `appcast.xml` and verifies its EdDSA signature (`SURequireSignedFeed = true`).
3. If a newer version exists, Sparkle downloads the DMG, verifies its EdDSA signature against the public key, and offers to install.
4. Users on the **beta** channel see pre-release entries that include `<sparkle:channel>beta</sparkle:channel>` in the appcast item; stable users don't.

To ship a beta, tag `vX.Y.Z-beta.N` and let `generate_appcast` mark it as beta automatically (it inspects the version string). Beta opt-in is a toggle in Settings → About.

## Troubleshooting

### `SIGNING_IDENTITY not found in keychain`

Run `security find-identity -v -p codesigning` and copy the **exact** quoted string into `.env.release`. Quotes are part of the match anchor.

### `notarytool submit` failed

The script prints the submission ID and the exact `notarytool log` command to fetch Apple-side rejection details. Most rejections are:

- Missing or wrong hardened-runtime flag (`--options runtime`, set by `sign.sh`).
- Unsigned helper binary inside the bundle (e.g. a freshly fetched `fclones` that didn't pick up codesigning).
- Stale `get-task-allow=true` entitlement.

Re-run `Scripts/release.sh` after fixing — Apple's notary caches by hash, so the second submit of the same artifact is instant.

### `stapler staple` failed

Apple hasn't issued the ticket yet. Wait a minute and re-run `Scripts/release/notarize.sh` against the same target.

### `gh release create` fails with 403 on `inceptyon-labs/gargantua`

Your `gh auth` account doesn't have write on the repo. `gh auth status`, then refresh with `gh auth refresh -s repo,workflow`.

### Tap push fails with 403

Same root cause but on `inceptyon-labs/homebrew-tap`. Confirm membership + SSO in the browser, then `gh auth refresh -h github.com`.

### Sparkle signature mismatch on update

The build embedded a different public key than the one used to sign the appcast. Either:

- `SPARKLE_PUBLIC_ED_KEY` in `.env.release` doesn't match the private key in Keychain — re-export with `generate_keys -p`.
- Or you generated a new keypair on a new release machine instead of importing the original — see One-time setup §3.

### `Sparkle generate_appcast not found`

Run `swift package resolve` once so SPM materialises Sparkle's helper binaries under `.build/artifacts/`. The pipeline expects them there.

### DMG SHA mismatch in tap cask after a re-cut

If you rebuilt the same version (don't), the SHA changed and the tap cask is now wrong for users who haven't updated yet. Bump the patch version, re-tag, re-cut. Don't try to "fix" by editing the cask in place — Homebrew's CDN caches by version.

## Manual recovery

Everything `Scripts/publish.sh` does can be done by hand if the script breaks at a particular step. The exact sequence:

```sh
# 1. Build the DMG and sign the appcast.
Scripts/release.sh

# 2. Compute SHA-256 (cask needs it).
shasum -a 256 dist/Gargantua-X.Y.Z.dmg

# 3. Create the GitHub Release with both artifacts.
gh release create vX.Y.Z \
  --title "Gargantua X.Y.Z" \
  --notes-file dist/sparkle-updates/Gargantua-X.Y.Z.dmg.md \
  dist/Gargantua-X.Y.Z.dmg \
  dist/sparkle-updates/appcast.xml

# 4. Render and push the cask.
SHA=$(shasum -a 256 dist/Gargantua-X.Y.Z.dmg | awk '{print $1}')
git clone https://github.com/inceptyon-labs/homebrew-tap /tmp/tap
Scripts/release/render-cask.sh \
  --version X.Y.Z --sha256 "$SHA" --repo inceptyon-labs/gargantua \
  > /tmp/tap/Casks/gargantua.rb
( cd /tmp/tap && git add Casks/gargantua.rb && \
  git commit -m "Update gargantua to X.Y.Z" && git push )
```

If you find yourself doing this more than once, fix `publish.sh` instead.

## What the release scripts do NOT do

- `Scripts/publish.sh` does not push the git tag — `release-interactive.sh` prompts at the end. Pushing the tag is the last revertible point; until you push, you can `git tag -d vX.Y.Z` and re-cut.
- They do not rev `Package.swift`. Version is derived from the git tag.
- They do not run mutation tests, security scans, or the dependency CVE check. CI runs those on `main`; release inherits whatever was last green.
- They do not announce anything externally. No tweet, no blog, no Slack — that's a person's job.
