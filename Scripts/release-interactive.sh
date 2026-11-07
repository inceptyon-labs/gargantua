#!/usr/bin/env bash
# Scripts/release-interactive.sh — interactive top-level release entry point.
#
# Mirrors the freeport release flow:
#   1. Read current version from `git describe --tags --abbrev=0`.
#   2. Show a numbered menu: patch / minor / major / beta / custom / cancel.
#   3. Confirm the summary.
#   4. Offer to commit any ambient changes (only with explicit consent).
#   5. Bump CHANGELOG.md: rename [Unreleased] → [X.Y.Z] - DATE, prepend a
#      fresh empty [Unreleased] block.
#   6. Commit the CHANGELOG bump.
#   7. Create the annotated git tag vX.Y.Z.
#   8. Run Scripts/publish.sh — builds, signs, notarizes, uploads to GitHub
#      Releases, pushes Casks/gargantua.rb to inceptyon-labs/homebrew-tap.
#   9. After publish succeeds, prompt to push main + the tag.
#
# Use Scripts/publish.sh directly when you already created the tag and just
# want the non-interactive build+upload (e.g. recovering from a partial run).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ----- Output helpers -------------------------------------------------------

if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[0;36m'; GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; GRAY=$'\033[0;90m'; NC=$'\033[0m'
else
    BOLD=""; DIM=""; CYAN=""; GREEN=""; YELLOW=""; RED=""; GRAY=""; NC=""
fi

log()   { printf '%s==>%s %s\n'   "$CYAN"   "$NC" "$*"; }
ok()    { printf '%s✓%s %s\n'     "$GREEN"  "$NC" "$*"; }
warn()  { printf '%swarn:%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
err()   { printf '%serror:%s %s\n' "$RED"   "$NC" "$*" >&2; }
die()   { err "$*"; exit 1; }

ask_yn() {
    # ask_yn "Prompt" [default-y|default-n]
    local prompt="$1"
    local default="${2:-default-n}"
    local hint reply
    case "$default" in
        default-y) hint="[Y/n]" ;;
        *)         hint="[y/N]" ;;
    esac
    printf '%s %s ' "$prompt" "$hint" >&2
    IFS= read -r reply
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        n|N|no|NO)   return 1 ;;
        "")
            [ "$default" = "default-y" ] && return 0
            return 1 ;;
        *) return 1 ;;
    esac
}

# ----- Preflight ------------------------------------------------------------

command -v git >/dev/null 2>&1     || die "git not found"
command -v gh >/dev/null 2>&1      || die "gh CLI not installed. brew install gh && gh auth login. See docs/RELEASING.md."
command -v swift >/dev/null 2>&1   || die "swift not found; install Xcode Command Line Tools"
command -v shasum >/dev/null 2>&1  || die "shasum not found (macOS system tool)"

if ! gh auth status >/dev/null 2>&1; then
    die "gh CLI not authenticated. Run: gh auth login"
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "main" ]; then
    warn "current branch is '$CURRENT_BRANCH', not 'main'"
    ask_yn "Continue anyway?" default-n || die "release cancelled"
fi

# ----- Resolve current version ---------------------------------------------

if CURRENT_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null)"; then
    CURRENT_VERSION="${CURRENT_TAG#v}"
else
    CURRENT_VERSION="0.0.0"
fi

# Strip any prerelease suffix to compute next-stable bumps cleanly.
BASE_VERSION="${CURRENT_VERSION%%-*}"

