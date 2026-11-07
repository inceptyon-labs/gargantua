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
# fragile against whitespace or Apple's log tweaks. The upload and the wait
# run as separate notarytool calls, each bounded by a watchdog.
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

# Auth: prefer App Store Connect API key (CI-friendly, no keychain),
# fall back to a stored notarytool keychain profile.
NOTARY_AUTH_FLAGS=()
NOTARY_AUTH_DESC=""
if [ -n "${NOTARY_API_KEY_PATH:-}" ]; then
    [ -n "${NOTARY_API_KEY_ID:-}" ] \
        || die "NOTARY_API_KEY_ID required when NOTARY_API_KEY_PATH is set"
    [ -n "${NOTARY_API_ISSUER_ID:-}" ] \
        || die "NOTARY_API_ISSUER_ID required when NOTARY_API_KEY_PATH is set"
    [ -f "$NOTARY_API_KEY_PATH" ] || [ "${DRY_RUN:-0}" = "1" ] \
        || die "NOTARY_API_KEY_PATH does not point at a readable file: $NOTARY_API_KEY_PATH"
    NOTARY_AUTH_FLAGS=(
        --key "$NOTARY_API_KEY_PATH"
        --key-id "$NOTARY_API_KEY_ID"
        --issuer "$NOTARY_API_ISSUER_ID"
    )
    NOTARY_AUTH_DESC="API key $NOTARY_API_KEY_ID"
elif [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_AUTH_FLAGS=(--keychain-profile "$NOTARY_PROFILE")
    NOTARY_AUTH_DESC="profile: $NOTARY_PROFILE"
else
    die "Neither NOTARY_API_KEY_PATH nor NOTARY_PROFILE set. Either:
  - export NOTARY_API_KEY_PATH/NOTARY_API_KEY_ID/NOTARY_API_ISSUER_ID (App Store Connect API key), OR
  - run: xcrun notarytool store-credentials \"gargantua-notary\" \\
      --apple-id <you@example.com> --team-id \$TEAM_ID \\
      --password <app-specific-password>"
fi

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

# notarytool's --timeout only bounds the wait after the upload, so the upload
# and the wait run as separate steps, each under its own watchdog. A ~70 MB
# upload normally takes well under a minute.
UPLOAD_LIMIT_SECS=900
WAIT_TIMEOUT="30m"
WAIT_LIMIT_SECS=2100

# with_watchdog <seconds> <cmd...>: run <cmd>, killing it with SIGALRM after
# <seconds>. A process killed this way exits with status 142.
with_watchdog() {
    local seconds="$1"
    shift
    perl -e 'alarm shift @ARGV; exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"' \
        "$seconds" "$@"
}

notary_failed() {
    local sub_id="${1:-}"
    if [ -n "$sub_id" ]; then
        warn "Submission ID: $sub_id"
        warn "Fetch detailed Apple log with:"
        warn "  xcrun notarytool log \"$sub_id\" ${NOTARY_AUTH_FLAGS[*]}"
    fi
    warn "notarytool output saved at: $SUBMIT_LOG"
    [ -n "$SUBMIT_CLEANUP" ] && warn "Submission artifact retained: $SUBMIT_CLEANUP"
    die "${2:-notarization did not succeed}"
}

log "Submitting $(basename "$TARGET") to notarytool ($NOTARY_AUTH_DESC)..."
log "Upload limit $((UPLOAD_LIMIT_SECS / 60))m, processing limit $WAIT_TIMEOUT. Processing typically takes 2-10 minutes."

if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY-RUN: xcrun notarytool submit \"$SUBMIT_PATH\" ${NOTARY_AUTH_FLAGS[*]} --no-wait --output-format json"
    log "DRY-RUN: xcrun notarytool wait <submission-id> ${NOTARY_AUTH_FLAGS[*]} --timeout $WAIT_TIMEOUT --output-format json"
else
    if ! file_lock_free "$SUBMIT_PATH"; then
        lsof "$SUBMIT_PATH" >&2 || true
        die "$SUBMIT_PATH is locked by the process above, and notarytool would wait on it forever. For a disk image, detach it (hdiutil info lists the device) and re-run."
    fi

    NOTARYTOOL="$(xcrun --find notarytool)"

    rc=0
    with_watchdog "$UPLOAD_LIMIT_SECS" "$NOTARYTOOL" submit "$SUBMIT_PATH" \
        "${NOTARY_AUTH_FLAGS[@]}" \
        --no-wait \
        --output-format json \
        > "$SUBMIT_LOG" 2>&1 || rc=$?

    # JSON output is strict; sed can extract "id" reliably.
    SUB_ID="$(sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$SUBMIT_LOG" | head -1)"
    if [ "$rc" = 142 ]; then
        notary_failed "$SUB_ID" "notarytool upload did not finish within $((UPLOAD_LIMIT_SECS / 60)) minutes. Check the network and re-run; Apple dedupes submissions by hash."
    elif [ "$rc" != 0 ] || [ -z "$SUB_ID" ]; then
        notary_failed "$SUB_ID" "notarytool upload failed"
    fi

    log "Uploaded (submission $SUB_ID). Waiting for Apple to process it..."
    rc=0
    with_watchdog "$WAIT_LIMIT_SECS" "$NOTARYTOOL" wait "$SUB_ID" \
        "${NOTARY_AUTH_FLAGS[@]}" \
        --timeout "$WAIT_TIMEOUT" \
        --output-format json \
        > "$SUBMIT_LOG" 2>&1 || rc=$?
    [ "$rc" = 0 ] || notary_failed "$SUB_ID" "notarization failed or timed out"

    # Status in JSON: "status": "Accepted" | "Invalid" | "Rejected".
    if ! grep -qE '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$SUBMIT_LOG"; then
        STATUS="$(sed -nE 's/.*"status"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$SUBMIT_LOG" | head -1)"
        warn "notarytool finished but the verdict was: ${STATUS:-unknown}"
        notary_failed "$SUB_ID" "notarization completed but verdict was not Accepted"
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
