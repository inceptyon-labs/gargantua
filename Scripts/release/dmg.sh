#!/usr/bin/env bash
# dmg.sh — build a DMG from the signed + notarized .app.
#
# Responsibilities:
#   - Always stage the .app into a temp directory (create-dmg puts folder
#     *contents* at the DMG root, so passing the .app bundle directly would
#     unpack Contents/MacOS/ etc. at root).
#   - Produce $DMG_PATH from $APP_BUNDLE.
#
# NOT this script's job:
#   - Notarizing the DMG (done by a subsequent `notarize.sh $DMG_PATH` call
#     from release.sh).
#   - Stapling the DMG (same — stapler requires a prior submission for THAT
#     DMG, so stapling must follow notarization).
#
# Prefers `create-dmg` (Homebrew) for the polished drag-to-Applications
# layout; falls back to `hdiutil` if not installed.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_env.sh
. "$_SCRIPT_DIR/_env.sh"

if [ "${DRY_RUN:-0}" != "1" ] && [ ! -d "$APP_BUNDLE" ]; then
    die "no app to package at $APP_BUNDLE"
fi

run rm -f "$DMG_PATH"

STAGING="$(mktemp -d -t gargantua-dmg-staging-XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

# Stage the signed/notarized .app bundle so create-dmg and hdiutil both see a
# DMG root containing Gargantua.app (not Contents/ at root).
if [ "${DRY_RUN:-0}" != "1" ]; then
    ditto "$APP_BUNDLE" "$STAGING/${APP_NAME}.app"
else
    log "DRY-RUN: ditto $APP_BUNDLE -> $STAGING/${APP_NAME}.app"
fi

if command -v create-dmg >/dev/null 2>&1; then
    log "Packaging $DMG_PATH via create-dmg..."
    # create-dmg adds its own /Applications symlink via --app-drop-link, so
    # we do NOT pre-stage one here.
    run create-dmg \
        --volname "$APP_NAME $VERSION" \
        --window-pos 200 120 \
        --window-size 540 380 \
        --icon-size 96 \
        --icon "${APP_NAME}.app" 140 180 \
        --app-drop-link 400 180 \
        --hide-extension "${APP_NAME}.app" \
        --no-internet-enable \
        "$DMG_PATH" \
        "$STAGING"
else
    warn "create-dmg not installed; falling back to hdiutil (functional, not polished)."
    warn "Install with: brew install create-dmg"

    # hdiutil doesn't offer an --app-drop-link; stage /Applications manually.
    if [ "${DRY_RUN:-0}" != "1" ]; then
        ln -s /Applications "$STAGING/Applications"
    else
        log "DRY-RUN: ln -s /Applications $STAGING/Applications"
    fi

    run hdiutil create \
        -volname "$APP_NAME $VERSION" \
        -srcfolder "$STAGING" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
fi

if [ "${DRY_RUN:-0}" != "1" ]; then
    [ -n "${SIGNING_IDENTITY:-}" ] || die "SIGNING_IDENTITY not set; cannot sign DMG"
    log "Signing DMG..."
    run codesign \
        --force \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$DMG_PATH"
fi

log "DMG built: $DMG_PATH"
