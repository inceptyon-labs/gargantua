#!/usr/bin/env bash
# sign.sh - strip and codesign the app bundle inside-out.
#
# Signing order (mandatory; Apple rejects "signed app wrapping unsigned
# helper" at notarization time):
#
#   0. Strip shipped Mach-O executables before anything is signed.
#   1. Privileged helper executable in Contents/Library/LaunchServices/.
#   2. Every Mach-O executable file in Contents/Resources/ (e.g. bin/fclones).
#   3. Non-main code assets in Contents/MacOS (e.g. mlx.metallib).
#   4. Every valid nested *.bundle, deepest first. SwiftPM resource bundles are
#      plain directories sealed by the top-level app signature, not signable
#      code bundles.
#   5. The top-level Gargantua.app, with entitlements and hardened runtime.
#
# After signing, asserts the Authority line starts with
# "Developer ID Application" and that `codesign --verify --deep --strict`
# returns clean. These are the two checks Gatekeeper will run on a fresh
# machine; failing here locally is cheaper than finding out at notarize time.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_env.sh
. "$_SCRIPT_DIR/_env.sh"

[ -n "${SIGNING_IDENTITY:-}" ] || die "SIGNING_IDENTITY not set; see .env.release.example"

ENTITLEMENTS="$APPSHELL_DIR/Gargantua.entitlements"
[ -f "$ENTITLEMENTS" ] || die "missing entitlements at $ENTITLEMENTS"

if [ "${DRY_RUN:-0}" != "1" ] && [ ! -d "$APP_BUNDLE" ]; then
    die "no app to sign at $APP_BUNDLE (did assemble-app.sh run?)"
fi

# Verify identity is present in the keychain (skipped under dry-run so the
# smoke flow works on a machine without a real Developer ID cert).
if [ "${DRY_RUN:-0}" != "1" ]; then
    # security find-identity prints each identity wrapped in double-quotes;
    # anchor the match on the quotes to avoid accepting a substring of a
    # different identity.
    if ! security find-identity -v -p codesigning | grep -qF "\"$SIGNING_IDENTITY\"" \
        && ! security find-identity -v -p codesigning | grep -qF "$SIGNING_IDENTITY"; then
        die "signing identity not found in keychain: $SIGNING_IDENTITY

Run: security find-identity -v -p codesigning
to see the available identities, and set SIGNING_IDENTITY to either the
SHA-1 hash or exact 'Developer ID Application: ...' string."
    fi
fi

_sign() {
    run codesign \
        --force \
        --timestamp \
        --options runtime \
        "$@"
}

_is_macho() {
    file -b "$1" 2>/dev/null | grep -q 'Mach-O'
}

"$RELEASE_SCRIPTS_DIR/strip-binaries.sh"

# ----- Phase 1: privileged helper daemon ------------------------------------
log "Phase 1/5: signing privileged helper daemon..."
HELPER_EXECUTABLE="$APP_BUNDLE/Contents/Library/LaunchServices/$HELPER_BUNDLE_ID"
if [ "${DRY_RUN:-0}" != "1" ] && [ ! -x "$HELPER_EXECUTABLE" ]; then
    die "missing privileged helper executable at $HELPER_EXECUTABLE"
fi
if [ -e "$HELPER_EXECUTABLE" ] || [ "${DRY_RUN:-0}" = "1" ]; then
    _sign --sign "$SIGNING_IDENTITY" --identifier "$HELPER_BUNDLE_ID" "$HELPER_EXECUTABLE"
fi

# ----- Phase 2: embedded helper binaries ------------------------------------
log "Phase 2/5: signing embedded helper binaries..."
phase1_count=0
while IFS= read -r -d '' BIN; do
    [ -f "$BIN" ] || continue
    [ -x "$BIN" ] || continue
    _is_macho "$BIN" || continue
    log "  $BIN"
    _sign --sign "$SIGNING_IDENTITY" "$BIN"
    phase1_count=$((phase1_count + 1))
done < <(find "$APP_BUNDLE/Contents/Resources" -type f -print0 2>/dev/null || true)
log "  signed $phase1_count helper binaries"

# ----- Phase 3: non-main code assets in Contents/MacOS ----------------------
log "Phase 3/5: signing non-main code assets..."
phase2_count=0
while IFS= read -r -d '' CODE_ASSET; do
    [ -f "$CODE_ASSET" ] || continue
    [ "$(basename "$CODE_ASSET")" != "$APP_NAME" ] || continue
    case "$CODE_ASSET" in
        *.metallib) ;;
        *) _is_macho "$CODE_ASSET" || continue ;;
    esac
    log "  $CODE_ASSET"
    _sign --sign "$SIGNING_IDENTITY" "$CODE_ASSET"
    phase2_count=$((phase2_count + 1))
done < <(find "$APP_BUNDLE/Contents/MacOS" -type f -print0 2>/dev/null || true)
log "  signed $phase2_count code assets"

# ----- Phase 4: nested bundles (deepest-first via -depth) -------------------
log "Phase 4/5: signing nested bundles (deepest first)..."
phase3_count=0
while IFS= read -r -d '' BUNDLE; do
    if [ ! -f "$BUNDLE/Contents/Info.plist" ] && [ ! -f "$BUNDLE/Info.plist" ]; then
        log "  skipping plain resource bundle: $BUNDLE"
        continue
    fi
    log "  $BUNDLE"
    _sign --sign "$SIGNING_IDENTITY" "$BUNDLE"
    phase3_count=$((phase3_count + 1))
done < <(find "$APP_BUNDLE/Contents" -depth -type d -name '*.bundle' -print0 2>/dev/null || true)
log "  signed $phase3_count nested bundles"

# ----- Phase 5: top-level .app with entitlements ----------------------------
log "Phase 5/5: signing $APP_BUNDLE with entitlements..."
_sign \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE"

# ----- Post-sign assertions -------------------------------------------------
if [ "${DRY_RUN:-0}" != "1" ]; then
    CODESIGN_DETAILS="$(codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1)"
    AUTHORITY="$(printf '%s\n' "$CODESIGN_DETAILS" \
        | sed -n 's/^Authority=//p' \
        | head -1)"

    case "$AUTHORITY" in
        "Developer ID Application:"*)
            log "Signed with: $AUTHORITY"
            ;;
        "")
            die "codesign produced no Authority line; app is not signed"
            ;;
        *)
            die "unexpected signing authority: '$AUTHORITY' (expected 'Developer ID Application: ...')"
            ;;
    esac

    log "Verifying signature chain..."
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" \
        || die "codesign --verify failed; see output above"
fi

log "Signing complete."
