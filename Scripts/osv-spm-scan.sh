#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: Scripts/osv-spm-scan.sh [Package.resolved] [-- osv-scanner args...]

Generate an OSV custom lockfile from SwiftPM's Package.resolved and scan it
with osv-scanner. Extra arguments after -- are forwarded to osv-scanner.

Examples:
  Scripts/osv-spm-scan.sh
  Scripts/osv-spm-scan.sh -- --format json --output-file /tmp/osv-spm.json
USAGE
}

LOCKFILE="Package.resolved"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

if [ "${1:-}" != "" ] && [ "${1:-}" != "--" ]; then
    LOCKFILE="$1"
    shift
fi

if [ "${1:-}" = "--" ]; then
    shift
fi

if [ ! -f "$LOCKFILE" ]; then
    echo "SwiftPM lockfile not found: $LOCKFILE" >&2
    exit 66
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to convert Package.resolved for osv-scanner" >&2
    exit 69
fi

if ! command -v osv-scanner >/dev/null 2>&1; then
    echo "osv-scanner is required. Install with: brew install osv-scanner" >&2
    exit 69
fi

CUSTOM_LOCKFILE="$(mktemp)"
trap 'rm -f "$CUSTOM_LOCKFILE"' EXIT

jq --arg lockfile "$LOCKFILE" '
def normalizedRepository:
    if .location? then
        .location
        | sub("^https?://"; "")
        | sub("^git@"; "")
        | sub(":"; "/")
        | sub("\\.git$"; "")
    else
        .identity
    end;

{
    results: [
        {
            source: {
                path: $lockfile,
                type: "lockfile"
            },
            packages: [
                .pins[]
                | {
                    package: (
                        {
                            name: normalizedRepository,
                            version: (.state.version // ""),
                            commit: (.state.revision // "")
                        }
                        | with_entries(select(.value != null and .value != ""))
                    )
                }
            ]
        }
    ]
}
' "$LOCKFILE" > "$CUSTOM_LOCKFILE"

exec osv-scanner scan source --lockfile "osv-scanner:$CUSTOM_LOCKFILE" "$@"
