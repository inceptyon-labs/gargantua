#!/usr/bin/env bash
# Verify a signed installed Gargantua.app uses its embedded helper binaries.
#
# Usage:
#   Scripts/smoke/verify-vendored-bins.sh
#   Scripts/smoke/verify-vendored-bins.sh /Applications/Gargantua.app
set -euo pipefail

APP_BUNDLE_INPUT="${1:-/Applications/Gargantua.app}"

die() {
    echo "error: $*" >&2
    exit 1
}

APP_PARENT="$(cd "$(dirname "$APP_BUNDLE_INPUT")" 2>/dev/null && pwd -P)" \
    || die "app bundle parent does not exist: $(dirname "$APP_BUNDLE_INPUT")"
APP_BUNDLE="$APP_PARENT/$(basename "$APP_BUNDLE_INPUT")"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/Gargantua"
CORE_BUNDLE="$APP_BUNDLE/Contents/Resources/Gargantua_GargantuaCore.bundle"

team_identifier() {
    (codesign -dv --verbose=4 "$1" 2>&1 || true) | awk -F= '/^TeamIdentifier=/ { print $2; exit }'
}

authority() {
    (codesign -dv --verbose=2 "$1" 2>&1 || true) | awk -F= '/^Authority=/ { print $2; exit }'
}

assert_executable() {
    local path="$1"
    [ -f "$path" ] || die "missing executable: $path"
    [ -x "$path" ] || die "not executable: $path"
}

assert_developer_id_signed_with_team() {
    local path="$1"
    local expected_team="$2"
    local actual_authority
    local actual_team

    actual_authority="$(authority "$path")"
    case "$actual_authority" in
        "Developer ID Application:"*) ;;
        *) die "$path is not signed by Developer ID Application (authority: ${actual_authority:-none})" ;;
    esac

    actual_team="$(team_identifier "$path")"
    [ -n "$actual_team" ] || die "$path has no TeamIdentifier"
    [ "$actual_team" = "$expected_team" ] \
        || die "$path TeamIdentifier is $actual_team, expected $expected_team"
}

assert_resolved_inside_app() {
    local label="$1"
    local expected_path="$2"
    local output="$3"
    local resolved

    resolved="$(printf '%s\n' "$output" | awk -F': ' -v label="$label" '$1 == label { print $2; exit }')"
    [ -n "$resolved" ] || die "selfcheck output did not include $label"

    case "$resolved" in
        "$APP_BUNDLE"/*) ;;
        *) die "$label resolved outside the app bundle: $resolved" ;;
    esac

    [ "$resolved" = "$expected_path" ] \
        || die "$label resolved to $resolved, expected $expected_path"
}

assert_executable "$APP_EXECUTABLE"
[ -d "$CORE_BUNDLE" ] || die "missing GargantuaCore resource bundle: $CORE_BUNDLE"

APP_TEAM="$(team_identifier "$APP_BUNDLE")"
[ -n "$APP_TEAM" ] || die "$APP_BUNDLE has no TeamIdentifier; sign the app first"

FCLONES="$CORE_BUNDLE/bin/fclones"
CZKAWKA="$CORE_BUNDLE/bin/czkawka_cli"

assert_executable "$FCLONES"
assert_executable "$CZKAWKA"
assert_developer_id_signed_with_team "$FCLONES" "$APP_TEAM"
assert_developer_id_signed_with_team "$CZKAWKA" "$APP_TEAM"

SELFCHECK_OUTPUT="$(
    env \
        -u GARGANTUA_FCLONES_BIN \
        -u GARGANTUA_CZKAWKA_BIN \
        PATH=/usr/bin:/bin \
        "$APP_EXECUTABLE" --selfcheck-binaries
)"

assert_resolved_inside_app "fclones" "$FCLONES" "$SELFCHECK_OUTPUT"
assert_resolved_inside_app "czkawka_cli" "$CZKAWKA" "$SELFCHECK_OUTPUT"

echo "Vendored helper smoke passed for $APP_BUNDLE"
