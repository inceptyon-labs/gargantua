#!/usr/bin/env bash
# build.sh — swift build wrapper for the release pipeline.
#
# Builds the Gargantua executable in release configuration for arm64. Intel /
# universal coverage is tracked in gargantua-vzuz; this script stays arm64-
# only until a rustup-managed toolchain or CI runner lands.
#
# Exports SWIFT_BIN_DIR so downstream scripts (assemble-app.sh) can locate
# the built artifacts without re-invoking swift build.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_env.sh
. "$_SCRIPT_DIR/_env.sh"

log "Building $APP_NAME $VERSION ($BUILD) for arm64-apple-macosx..."

run swift build \
    --package-path "$REPO_ROOT" \
    -c release \
    --arch arm64 \
    --product "$APP_NAME"

run swift build \
    --package-path "$REPO_ROOT" \
    -c release \
    --arch arm64 \
    --product "GargantuaPrivilegedHelper"

# --show-bin-path is non-destructive, always safe to run even under --dry-run.
SWIFT_BIN_DIR="$(swift build \
    --package-path "$REPO_ROOT" \
    -c release \
    --arch arm64 \
    --show-bin-path)"
export SWIFT_BIN_DIR

if [ "${DRY_RUN:-0}" != "1" ]; then
    [ -x "$SWIFT_BIN_DIR/$APP_NAME" ] \
        || die "swift build did not produce $SWIFT_BIN_DIR/$APP_NAME"
    [ -x "$SWIFT_BIN_DIR/GargantuaPrivilegedHelper" ] \
        || die "swift build did not produce $SWIFT_BIN_DIR/GargantuaPrivilegedHelper"
    [ -d "$SWIFT_BIN_DIR/Gargantua_GargantuaCore.bundle" ] \
        || die "missing GargantuaCore resource bundle at $SWIFT_BIN_DIR/Gargantua_GargantuaCore.bundle"
fi

log "Built $SWIFT_BIN_DIR/$APP_NAME"
