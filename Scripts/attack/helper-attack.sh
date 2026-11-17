#!/usr/bin/env bash
# Attack the installed Gargantua privileged helper and MCP server with the bug
# classes they were fixed for, and fail if any guard has regressed.
#
# Every attack targets a file this script creates and owns, so a regressed
# guard can at worst move one of its own test files into your Trash. No sudo.
#
# Usage:
#   Scripts/attack/helper-attack.sh            # attacks /Applications/Gargantua.app
#   GARGANTUA_APP=dist/Gargantua.app Scripts/attack/helper-attack.sh
#
# The helper under test is whichever one launchd has registered, so install the
# build you want to test (and let it update the helper) before running this.
#
# Needs: Xcode command-line tools (swiftc, codesign) and a "Developer ID
# Application" identity for team 3T877KDT79 in the login keychain, because the
# helper only accepts clients signed by that team as com.inceptyon.gargantua.
# Override the identity with PROBE_SIGN_IDENTITY.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
APP="${GARGANTUA_APP:-/Applications/Gargantua.app}"
TEAM_ID="3T877KDT79"
APP_ID="com.inceptyon.gargantua"
HELPER_ID="com.inceptyon.gargantua.privileged-helper"

PASS=0
FAIL=0
TRASHED=()
MCP_PID=""

die() { echo "error: $*" >&2; exit 2; }
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
section() { printf '\n== %s\n' "$1"; }

# ---------------------------------------------------------------- setup

command -v swiftc >/dev/null || die "swiftc not found (install Xcode command-line tools)"
[ -d "$APP" ] || die "app not found at $APP"

