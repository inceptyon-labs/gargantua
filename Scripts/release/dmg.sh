#!/usr/bin/env bash
# dmg.sh — package the notarized, stapled app into a DMG and staple the DMG.
#
# Prefers `create-dmg` (Homebrew) for a polished drag-to-Applications layout;
# falls back to plain `hdiutil` if not installed.
#
# Run strictly AFTER notarize.sh — the DMG stapling ticket is pulled from
# the already-stapled .app, so if the app isn't stapled, the DMG won't be
# either. We double-check with stapler validate on the DMG.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_env.sh
. "$_SCRIPT_DIR/_env.sh"

if [ "${DRY_RUN:-0}" != "1" ] && [ ! -d "$APP_BUNDLE" ]; then
    die "no app to package at $APP_BUNDLE"
fi

DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

run rm -f "$DMG_PATH"

if command -v create-dmg >/dev/null 2>&1; then
    log "Packaging $DMG_PATH via create-dmg..."
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
        "$APP_BUNDLE"
else
    warn "create-dmg not installed; falling back to hdiutil (functional, not polished)."
    warn "Install with: brew install create-dmg"

    STAGING="$(mktemp -d -t gargantua-dmg-staging-XXXXXX)"
    trap 'rm -rf "$STAGING"' EXIT

    if [ "${DRY_RUN:-0}" != "1" ]; then
        ditto "$APP_BUNDLE" "$STAGING/${APP_NAME}.app"
        ln -s /Applications "$STAGING/Applications"
    else
        log "DRY-RUN: stage $APP_BUNDLE and /Applications symlink under $STAGING"
    fi

    run hdiutil create \
        -volname "$APP_NAME $VERSION" \
        -srcfolder "$STAGING" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
fi

log "Stapling ticket to $DMG_PATH..."
run xcrun stapler staple "$DMG_PATH"

if [ "${DRY_RUN:-0}" != "1" ]; then
    xcrun stapler validate "$DMG_PATH" \
        || die "stapler validate failed on DMG"
fi

# Final Gatekeeper assessment on the .app (the payload users will launch).
if [ "${DRY_RUN:-0}" != "1" ]; then
    log "Running spctl Gatekeeper assessment on $APP_BUNDLE..."
    if ! spctl --assess --type execute --verbose=2 "$APP_BUNDLE"; then
        warn "spctl rejected the app. This usually means notarization didn't"
        warn "complete or the ticket didn't staple. Inspect:"
        warn "  codesign -dv --verbose=4 \"$APP_BUNDLE\""
        warn "  xcrun stapler validate \"$APP_BUNDLE\""
        die "Gatekeeper assessment failed"
    fi
fi

log "DMG ready: $DMG_PATH"
