#!/usr/bin/env bash
# Scripts/publish.sh — local-Mac one-shot publish.
#
# Wraps Scripts/release.sh and then mirrors what .github/workflows/release.yml
# does after the build: creates a GitHub Release with the DMG + appcast,
# and pushes Casks/gargantua.rb to inceptyon-labs/homebrew-tap.
#
# Usage:
#   git tag vX.Y.Z
#   ./Scripts/publish.sh
#
# Outputs (in addition to release.sh's outputs under dist/):
#   - GitHub Release vX.Y.Z on $REPO with Gargantua-X.Y.Z.dmg + appcast.xml.
#   - Casks/gargantua.rb committed and pushed to $TAP_REPO.

set -euo pipefail

usage() {
    cat <<'USAGE'
usage: ./Scripts/publish.sh [options]

Cut a release locally: build, sign, notarize, package, then publish to
GitHub Releases and bump the Homebrew tap cask.

Options:
  --skip-tap       Skip the tap-cask push (still creates the GitHub Release).
                   Useful when the tap repo is offline or you're testing.
  --skip-release   Skip the GitHub Release upload and the tap push. Stops
                   after release.sh produces dist/Gargantua-<version>.dmg
                   and dist/sparkle-updates/appcast.xml.
  --dry-run        Pass through to release.sh (no signing, no notarytool,
                   no filesystem writes). Implies --skip-release and --skip-tap.
  --allow-dirty    Allow a dirty git tree. Default: refuse.
  -h, --help       Show this help.

Required environment (set in .env.release — gitignored — or exported):
  TEAM_ID, SIGNING_IDENTITY, NOTARY_PROFILE, SPARKLE_PUBLIC_ED_KEY,
  SPARKLE_FEED_URL. See docs/RELEASING.md and .env.release.example.

Required tools: swift, gh, git, shasum (codesign/notarytool/stapler/etc are
checked by release.sh's preflight).
USAGE
}

SKIP_TAP=0
SKIP_RELEASE=0
DRY_RUN=0
ALLOW_DIRTY=0

RELEASE_FLAGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-tap)     SKIP_TAP=1 ;;
        --skip-release) SKIP_RELEASE=1; SKIP_TAP=1 ;;
        --dry-run)
            DRY_RUN=1
            SKIP_RELEASE=1
            SKIP_TAP=1
            RELEASE_FLAGS+=(--dry-run --snapshot)
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            RELEASE_FLAGS+=(--allow-dirty)
            ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'publish.sh: unknown flag: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# release.sh's --ci removes dist/ unconditionally (no interactive prompt) and
# implies --allow-dirty for worktree checkouts. For local publish we want the
# non-interactive sweep, but we want the dirty-tree check to be ours, not
# release.sh's, so we can give a publish-specific error message.
if [ "$DRY_RUN" != 1 ]; then
    RELEASE_FLAGS+=(--ci)
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ----- Preflight ------------------------------------------------------------

# Tools used by publish.sh itself (release.sh checks its own).
if [ "$SKIP_RELEASE" != 1 ]; then
    command -v gh >/dev/null 2>&1 \
        || die "gh CLI not installed. brew install gh && gh auth login. See docs/RELEASING.md."
    if ! gh auth status >/dev/null 2>&1; then
        die "gh CLI not authenticated. Run: gh auth login"
    fi
fi
command -v shasum >/dev/null 2>&1 || die "shasum not found (macOS system tool)"
command -v git >/dev/null 2>&1 || die "git not found"

# Tag must exist on HEAD and start with v. We resolve VERSION ourselves rather
# than waiting for release.sh's _env.sh, so the publish-specific error wording
# fires before any heavy work.
if [ "$DRY_RUN" != 1 ]; then
    if ! git describe --tags --exact-match HEAD >/dev/null 2>&1; then
        die "HEAD is not on a tag. Run: git tag vX.Y.Z (or use --dry-run for a snapshot smoke test)"
    fi
    TAG="$(git describe --tags --exact-match HEAD)"
    case "$TAG" in
        v*) VERSION="${TAG#v}" ;;
        *)  die "tag '$TAG' must start with 'v' (e.g. v0.2.0)" ;;
    esac
else
    VERSION="0.0.0-$(git rev-parse --short HEAD)"
    TAG="v$VERSION"
fi

