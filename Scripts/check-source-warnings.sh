#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: Scripts/check-source-warnings.sh [swift build args...]
       Scripts/check-source-warnings.sh --check-log FILE

Build the package (including tests) and fail if the compiler emits any
warning from this repository's own Sources/ tree.

Package-wide -warnings-as-errors is not usable here: the mlx.metallib build
plugin carries pre-existing PackagePlugin Path -> URL deprecations that are
their own migration. This gate is scoped to Sources/ instead, so Swift 6
actor-isolation warnings cannot regress unnoticed while the plugin's
deprecations stay out of scope.

Extra arguments are forwarded to `swift build`, e.g.

  Scripts/check-source-warnings.sh --enable-code-coverage

--check-log FILE skips the build and instead scans an existing build log
(e.g. one already captured by another build configuration), e.g.

  Scripts/check-source-warnings.sh --check-log licensed-test.log
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Report warnings under Sources/ found in an existing build log. The repo
# root prefix is matched as a literal string (via awk's index()), so a clone
# path containing regex or sed-delimiter metacharacters cannot silently
# neuter the gate.
check_log() {
    local log_file="$1"
    local offenders
    offenders="$(awk -v root="$ROOT/" '
        index($0, root) == 1 {
            line = substr($0, length(root) + 1)
            if (line ~ /^Sources\/.*: warning: /) { print line }
        }' "$log_file" | sort -u)"

    if [ -n "$offenders" ]; then
        echo ""
        echo "Compiler warnings under Sources/ (this gate fails on any):"
        echo ""
        printf '%s\n' "$offenders"
        echo ""
        echo "Fix them, or if the warning is genuinely acceptable, silence it at the"
        echo "call site rather than widening this gate."
        return 1
    fi

    echo "OK - no compiler warnings under Sources/ in $(basename "$log_file")"
}

if [ "${1:-}" = "--check-log" ]; then
    LOG_FILE="${2:-}"
    if [ -z "$LOG_FILE" ]; then
        echo "error: --check-log requires a FILE argument" >&2
        exit 2
    fi
    if [ ! -r "$LOG_FILE" ]; then
        echo "error: cannot read log file: $LOG_FILE" >&2
        exit 2
    fi
    check_log "$LOG_FILE"
    exit $?
fi

# Warnings are only emitted for files the compiler actually recompiles, so
# this gate assumes a cold build. CI checks out fresh and restores no .build
# cache; adding one would silently weaken this check.
BUILD_LOG="$(mktemp -t gargantua-warning-gate)"
trap 'rm -f "$BUILD_LOG"' EXIT

swift build --build-tests "$@" 2>&1 | tee "$BUILD_LOG"

check_log "$BUILD_LOG"
