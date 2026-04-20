#!/usr/bin/env bash
# Scripts/release.sh — canonical entry point for building + shipping Gargantua.
#
# Runs the full pipeline: preflight → build → assemble → sign → notarize → DMG.
# See docs/designs/2026-04-19-macos-release-pipeline.md for the full design.
#
# Usage:
#   git tag v0.1.0
#   ./Scripts/release.sh
#
# Outputs:
#   dist/Gargantua.app                (signed, notarized, stapled)
#   dist/Gargantua-<version>.dmg      (stapled, drag-to-Applications)

set -euo pipefail

usage() {
    cat <<'USAGE'
usage: ./Scripts/release.sh [options]

Build, sign, notarize, and package Gargantua.app into a stapled DMG.

Options:
  --snapshot       Allow untagged HEAD. VERSION becomes 0.0.0-<short-sha>.
                   Still fully signs and notarizes; for pipeline testing.
  --dry-run        Log all commands without executing destructive ones.
                   No codesign, no notarytool, no filesystem writes.
                   Useful for CI smoke tests or debugging the pipeline
                   without a valid Developer ID cert.
  --allow-dirty    Allow a dirty git tree. Default: refuse.
  --ci             Non-interactive mode: no confirmation prompts; removes
                   dist/ unconditionally.
  -h, --help       Show this help.

Environment (set in .env.release — gitignored — or exported in the shell):
  TEAM_ID              Apple Developer team ID (10-char).
  SIGNING_IDENTITY     "Developer ID Application: ... (TEAM_ID)"
  NOTARY_PROFILE       Name of the notarytool keychain profile.
  BUNDLE_ID            Defaults to com.gargantua.app.

Preflight will fail fast on:
  - Missing Xcode CLT tools (codesign, notarytool, stapler, iconutil, …).
  - Dirty git tree (without --allow-dirty or --snapshot).
  - Untagged HEAD (without --snapshot).
  - SIGNING_IDENTITY not set or not in the keychain.
  - NOTARY_PROFILE not set.
USAGE
}

# ----- Parse flags ----------------------------------------------------------

SNAPSHOT=0
DRY_RUN=0
ALLOW_DIRTY=0
CI_MODE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --snapshot)    SNAPSHOT=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        --ci)          CI_MODE=1; ALLOW_DIRTY=1 ;;  # CI implies allow-dirty for worktrees/checkouts
        -h|--help)     usage; exit 0 ;;
        *) printf 'error: unknown flag: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

export SNAPSHOT DRY_RUN ALLOW_DIRTY CI_MODE

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./release/_env.sh
. "$_SCRIPT_DIR/release/_env.sh"

# ----- Preflight ------------------------------------------------------------

log "Preflight checks..."

# Required tools (one aggregated error message if several are missing).
missing_tools=()

_need() {
    command -v "$1" >/dev/null 2>&1 || missing_tools+=("$1${2:+ ($2)}")
}

_need swift "Swift toolchain"
_need codesign "Xcode CLT"
_need xcrun "Xcode CLT"
_need ditto "macOS system tool"
_need iconutil "Xcode CLT"
_need hdiutil "macOS system tool"
_need spctl "macOS system tool"
_need security "macOS system tool"

# stapler is dispatched via xcrun; check separately.
if command -v xcrun >/dev/null 2>&1; then
    xcrun --find stapler >/dev/null 2>&1 \
        || missing_tools+=("stapler (Xcode CLT)")
fi

if [ "${#missing_tools[@]}" -gt 0 ]; then
    for t in "${missing_tools[@]}"; do
        warn "missing: $t"
    done
    die "required tools missing; install Xcode Command Line Tools with 'xcode-select --install'"
fi

# Git cleanliness
if [ "$ALLOW_DIRTY" != "1" ] && [ "$SNAPSHOT" != "1" ]; then
    if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
        die "git working tree is dirty. Commit, stash, or pass --allow-dirty / --snapshot."
    fi
fi

# Signing identity — strict under real runs, advisory under --dry-run.
if [ "$DRY_RUN" != "1" ]; then
    [ -n "${SIGNING_IDENTITY:-}" ] \
        || die "SIGNING_IDENTITY not set. Copy .env.release.example to .env.release and fill in, or export SIGNING_IDENTITY."
    [ -n "${NOTARY_PROFILE:-}" ] \
        || die "NOTARY_PROFILE not set. See .env.release.example for setup."

    # Anchor on the surrounding double-quotes that `security find-identity`
    # prints to avoid accepting a substring of another identity.
    if ! security find-identity -v -p codesigning | grep -qF "\"$SIGNING_IDENTITY\""; then
        die "SIGNING_IDENTITY not found in keychain: $SIGNING_IDENTITY

Available codesigning identities:
$(security find-identity -v -p codesigning | sed 's/^/  /')"
    fi
fi

log "Preflight OK. VERSION=$VERSION  BUILD=$BUILD  BUNDLE_ID=$BUNDLE_ID"
[ "$DRY_RUN"  = "1" ] && log "Mode: DRY-RUN (no destructive commands will execute)"
[ "$SNAPSHOT" = "1" ] && log "Mode: SNAPSHOT (VERSION not from a tag)"
[ "$CI_MODE"  = "1" ] && log "Mode: CI (non-interactive)"

# ----- Wipe dist/ -----------------------------------------------------------
if [ -d "$DIST_DIR" ]; then
    if [ "$CI_MODE" = "1" ] || [ "$DRY_RUN" = "1" ]; then
        run rm -rf "$DIST_DIR"
    else
        printf '==> dist/ already exists. Remove? [y/N] ' >&2
        read -r reply
        case "$reply" in
            y|Y|yes|YES) rm -rf "$DIST_DIR" ;;
            *) die "aborted; resolve dist/ manually or pass --ci" ;;
        esac
    fi
fi
run mkdir -p "$DIST_DIR"

# ----- Pipeline -------------------------------------------------------------
#
# Two notarizations: once for the .app (so the extracted bundle is offline-
# verifiable) and once for the DMG (so the downloaded artifact itself is
# Gatekeeper-clean). Apple's notary caches by hash, so the second submission
# of the same app inside a DMG is typically fast.

"$RELEASE_SCRIPTS_DIR/build.sh"
"$RELEASE_SCRIPTS_DIR/assemble-app.sh"
"$RELEASE_SCRIPTS_DIR/sign.sh"
"$RELEASE_SCRIPTS_DIR/notarize.sh" "$APP_BUNDLE"
"$RELEASE_SCRIPTS_DIR/dmg.sh"
"$RELEASE_SCRIPTS_DIR/notarize.sh" "$DMG_PATH"

# ----- Final Gatekeeper assessment ------------------------------------------
# spctl --type execute validates the app (what users launch).
# spctl --type open validates the DMG (what users download).
if [ "$DRY_RUN" != "1" ]; then
    log "Final Gatekeeper assessment..."
    spctl --assess --type execute --verbose=2 "$APP_BUNDLE" \
        || die "spctl rejected $APP_BUNDLE"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH" \
        || die "spctl rejected $DMG_PATH"
fi

log ""
log "Release complete."
log "  App: $APP_BUNDLE"
log "  DMG: $DMG_PATH"
if [ "$DRY_RUN" = "1" ]; then
    log ""
    log "(dry-run: no actual artifacts were produced.)"
fi
