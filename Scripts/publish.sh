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

log "Publishing Gargantua $VERSION (tag $TAG)..."

# ----- Stage 1: build, sign, notarize, package ------------------------------

log "Running Scripts/release.sh ${RELEASE_FLAGS[*]}..."
"$REPO_ROOT/Scripts/release.sh" "${RELEASE_FLAGS[@]}"

DMG_PATH="$REPO_ROOT/dist/Gargantua-${VERSION}.dmg"
APPCAST_PATH="$REPO_ROOT/dist/sparkle-updates/appcast.xml"
NOTES_PATH="$REPO_ROOT/dist/sparkle-updates/Gargantua-${VERSION}.dmg.md"

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

log "Creating GitHub Release $TAG on $REPO_SLUG..."
gh release create "$TAG" \
    --repo "$REPO_SLUG" \
    --title "Gargantua $VERSION" \
    --notes-file "$NOTES_PATH" \
    "$DMG_PATH" \
    "$APPCAST_PATH"

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
trap 'rm -rf "$TAP_DIR"' EXIT

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
log "  - git push origin main $TAG"
log "  - On a clean machine: brew update && brew upgrade --cask gargantua"
