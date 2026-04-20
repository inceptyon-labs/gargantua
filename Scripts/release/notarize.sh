#!/usr/bin/env bash
# notarize.sh <target> — submit a target to Apple's notary service and staple.
#
# Target is either Gargantua.app or Gargantua-<version>.dmg. notarytool
# accepts both; only zipping differs:
#
#   .app → ditto-zip → submit the zip → staple the .app.
#   .dmg → submit the DMG directly → staple the DMG.
#
# Stapling a container requires a prior notarization submission for THAT
# container. So a properly distributable pipeline notarizes both the .app
# and the DMG — the .app so it remains offline-verifiable once extracted to
# /Applications, the DMG so the downloaded artifact itself carries its
# ticket.
#
# Uses `--output-format json` so status / submission-ID parsing isn't
# fragile against whitespace or Apple's log tweaks.
#
# Idempotent at Apple's side: re-submitting the same hash returns the
# previous verdict, so release.sh can be safely re-run after a hiccup.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_env.sh
. "$_SCRIPT_DIR/_env.sh"

TARGET="${1:-$APP_BUNDLE}"

case "$TARGET" in
    *.app) NOTARIZE_KIND="app" ;;
    *.dmg) NOTARIZE_KIND="dmg" ;;
    *) die "unsupported notarize target (expected .app or .dmg): $TARGET" ;;
esac

[ -n "${NOTARY_PROFILE:-}" ] \
    || die "NOTARY_PROFILE not set. Create one with:
  xcrun notarytool store-credentials \"gargantua-notary\" \\
    --apple-id <you@example.com> \\
    --team-id \$TEAM_ID \\
    --password <app-specific-password>"

if [ "${DRY_RUN:-0}" != "1" ]; then
    case "$NOTARIZE_KIND" in
        app) [ -d "$TARGET" ] || die "no app to notarize at $TARGET" ;;
        dmg) [ -f "$TARGET" ] || die "no dmg to notarize at $TARGET" ;;
    esac
fi

command -v xcrun >/dev/null 2>&1 \
    || die "xcrun not found; install Xcode Command Line Tools"

# ----- Prepare submit artifact ----------------------------------------------
SUBMIT_PATH=""
SUBMIT_CLEANUP=""
case "$NOTARIZE_KIND" in
    app)
        SUBMIT_PATH="$DIST_DIR/$(basename "$TARGET" .app)-notarize.zip"
        SUBMIT_CLEANUP="$SUBMIT_PATH"
        log "Zipping $TARGET -> $SUBMIT_PATH (ditto, preserves bundle)..."
        run rm -f "$SUBMIT_PATH"
        run ditto -c -k --keepParent "$TARGET" "$SUBMIT_PATH"
        ;;
    dmg)
        SUBMIT_PATH="$TARGET"
        ;;
esac

SUBMIT_LOG="$DIST_DIR/notarize-$(basename "$TARGET").json"

log "Submitting $(basename "$TARGET") to notarytool (profile: $NOTARY_PROFILE, timeout: 30m)..."
log "This typically takes 2-10 minutes but can be longer under load."

if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY-RUN: xcrun notarytool submit \"$SUBMIT_PATH\" --keychain-profile \"$NOTARY_PROFILE\" --wait --timeout 30m --output-format json"
else
    if ! xcrun notarytool submit "$SUBMIT_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --timeout 30m \
        --output-format json \
        > "$SUBMIT_LOG" 2>&1; then

        # JSON output is strict; grep can extract "id" reliably.
        SUB_ID="$(sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$SUBMIT_LOG" | head -1)"
        warn "notarization failed or timed out."
        if [ -n "$SUB_ID" ]; then
            warn "Submission ID: $SUB_ID"
            warn "Fetch detailed Apple log with:"
            warn "  xcrun notarytool log \"$SUB_ID\" --keychain-profile \"$NOTARY_PROFILE\""
        fi
        warn "Submission output saved at: $SUBMIT_LOG"
        [ -n "$SUBMIT_CLEANUP" ] && warn "Submission artifact retained: $SUBMIT_CLEANUP"
        die "notarization did not succeed"
    fi

    # Status in JSON: "status": "Accepted" | "Invalid" | "Rejected".
    if ! grep -qE '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$SUBMIT_LOG"; then
        STATUS="$(sed -nE 's/.*"status"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$SUBMIT_LOG" | head -1)"
        warn "notarytool returned success but verdict was: ${STATUS:-unknown}"
        warn "See $SUBMIT_LOG for details."
        die "notarization completed but verdict was not Accepted"
    fi
fi

log "Stapling ticket to $TARGET..."
run xcrun stapler staple "$TARGET"

if [ "${DRY_RUN:-0}" != "1" ]; then
    xcrun stapler validate "$TARGET" \
        || die "stapler validate failed on $TARGET"
fi

# Clean up the submission zip (only relevant for .app).
if [ -n "$SUBMIT_CLEANUP" ]; then
    run rm -f "$SUBMIT_CLEANUP"
fi

log "Notarization of $(basename "$TARGET") complete."