if ! [[ "$BASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "current version '$CURRENT_VERSION' doesn't parse as semver. Tag a starting point manually (e.g. git tag v0.1.0) and re-run."
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$BASE_VERSION"

PATCH_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
MINOR_VERSION="${MAJOR}.$((MINOR + 1)).0"
MAJOR_VERSION="$((MAJOR + 1)).0.0"
# Beta off the next-patch base, matching the freeport convention.
BETA_VERSION="${PATCH_VERSION}-beta.1"

REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "<unknown repo>")"

# ----- Menu -----------------------------------------------------------------

printf '\n'
printf '%s%sGargantua release%s\n' "$BOLD" "$CYAN" "$NC"
printf '  Current version: %s%s%s\n' "$CYAN" "$CURRENT_VERSION" "$NC"
printf '  Repository:      %s%s%s\n' "$GRAY" "$REPO_SLUG"      "$NC"
printf '  Branch:          %s%s%s\n' "$GRAY" "$CURRENT_BRANCH" "$NC"
printf '\n'
printf '%sSelect release type:%s\n' "$BOLD" "$NC"
printf '\n'
printf '  %s1)%s Patch  → %s%s%s   (bug fixes)\n'         "$CYAN" "$NC" "$GREEN" "$PATCH_VERSION" "$NC"
printf '  %s2)%s Minor  → %s%s%s   (new features)\n'      "$CYAN" "$NC" "$GREEN" "$MINOR_VERSION" "$NC"
printf '  %s3)%s Major  → %s%s%s   (breaking changes)\n'  "$CYAN" "$NC" "$GREEN" "$MAJOR_VERSION" "$NC"
printf '  %s4)%s Beta   → %s%s%s   (pre-release of next patch)\n' "$CYAN" "$NC" "$GREEN" "$BETA_VERSION" "$NC"
printf '  %s5)%s Custom (e.g. 0.5.0, 0.5.0-beta.2)\n'     "$CYAN" "$NC"
printf '  %s6)%s Cancel\n'                                "$CYAN" "$NC"
printf '\n'
printf 'Choice [1-6]: '
IFS= read -r choice

case "$choice" in
    1) NEW_VERSION="$PATCH_VERSION" ;;
    2) NEW_VERSION="$MINOR_VERSION" ;;
    3) NEW_VERSION="$MAJOR_VERSION" ;;
    4) NEW_VERSION="$BETA_VERSION" ;;
    5)
        printf 'Enter version (e.g. 0.5.0 or 0.5.0-beta.2): '
        IFS= read -r NEW_VERSION
        if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; then
            die "invalid version format: $NEW_VERSION"
        fi
        ;;
    6|*)
        log "release cancelled"
        exit 0
        ;;
esac

IS_BETA=false
[[ "$NEW_VERSION" == *"-"* ]] && IS_BETA=true
TAG_NAME="v${NEW_VERSION}"

# ----- Confirm --------------------------------------------------------------

printf '\n'
printf '%sRelease summary%s\n' "$BOLD" "$NC"
printf '  Current:    %s\n' "$CURRENT_VERSION"
printf '  New:        %s%s%s\n' "$GREEN" "$NEW_VERSION" "$NC"
printf '  Tag:        %s\n' "$TAG_NAME"
printf '  Channel:    %s\n' "$([ "$IS_BETA" = true ] && echo "beta" || echo "stable")"
printf '  Repository: %s\n' "$REPO_SLUG"
printf '\n'

ask_yn "Proceed with release?" default-n || die "release cancelled"

# ----- Refuse if tag or release already exist -------------------------------

if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
    die "tag $TAG_NAME already exists locally. Delete with 'git tag -d $TAG_NAME' (and 'git push origin :refs/tags/$TAG_NAME' if pushed) before re-cutting."
fi
if gh release view "$TAG_NAME" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    die "GitHub release $TAG_NAME already exists on $REPO_SLUG. Bump again."
fi

# ----- Handle ambient uncommitted changes -----------------------------------

if [ -n "$(git status --porcelain)" ]; then
    printf '\n'
    warn "uncommitted changes in working tree:"
    git status --short
    printf '\n'
    if ask_yn "Stage and commit them as 'chore: prepare release ${NEW_VERSION}'?" default-n; then
        git add -A
        git commit -m "chore: prepare release ${NEW_VERSION}"
    else
        die "commit or stash changes manually, then re-run"
    fi
fi

# ----- Bump CHANGELOG (Conventional Commits → git-cliff → claude polish) -----
#
# polish-notes.sh builds a deterministic draft from the commits since the last
# tag (git-cliff, see cliff.toml) and has `claude -p` rewrite it into polished,
# user-facing notes — falling back to the raw draft if claude is unavailable.
# The reviewed section is prepended, leaving older sections untouched. Preview
# pending notes any time with `git cliff --unreleased`.

CHANGELOG="$REPO_ROOT/CHANGELOG.md"

if ! command -v git-cliff >/dev/null 2>&1; then
    die "git-cliff not found. Install with 'brew install git-cliff' (config in cliff.toml)."
fi

if grep -q "^## \[${NEW_VERSION}\]" "$CHANGELOG" 2>/dev/null; then
    log "CHANGELOG already has a [${NEW_VERSION}] section; leaving it as-is"
