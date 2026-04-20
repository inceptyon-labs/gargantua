#!/usr/bin/env bash
# Shared environment + helpers for the release pipeline.
#
# This file is sourced (not executed) by Scripts/release.sh and every
# sub-script under Scripts/release/. It:
#
#   - Resolves VERSION, BUILD, and signing/notarization identities from the
#     environment, a gitignored .env.release, and the current git state.
#   - Exposes a `run` helper that honors DRY_RUN so sub-scripts can be
#     written in a single style and smoke-tested without touching codesign,
#     notarytool, or the filesystem destructively.
#   - Defines paths (REPO_ROOT, DIST_DIR, APP_BUNDLE, …) once so sub-scripts
#     don't drift.
#
# Idempotent: sourcing this file twice is a no-op.

# shellcheck disable=SC2155
if [ -n "${GARGANTUA_RELEASE_ENV_LOADED:-}" ]; then
    return 0
fi
GARGANTUA_RELEASE_ENV_LOADED=1

set -euo pipefail

# ----- Paths ----------------------------------------------------------------

# _env.sh lives at Scripts/release/_env.sh; REPO_ROOT is two levels up.
_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "$_ENV_DIR/../.." && pwd)"
export SCRIPTS_DIR="$REPO_ROOT/Scripts"
export RELEASE_SCRIPTS_DIR="$SCRIPTS_DIR/release"
export APPSHELL_DIR="$REPO_ROOT/AppShell"
export DIST_DIR="$REPO_ROOT/dist"
export APP_NAME="Gargantua"
export APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

# ----- Logging helpers ------------------------------------------------------

# log messages go to stderr so sub-scripts' stdout can be captured cleanly.
log()   { printf '==> %s\n' "$*" >&2; }
warn()  { printf 'warn: %s\n' "$*" >&2; }
die()   { printf 'error: %s\n' "$*" >&2; exit 1; }

# run: execute a command, honoring DRY_RUN. Use for any externally visible
# action (codesign, notarytool, ditto, stapler, cp, rm). Internal plumbing
# (e.g. reading files) should call commands directly.
run() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf 'DRY-RUN: %s\n' "$*" >&2
    else
        "$@"
    fi
}

# ----- Optional .env.release ------------------------------------------------
# .env.release is gitignored; holds TEAM_ID / SIGNING_IDENTITY / NOTARY_PROFILE.
# Real env vars take precedence, so CI can override without touching the file.

if [ -f "$REPO_ROOT/.env.release" ]; then
    # shellcheck disable=SC1091
    set -a
    . "$REPO_ROOT/.env.release"
    set +a
fi

# ----- Version / build resolution -------------------------------------------
# VERSION:
#   - Explicit env VERSION wins (useful for --snapshot, CI dispatches).
#   - Otherwise, `git describe --tags --abbrev=0` on HEAD.
# BUILD: short SHA, always derived from git.

_resolve_version() {
    if [ -n "${VERSION:-}" ]; then
        return 0
    fi

    if git -C "$REPO_ROOT" describe --tags --exact-match HEAD >/dev/null 2>&1; then
        VERSION="$(git -C "$REPO_ROOT" describe --tags --exact-match HEAD)"
        VERSION="${VERSION#v}"
    elif [ "${SNAPSHOT:-0}" = "1" ]; then
        VERSION="0.0.0-${BUILD_SHA}"
    else
        die "HEAD is not on a tag. Use --snapshot for dev builds or git tag vX.Y.Z first."
    fi
    export VERSION
}

_resolve_build() {
    if [ -n "${BUILD:-}" ]; then
        return 0
    fi
    # CFBundleVersion must be dotted-numeric (Apple notary validates).
    # Use commit count since the root; monotonically increasing.
    BUILD="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo "0")"
    export BUILD
}

_resolve_build_sha() {
    # Short SHA for diagnostics / log paths / snapshot VERSION suffixes.
    # NOT used for CFBundleVersion (non-numeric).
    BUILD_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
    export BUILD_SHA
}

_resolve_build_sha
_resolve_version
_resolve_build

# ----- Bundle identity defaults ---------------------------------------------

export BUNDLE_ID="${BUNDLE_ID:-com.gargantua.app}"
export MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-14.0}"

# ----- Flag defaults --------------------------------------------------------
# release.sh parses flags and exports these before sourcing sub-scripts.
export SNAPSHOT="${SNAPSHOT:-0}"
export DRY_RUN="${DRY_RUN:-0}"
export ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
export CI_MODE="${CI_MODE:-0}"

# Under --dry-run, supply placeholder credentials so sub-scripts can exercise
# their code paths without real signing material. Sub-scripts still gate
# actual codesign/notarytool invocations on DRY_RUN, so nothing leaves the
# local machine.
if [ "$DRY_RUN" = "1" ]; then
    export SIGNING_IDENTITY="${SIGNING_IDENTITY:-DRYRUN-PLACEHOLDER-IDENTITY}"
    export NOTARY_PROFILE="${NOTARY_PROFILE:-DRYRUN-PLACEHOLDER-PROFILE}"
fi
