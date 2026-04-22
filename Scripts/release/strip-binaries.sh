#!/usr/bin/env bash
# strip-binaries.sh - strip shipped Mach-O executables before codesign.
#
# `strip` mutates Mach-O contents and invalidates any existing signature, so
# this must run before the inside-out codesign walk. It covers the top-level
# app executable plus embedded executable helpers copied into Resources.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_env.sh
. "$_SCRIPT_DIR/_env.sh"

if [ "${DRY_RUN:-0}" != "1" ] && [ ! -d "$APP_BUNDLE" ]; then
    die "no app to strip at $APP_BUNDLE (did assemble-app.sh run?)"
fi

command -v file >/dev/null 2>&1 || die "file not found; install macOS system tools"
command -v strip >/dev/null 2>&1 || die "strip not found; install Xcode Command Line Tools"

_is_macho() {
    file -b "$1" 2>/dev/null | grep -q 'Mach-O'
}

log "Stripping Mach-O executables before codesign..."
strip_count=0
while IFS= read -r -d '' BIN; do
    [ -f "$BIN" ] || continue
    [ -x "$BIN" ] || continue
    _is_macho "$BIN" || continue

    log "  $BIN"
    run strip -u -r "$BIN"
    strip_count=$((strip_count + 1))
done < <(find "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Library" "$APP_BUNDLE/Contents/Resources" -type f -print0 2>/dev/null || true)
log "  stripped $strip_count executable binaries"
