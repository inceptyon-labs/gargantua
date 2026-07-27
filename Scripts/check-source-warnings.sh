#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: Scripts/check-source-warnings.sh [swift build args...]

Build the package (including tests) and fail if the compiler emits any
warning from this repository's own Sources/ tree.

Package-wide -warnings-as-errors is not usable here: the mlx.metallib build
plugin carries pre-existing PackagePlugin Path -> URL deprecations that are
their own migration. This gate is scoped to Sources/ instead, so Swift 6
actor-isolation warnings cannot regress unnoticed while the plugin's
deprecations stay out of scope.

Extra arguments are forwarded to `swift build`, e.g.

  Scripts/check-source-warnings.sh --enable-code-coverage
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Warnings are only emitted for files the compiler actually recompiles, so
# this gate assumes a cold build. CI checks out fresh and restores no .build
# cache; adding one would silently weaken this check.
BUILD_LOG="$(mktemp -t gargantua-warning-gate)"
trap 'rm -f "$BUILD_LOG"' EXIT

swift build --build-tests "$@" 2>&1 | tee "$BUILD_LOG"

# Rewrite absolute paths to repo-relative first, so the offender match below
# is a plain string anchor rather than a regex built from $ROOT (which could
# contain characters meaningful to ERE).
offenders="$(sed "s|^${ROOT}/||" "$BUILD_LOG" | grep -E '^Sources/.*: warning: ' | sort -u || true)"

if [ -n "$offenders" ]; then
    echo ""
    echo "Compiler warnings under Sources/ (this gate fails on any):"
    echo ""
    printf '%s\n' "$offenders"
    echo ""
    echo "Fix them, or if the warning is genuinely acceptable, silence it at the"
    echo "call site rather than widening this gate."
    exit 1
fi

echo "OK - no compiler warnings under Sources/"
