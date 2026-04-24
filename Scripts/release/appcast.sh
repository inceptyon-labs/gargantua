#!/usr/bin/env bash
# appcast.sh — stage the release DMG and ask Sparkle to generate/sign appcast XML.
#
# The generated folder is ready to upload to the HTTPS directory that hosts
# SPARKLE_FEED_URL. Sparkle's generate_appcast reads SUFeedURL/SUPublicEDKey
# from the built app inside the DMG and signs archives, appcast XML, and
# markdown release notes using the EdDSA private key in Keychain.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_env.sh
. "$_SCRIPT_DIR/_env.sh"

UPDATES_DIR="${SPARKLE_UPDATES_DIR:-$DIST_DIR/sparkle-updates}"
APPCAST_NAME="$(basename "$SPARKLE_FEED_URL")"
RELEASE_NOTES_MARKDOWN_PATH="$UPDATES_DIR/$(basename "$DMG_PATH").md"
RELEASE_NOTES_HTML_PATH="$UPDATES_DIR/$(basename "$DMG_PATH").html"

_find_generate_appcast() {
    local candidate
    for candidate in \
        "$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
        "$REPO_ROOT/.build/artifacts/sparkle/bin/generate_appcast"
    do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    find "$REPO_ROOT/.build/artifacts" -path '*/bin/generate_appcast' -perm -111 -print 2>/dev/null | head -1
}

GENERATE_APPCAST="$(_find_generate_appcast)"
[ -n "$GENERATE_APPCAST" ] \
    || die "Sparkle generate_appcast not found. Run 'swift package resolve' so SPM fetches Sparkle artifacts."

if [ "${DRY_RUN:-0}" != "1" ] && [ ! -f "$DMG_PATH" ]; then
    die "no DMG to publish at $DMG_PATH"
fi

log "Staging Sparkle appcast inputs in $UPDATES_DIR..."
run mkdir -p "$UPDATES_DIR"
run cp "$DMG_PATH" "$UPDATES_DIR/"

if [ "${DRY_RUN:-0}" != "1" ]; then
    if [ -f "$REPO_ROOT/CHANGELOG.md" ]; then
        {
            printf '# Gargantua %s\n\n' "$VERSION"
            awk -v version="$VERSION" '
                BEGIN { capture = 0 }
                /^##[[:space:]]+/ {
                    if (capture == 1) exit
                    if ($0 ~ version) capture = 1
                }
                capture == 1 { print }
            ' "$REPO_ROOT/CHANGELOG.md"
        } > "$RELEASE_NOTES_MARKDOWN_PATH"
    else
        printf '# Gargantua %s\n\nSee the project changelog for release notes.\n' "$VERSION" > "$RELEASE_NOTES_MARKDOWN_PATH"
    fi

    if command -v cmark >/dev/null 2>&1; then
        cmark "$RELEASE_NOTES_MARKDOWN_PATH" > "$RELEASE_NOTES_HTML_PATH"
    elif command -v pandoc >/dev/null 2>&1; then
        pandoc "$RELEASE_NOTES_MARKDOWN_PATH" -f markdown -t html -o "$RELEASE_NOTES_HTML_PATH"
    else
        warn "cmark/pandoc not found; Sparkle 2.9 will render markdown release notes directly."
    fi
else
    log "DRY-RUN: write release notes to $RELEASE_NOTES_MARKDOWN_PATH"
    log "DRY-RUN: render markdown release notes to $RELEASE_NOTES_HTML_PATH when cmark/pandoc is available"
fi

log "Generating signed appcast ($APPCAST_NAME)..."
run "$GENERATE_APPCAST" "$UPDATES_DIR"

if [ "${DRY_RUN:-0}" != "1" ]; then
    [ -f "$UPDATES_DIR/$APPCAST_NAME" ] \
        || die "generate_appcast did not produce $UPDATES_DIR/$APPCAST_NAME"
fi

log "Sparkle appcast ready: $UPDATES_DIR/$APPCAST_NAME"
