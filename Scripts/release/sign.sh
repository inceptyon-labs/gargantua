#!/usr/bin/env bash
# sign.sh — codesign the app bundle inside-out.
#
# Signing order (mandatory; Apple rejects "signed app wrapping unsigned
# helper" at notarization time):
#
#   1. Every executable file in Contents/Resources/ (e.g. bin/fclones).
#   2. Every nested *.bundle, deepest first (the GargantuaCore resource
#      bundle today, plus anything future code adds).
#   3. The top-level Gargantua.app, with entitlements and hardened runtime.
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
    if ! security find-identity -v -p codesigning | grep -qF "$SIGNING_IDENTITY"; then
        die "signing identity not found in keychain: $SIGNING_IDENTITY

Run: security find-identity -v -p codesigning
to see the available identities, and set SIGNING_IDENTITY to the exact
'Developer ID Application: ...' string."
    fi
fi

_sign() {
    run codesign \
        --force \
        --timestamp \
        --options runtime \
        "$@"
}

# ----- Phase 1: embedded helper binaries ------------------------------------
log "Phase 1/3: signing embedded helper binaries..."
phase1_count=0
while IFS= read -r -d '' BIN; do
    # Directories and non-executable files get skipped. Using -x catches
    # Mach-O binaries regardless of filename.
    [ -f "$BIN" ] || continue
    [ -x "$BIN" ] || continue
    log "  $BIN"
    _sign --sign "$SIGNING_IDENTITY" "$BIN"
    phase1_count=$((phase1_count + 1))
done < <(find "$APP_BUNDLE/Contents/Resources" -type f -print0 2>/dev/null || true)
log "  signed $phase1_count helper binaries"

# ----- Phase 2: nested bundles (deepest-first via -depth) -------------------
log "Phase 2/3: signing nested bundles (deepest first)..."
phase2_count=0
while IFS= read -r -d '' BUNDLE; do
    log "  $BUNDLE"
    _sign --sign "$SIGNING_IDENTITY" "$BUNDLE"
    phase2_count=$((phase2_count + 1))
done < <(find "$APP_BUNDLE/Contents" -depth -type d -name '*.bundle' -print0 2>/dev/null || true)
log "  signed $phase2_count nested bundles"

# ----- Phase 3: top-level .app with entitlements ----------------------------
log "Phase 3/3: signing $APP_BUNDLE with entitlements..."
_sign \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE"

# ----- Post-sign assertions -------------------------------------------------
if [ "${DRY_RUN:-0}" != "1" ]; then
    AUTHORITY="$(codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1 \
        | awk -F'=' '/^Authority=/ { print $2; exit }')"

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