# Refuse a dirty tree unless explicitly opted in.
if [ "$ALLOW_DIRTY" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    if [ -n "$(git status --porcelain)" ]; then
        die "git working tree is dirty. Commit / stash first, or pass --allow-dirty."
    fi
fi

# Refuse to clobber an existing GitHub release on the same tag.
if [ "$SKIP_RELEASE" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
    if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
        die "GitHub release $TAG already exists on $REPO_SLUG. Bump the tag (e.g. $(echo "$VERSION" | awk -F. '{print "v"$1"."$2"."$3+1}')) and re-cut."
    fi
fi

# The GitHub release must sit on the commit we build. When the tag isn't on
# GitHub yet, `gh release create` makes one at the default branch's tip
# instead, which is how v0.4.12's GitHub tag ended up a commit short of its
# DMG. Catch a conflicting remote tag here, before the long build; the tag
# itself is pushed just before the release is created.
remote_tag_commit() {
    git ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}" \
        | awk -v plain="refs/tags/$TAG" -v peeled="refs/tags/$TAG^{}" \
            '$2 == plain { p = $1 } $2 == peeled { c = $1 } END { print (c != "" ? c : p) }'
}
if [ "$SKIP_RELEASE" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    TAG_COMMIT="$(git rev-parse "$TAG^{commit}")"
    REMOTE_TAG_COMMIT="$(remote_tag_commit)" || die "could not reach origin to check tag $TAG"
    if [ -n "$REMOTE_TAG_COMMIT" ] && [ "$REMOTE_TAG_COMMIT" != "$TAG_COMMIT" ]; then
        die "origin's $TAG points at ${REMOTE_TAG_COMMIT:0:7} but the local $TAG is ${TAG_COMMIT:0:7}. Re-point one of them before publishing."
    fi
fi

log "Publishing Gargantua $VERSION (tag $TAG)..."

# Single cleanup hook for every temp dir we create below. Set before any of
# them exist so an early failure still tidies up.
BUILD_PARENT=""
TAP_DIR=""
cleanup() {
    if [ -n "$BUILD_PARENT" ] && [ -d "$BUILD_PARENT" ]; then
        git -C "$REPO_ROOT" worktree remove --force "$BUILD_PARENT/src" 2>/dev/null || true
        rm -rf "$BUILD_PARENT"
        git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
    fi
    [ -n "$TAP_DIR" ] && rm -rf "$TAP_DIR"
}
trap cleanup EXIT

# ----- Stage 1: build, sign, notarize, package ------------------------------
#
# Build from a pristine git worktree checked out at $TAG, NOT in-place from
# REPO_ROOT. This guarantees the artifact is exactly the tagged commit and
# isolates the build from any edits made to the working tree while the
# multi-minute build + notarize runs (an in-place build will silently bake in
# whatever happens to be on disk when each file compiles). .build/ and
# .env.release are gitignored, so the worktree gets a fresh SPM build and we
# hand-copy .env.release — the only build input git doesn't carry.
if [ "$DRY_RUN" = 1 ]; then
    # Snapshot smoke test: VERSION is a synthetic 0.0.0-<sha>, there's no tag to
    # check out, and nothing gets signed or published. Build in place.
    BUILD_ROOT="$REPO_ROOT"
    log "Running Scripts/release.sh ${RELEASE_FLAGS[*]} (in-place, dry-run)..."
    "$REPO_ROOT/Scripts/release.sh" "${RELEASE_FLAGS[@]}"
else
    BUILD_PARENT="$(mktemp -d -t gargantua-build-XXXXXX)"
    BUILD_ROOT="$BUILD_PARENT/src"
    log "Checking out $TAG into a clean build worktree..."
    git worktree add --detach "$BUILD_ROOT" "$TAG" >/dev/null
    if [ -f "$REPO_ROOT/.env.release" ]; then
        cp -p "$REPO_ROOT/.env.release" "$BUILD_ROOT/.env.release"
    fi
    log "Running Scripts/release.sh ${RELEASE_FLAGS[*]} (clean worktree @ $TAG)..."
    ( cd "$BUILD_ROOT" && ./Scripts/release.sh "${RELEASE_FLAGS[@]}" )

    # Mirror the build output back to the canonical dist/ so downstream stages
    # and the documented "artifacts live in dist/" contract are unchanged, and
    # the artifacts survive the worktree cleanup below.
    rm -rf "$REPO_ROOT/dist"
    mkdir -p "$REPO_ROOT/dist"
    cp -R "$BUILD_ROOT/dist/." "$REPO_ROOT/dist/"
fi

DMG_PATH="$REPO_ROOT/dist/Gargantua-${VERSION}.dmg"
APPCAST_PATH="$REPO_ROOT/dist/sparkle-updates/appcast.xml"
NOTES_PATH="$REPO_ROOT/dist/sparkle-updates/Gargantua-${VERSION}.md"

if [ "$SKIP_RELEASE" = 1 ]; then
    log "Stopped after build (per --skip-release / --dry-run)."
    log "  DMG:     $DMG_PATH"
    log "  Appcast: $APPCAST_PATH"
    exit 0
fi

[ -f "$DMG_PATH" ]     || die "expected DMG not found: $DMG_PATH"
[ -f "$APPCAST_PATH" ] || die "expected appcast not found: $APPCAST_PATH"

# release.sh's appcast.sh produces a per-version markdown notes file from the
# CHANGELOG. If something went sideways and it's missing, fall back to a stub
# rather than failing the publish.
if [ ! -f "$NOTES_PATH" ]; then
    warn "release notes not found at $NOTES_PATH; writing fallback"
    printf '# Gargantua %s\n\nSee CHANGELOG.md for details.\n' "$VERSION" > "$NOTES_PATH"
fi

# ----- Stage 2: GitHub Release ----------------------------------------------

# The appcast references release notes by URL
# (.../latest/download/Gargantua-X.Y.Z.md), so the signed notes file must be
# uploaded as a release asset — not merely used as the release body — or
# Sparkle's release-notes pane spins forever fetching a missing file.
RELEASE_ASSETS=("$DMG_PATH" "$APPCAST_PATH" "$NOTES_PATH")
NOTES_HTML_PATH="$REPO_ROOT/dist/sparkle-updates/Gargantua-${VERSION}.html"
[ -f "$NOTES_HTML_PATH" ] && RELEASE_ASSETS+=("$NOTES_HTML_PATH")

if [ -z "$(remote_tag_commit)" ]; then
    log "Pushing tag $TAG to origin..."
    git push origin "refs/tags/$TAG"
fi

log "Creating GitHub Release $TAG on $REPO_SLUG..."
gh release create "$TAG" \
    --repo "$REPO_SLUG" \
    --verify-tag \
    --title "Gargantua $VERSION" \
    --notes-file "$NOTES_PATH" \
    "${RELEASE_ASSETS[@]}"

# ----- Stage 3: Homebrew tap cask -------------------------------------------

if [ "$SKIP_TAP" = 1 ]; then
    log "Skipping Homebrew tap cask push (per --skip-tap)."
    log ""
    log "Publish complete (release only)."
    log "  Release: https://github.com/$REPO_SLUG/releases/tag/$TAG"
    exit 0
fi

TAP_REPO="${TAP_REPO:-inceptyon-labs/homebrew-tap}"

# Confirm we can write the tap before producing the cask file.
if ! gh repo view "$TAP_REPO" >/dev/null 2>&1; then
    die "cannot access $TAP_REPO via gh. Confirm membership and rerun: gh auth refresh -s repo"
fi

DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
log "DMG sha256: $DMG_SHA256"

TAP_DIR="$(mktemp -d -t gargantua-tap-XXXXXX)"

log "Cloning $TAP_REPO into $TAP_DIR..."
gh repo clone "$TAP_REPO" "$TAP_DIR" -- --depth 1 >/dev/null

mkdir -p "$TAP_DIR/Casks"
"$REPO_ROOT/Scripts/release/render-cask.sh" \
    --version "$VERSION" \
    --sha256  "$DMG_SHA256" \
    --repo    "$REPO_SLUG" \
    > "$TAP_DIR/Casks/gargantua.rb"

(
    cd "$TAP_DIR"
    git add Casks/gargantua.rb
    # `git diff --cached --quiet` is the right check after `git add`: it
    # exits non-zero when there's anything to commit (new file or modified
    # file), zero when the staged tree matches HEAD. A plain
    # `git diff --quiet -- Casks/gargantua.rb` would silently miss a fresh
    # add since untracked files aren't in the diff at all.
    if git diff --cached --quiet; then
        log "Cask already up to date for $VERSION on $TAP_REPO"
    else
        git commit -m "Update gargantua to $VERSION"
        git push origin HEAD
        log "Pushed Casks/gargantua.rb to $TAP_REPO"
    fi
)

log ""
log "Publish complete."
log "  Release: https://github.com/$REPO_SLUG/releases/tag/$TAG"
log "  Tap:     https://github.com/$TAP_REPO/blob/HEAD/Casks/gargantua.rb"
log ""
log "Next:"
log "  - git push origin main (the tag is already on GitHub)"
log "  - On a clean machine: brew update && brew upgrade --cask gargantua"
