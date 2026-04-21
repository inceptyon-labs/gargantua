#!/usr/bin/env bash
# test.sh — `swift test` wrapper that stages mlx.metallib alongside the test
# binary so MLX-touching tests can actually run.
#
# Why: `swift test` launches the xctest binary from inside
# `.build/<arch>/debug/GargantuaPackageTests.xctest/Contents/MacOS/`, and
# mlx-swift's runtime looks for a colocated `mlx.metallib` at that path
# first. Without it, any test that forces MLX's Metal device init fails with
# "Failed to load the default metallib" (see build-metallib.sh header).
#
# This wrapper:
#   1. Runs `swift package resolve` (if needed) so the mlx-swift shader
#      sources are present under .build/checkouts/.
#   2. Does a quick incremental `swift build --build-tests` so the test
#      binary directory exists.
#   3. Calls Scripts/build-metallib.sh to compile mlx.metallib into the test
#      binary's MacOS directory.
#   4. Exec's `swift test "$@"` with the same arguments passed to this
#      wrapper.
#
# Callers should use this instead of `swift test` when running tests locally,
# especially integration tests that exercise MLX. CI can either call this
# script directly or add the same staging step before `swift test`.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

log()  { printf '==> %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

SWIFT_TEST_ARGS=("$@")
CONFIG="debug"
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--configuration)
            CONFIG="$2"
            break
            ;;
        *)
            shift
            ;;
    esac
done

cd "$REPO_ROOT"

if [ ! -d ".build/checkouts/mlx-swift" ]; then
    log "Resolving SPM deps so mlx-swift shader sources are on disk..."
    swift package resolve
fi

log "Building tests ($CONFIG) to locate test binary directory..."
swift build -c "$CONFIG" --build-tests >/dev/null

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
TEST_BUNDLE_MACOS="$BIN_DIR/GargantuaPackageTests.xctest/Contents/MacOS"

if [ ! -d "$TEST_BUNDLE_MACOS" ]; then
    die "expected test bundle path missing: $TEST_BUNDLE_MACOS
     Did --build-tests succeed?"
fi

"$_SCRIPT_DIR/build-metallib.sh" --output "$TEST_BUNDLE_MACOS/mlx.metallib"

log "Running swift test ${SWIFT_TEST_ARGS[*]}..."
exec swift test "${SWIFT_TEST_ARGS[@]}"