IDENTITY="${PROBE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F'"' -v team="($TEAM_ID)" 'index($2, "Developer ID Application") && index($2, team) { print $2; exit }')}"
[ -n "$IDENTITY" ] || die "no Developer ID Application identity for team $TEAM_ID in the keychain"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gtua-attack-work.XXXXXX")"
# Canaries live outside every helper allowlist; attack entries live in /private/tmp, which is allowlisted.
SAFE="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/gtua-canary.XXXXXX")" && pwd -P)"
RUN="$(cd "$(mktemp -d /private/tmp/gtua-attack.XXXXXX)" && pwd -P)"
USERDIR="$(cd "$(mktemp -d "$HOME/Library/Caches/gtua-attack.XXXXXX")" && pwd -P)"
case "$SAFE" in
    /private/var/folders/*) ;;
    *) die "canary dir $SAFE is not under /private/var/folders; refusing to run" ;;
esac

cleanup() {
    [ -n "$MCP_PID" ] && kill "$MCP_PID" 2>/dev/null
    local path
    for path in "${TRASHED[@]+"${TRASHED[@]}"}"; do
        case "$path" in "$HOME/.Trash/"*) rm -rf "$path" ;; esac
    done
    rm -rf "$RUN" "$SAFE" "$USERDIR" "$WORK"
}
trap cleanup EXIT

echo "Building and signing the probe..."
swiftc -O "$HERE/HelperProbe.swift" -o "$WORK/probe" 2>"$WORK/swiftc.log" \
    || { cat "$WORK/swiftc.log" >&2; die "probe build failed"; }
GOOD="$WORK/probe-good"      # signed exactly like the app: should be accepted
ADHOC="$WORK/probe-adhoc"    # ad-hoc signature, right identifier
WRONGID="$WORK/probe-wrongid" # your Developer ID, wrong identifier
cp "$WORK/probe" "$GOOD"; cp "$WORK/probe" "$ADHOC"; cp "$WORK/probe" "$WRONGID"
codesign -f -s "$IDENTITY" -i "$APP_ID" "$GOOD" 2>/dev/null || die "codesign failed for $IDENTITY"
codesign -f -s - -i "$APP_ID" "$ADHOC" 2>/dev/null || die "ad-hoc codesign failed"
codesign -f -s "$IDENTITY" -i "$APP_ID.attack-probe" "$WRONGID" 2>/dev/null || die "codesign failed"

# ---------------------------------------------------------------- helpers

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# trash_req PATH OPERATION [INVOKING_UID]
trash_req() {
    printf '{"planID":"%s","items":[{"id":"%s","path":"%s","category":"attack","size":0,"operation":"%s"}],"invokingUserID":%s,"createdAt":"%s"}' \
        "$(uuidgen)" "$(uuidgen)" "$1" "$2" "${3:-null}" "$(now)"
}

# bg_req OPERATION LABEL PLIST_PATH
bg_req() {
    printf '{"id":"%s","operation":"%s","label":"%s","plistPath":"%s","createdAt":"%s"}' \
        "$(uuidgen)" "$1" "$2" "$3" "$(now)"
}

jget() { plutil -extract "$2" raw -o - - <<<"$1" 2>/dev/null; }

# Normalizes a reply into OK / ERR / TP for both reply shapes (per-item and background).
parse_reply() {
    OK="$(jget "$1" items.0.succeeded || jget "$1" succeeded || true)"
    ERR="$(jget "$1" items.0.error || jget "$1" error || true)"
    TP="$(jget "$1" items.0.trashPath || jget "$1" trashPath || true)"
    if [ -n "$TP" ]; then TRASHED+=("$TP"); fi
}

canary() { printf 'gargantua attack canary\n' >"$1"; }
inode() { stat -f %i "$1" 2>/dev/null; }
nlink() { stat -f %l "$1" 2>/dev/null; }

# expect_refused NAME REPLY WANTED_ERROR_SUBSTRING ORACLE_STATUS ORACLE_MESSAGE
# ORACLE_STATUS is 0 when the files on disk are exactly as before the attack.
expect_refused() {
    local name=$1 reply=$2 want=$3 oracle=$4 oracle_msg=$5
    parse_reply "$reply"
    if [ "$OK" != "false" ] && [ "$OK" != "true" ]; then
        fail "$name" "no result from the helper (protocol drift or XPC error): $reply"
    elif [ "$OK" = "true" ]; then
        fail "$name" "helper ACCEPTED the request: $reply"
    elif [ "$oracle" -ne 0 ]; then
        fail "$name" "refused, but the files changed: $oracle_msg"
    elif [[ "$ERR" != *"$want"* ]]; then
        fail "$name" "refused for a different reason, so this guard was not exercised (wanted '$want'): $ERR"
    else
        pass "$name"
    fi
}

# ---------------------------------------------------------------- run

echo "App:      $APP ($(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?'))"
echo "Signer:   $IDENTITY"

section "Positive controls (the probe can reach the helper, so refusals below are real)"
version="$("$GOOD" version)"
if [[ "$version" == VERSION* ]]; then
    pass "Signed probe connects (helper $version)"
else
    fail "Signed probe connects" "$version"
    echo; echo "The helper is unreachable or not registered; nothing below would mean anything."
    exit 1
fi

canary "$RUN/control.tmp"
reply="$("$GOOD" trash <<<"$(trash_req "$RUN/control.tmp" move_to_trash)")"
parse_reply "$reply"
if [ "$OK" = "true" ] && [[ "$TP" == "$HOME/.Trash/"* ]] && [ -e "$TP" ] && [ ! -e "$RUN/control.tmp" ]; then
    pass "Allowlisted single-link file moves to your Trash"
    control_trash="$TP"
else
    fail "Allowlisted single-link file moves to your Trash" "$reply"
    control_trash=""
fi

canary "$RUN/control-uid0.tmp"
reply="$("$GOOD" trash <<<"$(trash_req "$RUN/control-uid0.tmp" move_to_trash 0)")"
parse_reply "$reply"
if [ "$OK" = "true" ] && [[ "$TP" == "$HOME/.Trash/"* ]]; then
    pass "Spoofed invokingUserID=0 is ignored (item went to your Trash, not root's)"
else
    fail "Spoofed invokingUserID=0 is ignored" "$reply"
fi

if [ -n "$control_trash" ]; then
    reply="$("$GOOD" trash <<<"$(trash_req "$control_trash" delete_from_trash)")"
    parse_reply "$reply"
    if [ "$OK" = "true" ] && [ ! -e "$control_trash" ]; then
        pass "delete_from_trash removes a direct child of your Trash"
    else
        fail "delete_from_trash removes a direct child of your Trash" "$reply"
    fi
fi

section "Client validation (the helper must refuse callers that aren't Gargantua)"
out="$("$ADHOC" version)"
if [[ "$out" == XPC_ERROR* ]]; then pass "Ad-hoc signed client is rejected"; else fail "Ad-hoc signed client is rejected" "$out"; fi
out="$("$WRONGID" version)"
if [[ "$out" == XPC_ERROR* ]]; then pass "Same-team client with a different identifier is rejected"; else fail "Same-team client with a different identifier is rejected" "$out"; fi
canary "$RUN/x3.tmp"
out="$("$ADHOC" trash <<<"$(trash_req "$RUN/x3.tmp" move_to_trash)")"
if [[ "$out" == XPC_ERROR* ]] && [ -e "$RUN/x3.tmp" ]; then
    pass "Ad-hoc client cannot trash a file"
else
    parse_reply "$out"
    fail "Ad-hoc client cannot trash a file" "$out"
fi

section "Path attacks on move_to_trash / delete_from_trash"

canary "$SAFE/c1"; ln "$SAFE/c1" "$RUN/hardlink.tmp"; ino="$(inode "$SAFE/c1")"
reply="$("$GOOD" trash <<<"$(trash_req "$RUN/hardlink.tmp" move_to_trash)")"
[ "$(inode "$SAFE/c1")" = "$ino" ] && [ "$(nlink "$SAFE/c1")" = 2 ] && [ -e "$RUN/hardlink.tmp" ]; o=$?
expect_refused "Hardlink in /private/tmp to a file outside the allowlist (Sept H1)" "$reply" "multiply-linked" "$o" "link count or link entry changed"

canary "$SAFE/c2"; ln -s "$SAFE" "$RUN/dirlink"
reply="$("$GOOD" trash <<<"$(trash_req "$RUN/dirlink/c2" move_to_trash)")"
[ -e "$SAFE/c2" ]; o=$?
expect_refused "Symlinked parent directory pointing outside the allowlist" "$reply" "symlink" "$o" "$SAFE/c2 is gone"

canary "$SAFE/c3"; ln -s "$SAFE/c3" "$RUN/leaflink.tmp"
reply="$("$GOOD" trash <<<"$(trash_req "$RUN/leaflink.tmp" move_to_trash)")"
[ -e "$SAFE/c3" ] && [ -L "$RUN/leaflink.tmp" ]; o=$?
expect_refused "Symlink leaf pointing outside the allowlist" "$reply" "symlink" "$o" "target or link changed"

canary "$SAFE/c4"
reply="$("$GOOD" trash <<<"$(trash_req "/private/tmp/../..$SAFE/c4" move_to_trash)")"
[ -e "$SAFE/c4" ]; o=$?
expect_refused "../ traversal out of /private/tmp" "$reply" "rejected path" "$o" "$SAFE/c4 is gone"

canary "$SAFE/c5"
reply="$("$GOOD" trash <<<"$(trash_req "$SAFE/c5" move_to_trash)")"
[ -e "$SAFE/c5" ]; o=$?
expect_refused "Path outside the allowlist" "$reply" "rejected path" "$o" "$SAFE/c5 is gone"

canary "$SAFE/c6"
reply="$("$GOOD" trash <<<"$(trash_req "$SAFE/c6" delete_from_trash)")"
[ -e "$SAFE/c6" ]; o=$?
expect_refused "delete_from_trash on a path outside your Trash" "$reply" "rejected path" "$o" "$SAFE/c6 was deleted"

canary "$SAFE/c7"
reply="$("$GOOD" trash <<<"$(trash_req "$HOME/.Trash/../../..$SAFE/c7" delete_from_trash)")"
[ -e "$SAFE/c7" ]; o=$?
expect_refused "delete_from_trash with ../ out of your Trash" "$reply" "rejected path" "$o" "$SAFE/c7 was deleted"

section "Background-item attacks (launchctl and plist trash run as root)"
# Every label below is fake, so even a regressed check can only run launchctl
# against a job that doesn't exist.

reply="$("$GOOD" bgitem <<<"$(bg_req bootout_daemon com.apple.gtua-attack /Library/LaunchDaemons/com.apple.gtua-attack.plist)")"
expect_refused "Apple-namespaced label" "$reply" "Apple-namespaced" 0 ""

reply="$("$GOOD" bgitem <<<"$(bg_req bootout_daemon "gtua-attack/../x" /Library/LaunchDaemons/gtua-attack.plist)")"
expect_refused "Label with path characters" "$reply" "rejected label" 0 ""

label="gtua-attack-b3"
plutil -create xml1 "$USERDIR/$label.plist" && plutil -insert Label -string "$label" "$USERDIR/$label.plist"
reply="$("$GOOD" bgitem <<<"$(bg_req trash_launch_plist "$label" "$USERDIR/$label.plist")")"
[ -e "$USERDIR/$label.plist" ]; o=$?
expect_refused "Plist outside /Library/Launch{Agents,Daemons}" "$reply" "rejected plist path" "$o" "plist was moved"

label="gtua-attack-b4"
plutil -create xml1 "$RUN/$label.plist" && plutil -insert Label -string "$label" "$RUN/$label.plist"
reply="$("$GOOD" bgitem <<<"$(bg_req trash_launch_plist "$label" "/Library/LaunchDaemons/../../$RUN/$label.plist")")"
[ -e "$RUN/$label.plist" ]; o=$?
expect_refused "../ traversal out of /Library/LaunchDaemons" "$reply" "rejected plist path" "$o" "plist was moved"

section "MCP SSE server (shipped binary): DNS rebinding"
MCP_BIN="$APP/Contents/MacOS/GargantuaMCP"
PORT=$((49152 + RANDOM % 10000))
"$MCP_BIN" --sse --port "$PORT" >"$WORK/mcp.log" 2>&1 &
MCP_PID=$!
for _ in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    fail "MCP SSE server starts on 127.0.0.1:$PORT" "$(tail -5 "$WORK/mcp.log")"
else
    status() { curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$@"; }
    code="$(status "http://127.0.0.1:$PORT/sse")"
    if [ "$code" = 200 ]; then pass "Loopback Host is accepted (control)"; else fail "Loopback Host is accepted (control)" "HTTP $code"; fi
    code="$(status --resolve "rebind.attacker.test:$PORT:127.0.0.1" "http://rebind.attacker.test:$PORT/sse")"
    if [[ "$code" == 4* ]]; then pass "Rebound hostname on GET /sse is rejected (HTTP $code)"; else fail "Rebound hostname on GET /sse is rejected" "HTTP $code"; fi
    code="$(status --resolve "rebind.attacker.test:$PORT:127.0.0.1" -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "http://rebind.attacker.test:$PORT/message")"
    if [[ "$code" == 4* ]]; then pass "Rebound hostname on POST /message is rejected (HTTP $code)"; else fail "Rebound hostname on POST /message is rejected" "HTTP $code"; fi
    code="$(status -H 'Host:' "http://127.0.0.1:$PORT/sse")"
    if [[ "$code" == 4* ]]; then pass "Missing Host header is rejected (HTTP $code)"; else fail "Missing Host header is rejected" "HTTP $code"; fi
fi

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
