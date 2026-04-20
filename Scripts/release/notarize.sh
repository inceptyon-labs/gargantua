#!/usr/bin/env bash
# notarize.sh — submit the signed app to Apple's notary service and staple.
#
# Flow:
#   1. ditto-zip the .app (preserving the bundle structure).
#   2. xcrun notarytool submit --wait: blocks until Apple's service returns a
#      verdict (usually 2-10 min; can be 30+).
#   3. On "Accepted", xcrun stapler staple the ticket into the .app.
#   4. xcrun stapler validate as a local confidence check.
#
# On failure, keeps the submission zip in dist/ for re-submission, prints
# the submission ID, and tells the user how to fetch the full Apple log.
#
# Notarization is idempotent on Apple's side: re-submitting the same hash
# returns the previous verdict, so `release.sh` can be safely re-run after a
# network hiccup.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_env.sh
. "$_SCRIPT_DIR/_env.sh"

[ -n "${NOTARY_PROFILE:-}" ] \
    || die "NOTARY_PROFILE not set. Create one with:
  xcrun notarytool store-credentials \"gargantua-notary\" \\
    --apple-id <you@example.com> \\
    --team-id \$TEAM_ID \\
    --password <app-specific-password>"

if [ "${DRY_RUN:-0}" != "1" ] && [ ! -d "$APP_BUNDLE" ]; then
    die "no app to notarize at $APP_BUNDLE"
fi

command -v xcrun >/dev/null 2>&1 \
    || die "xcrun not found; install Xcode Command Line Tools"

ZIP="$DIST_DIR/${APP_NAME}-notarize.zip"
SUBMIT_LOG="$DIST_DIR/notarize-submit.log"

log "Zipping $APP_BUNDLE -> $ZIP (ditto, preserves bundle)..."
run rm -f "$ZIP"
run ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"

log "Submitting to notarytool (profile: $NOTARY_PROFILE, timeout: 30m)..."
log "This typically takes 2-10 minutes but can be longer under load."

if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY-RUN: xcrun notarytool submit \"$ZIP\" --keychain-profile \"$NOTARY_PROFILE\" --wait --timeout 30m"
else
    # `pipefail` (set in _env.sh) means `if !` correctly captures
    # notarytool's exit status across the tee.
    if ! xcrun notarytool submit "$ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --timeout 30m \
        2>&1 | tee "$SUBMIT_LOG"; then

        SUB_ID="$(awk '/^  id: / { print $2; exit }' "$SUBMIT_LOG" || true)"
        warn "notarization failed or timed out."
        if [ -n "$SUB_ID" ]; then
            warn "Submission ID: $SUB_ID"
            warn "Fetch detailed Apple log with:"
            warn "  xcrun notarytool log \"$SUB_ID\" --keychain-profile \"$NOTARY_PROFILE\""
        fi
        die "notarization did not succeed; $ZIP retained for re-submission"
    fi

    # notarytool can exit 0 with a non-"Accepted" status in some edge cases
    # (e.g. Invalid with submission-level errors). Double-check.
    if ! grep -qE '^[[:space:]]*status:[[:space:]]*Accepted' "$SUBMIT_LOG"; then
        warn "notarytool returned success but no 'status: Accepted' in output."
        warn "Check $SUBMIT_LOG for details."
        die "notarization completed but verdict was not Accepted"
    fi
fi

log "Stapling ticket to $APP_BUNDLE..."
run xcrun stapler staple "$APP_BUNDLE"

if [ "${DRY_RUN:-0}" != "1" ]; then
    xcrun stapler validate "$APP_BUNDLE" \
        || die "stapler validate failed; the ticket did not attach"
fi

# Only remove the submission zip on success — on die(), we already exited.
run rm -f "$ZIP"

log "Notarization complete."