else
    log "drafting CHANGELOG for ${NEW_VERSION} from commits since v${CURRENT_VERSION}"
    NOTES_TMP="$(mktemp)"
    trap 'rm -f "$NOTES_TMP"' EXIT
    "$REPO_ROOT/Scripts/release/polish-notes.sh" "$TAG_NAME" > "$NOTES_TMP"

    printf '\n%s\n\n' "${DIM}----- proposed ${NEW_VERSION} notes -----${NC}"
    cat "$NOTES_TMP"
    printf '\n%s\n' "${DIM}----------------------------------------${NC}"

    if [ -z "$(tr -d '[:space:]' < "$NOTES_TMP")" ]; then
        warn "no user-facing commits since v${CURRENT_VERSION}; CHANGELOG unchanged"
    else
        # Review loop: read the AI-polished notes, optionally open the editor,
        # re-read after editing, and only commit/tag once explicitly accepted.
        # Nothing below this point is reversible without deleting the tag.
        while true; do
            printf '\n'
            printf '%sReview %s release notes:%s\n' "$BOLD" "$NEW_VERSION" "$NC"
            printf '  %s1)%s Accept and commit\n' "$CYAN" "$NC"
            printf '  %s2)%s Edit in %s\n'        "$CYAN" "$NC" "${EDITOR:-vi}"
            printf '  %s3)%s Re-show notes\n'     "$CYAN" "$NC"
            printf '  %s4)%s Abort release\n'     "$CYAN" "$NC"
            printf 'Choice [1-4]: '
            IFS= read -r notes_choice
            case "$notes_choice" in
                1) break ;;
                2)
                    "${EDITOR:-vi}" "$NOTES_TMP"
                    printf '\n%s\n\n' "${DIM}----- updated ${NEW_VERSION} notes -----${NC}"
                    cat "$NOTES_TMP"
                    printf '%s\n' "${DIM}----------------------------------------${NC}"
                    [ -z "$(tr -d '[:space:]' < "$NOTES_TMP")" ] && warn "notes are now empty"
                    ;;
                3)
                    printf '\n%s\n\n' "${DIM}----- proposed ${NEW_VERSION} notes -----${NC}"
                    cat "$NOTES_TMP"
                    printf '%s\n' "${DIM}----------------------------------------${NC}"
                    ;;
                4) die "release cancelled" ;;
                *) warn "enter 1, 2, 3, or 4" ;;
            esac
        done

        if [ -z "$(tr -d '[:space:]' < "$NOTES_TMP")" ]; then
            die "release notes are empty; aborting before commit"
        fi

        # Insert the reviewed section just above the first existing release
        # heading, so it lands right under the file header.
        awk -v notesfile="$NOTES_TMP" '
            /^## \[/ && !done {
                while ((getline line < notesfile) > 0) print line
                print ""
                done = 1
            }
            { print }
        ' "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"

        git add CHANGELOG.md
        git commit -m "docs: update CHANGELOG for ${NEW_VERSION}"
    fi
fi

# ----- Tag ------------------------------------------------------------------

log "tagging ${TAG_NAME}"
git tag -a "$TAG_NAME" -m "Release ${NEW_VERSION}"

# ----- Run the publish pipeline ---------------------------------------------

printf '\n'
log "running Scripts/publish.sh (this builds, signs, notarizes, and uploads)..."
printf '\n'

if ! "$REPO_ROOT/Scripts/publish.sh"; then
    err "publish.sh failed."
    err "The tag ${TAG_NAME} was created locally. publish.sh pushes it only right before creating the GitHub release."
    err "After fixing the cause, you can either:"
    err "  - re-run Scripts/publish.sh (tag is already in place), or"
    err "  - delete the tag (git tag -d ${TAG_NAME}) and re-run this script."
    exit 1
fi

# ----- Push -----------------------------------------------------------------

printf '\n'
ok "publish complete."
printf '\n'

if ask_yn "Push '${CURRENT_BRANCH}' and '${TAG_NAME}' to origin?" default-y; then
    git push origin "$CURRENT_BRANCH"
    # publish.sh pushes the tag before creating the GitHub release, so by
    # the time we get here it's usually already on the remote. Only push if
    # it's missing, to avoid a misleading "tag already exists" error.
    if git ls-remote --tags --exit-code origin "refs/tags/$TAG_NAME" >/dev/null 2>&1; then
        log "tag ${TAG_NAME} already on remote (pushed by publish.sh); skipping."
    else
        git push origin "$TAG_NAME"
    fi
    ok "pushed ${CURRENT_BRANCH} (and ${TAG_NAME} if it wasn't already there)"
else
    log "skipped push. Run when ready:"
    printf '    git push origin %s %s\n' "$CURRENT_BRANCH" "$TAG_NAME"
fi

printf '\n'
ok "Gargantua ${NEW_VERSION} released."
printf '   Release: https://github.com/%s/releases/tag/%s\n' "$REPO_SLUG" "$TAG_NAME"
printf '   Smoke:   brew update && brew upgrade --cask gargantua\n'
