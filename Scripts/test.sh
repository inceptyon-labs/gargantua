#!/usr/bin/env bash
# test.sh — `swift test` wrapper that stages mlx.metallib alongside the test
# binary so MLX-touching tests can actually run.
#
# Why: `swift test` launches the xctest binary from inside the test
# bundle's `Contents/MacOS/` directory, and
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
#
# Constraint: `-c release` does not build the tests. Test call sites mint
# authorization tokens with `DestructiveActionAuthorization.unchecked(_:)`,
# which is `#if DEBUG` on purpose so the bypass is absent from shipped
# binaries. The debug configuration is the only one the test target compiles
# in; nothing in CI or muter runs release tests.

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

# The native build system writes one GargantuaPackageTests.xctest; the
# swiftbuild system (.build/out/Products/<Config>/) writes one bundle per test
# target. MLX doesn't find the mlx-swift_Cmlx.bundle swiftbuild embeds, so
# stage the metallib into every bundle found. swiftbuild also codesigns the
# bundles, and an unsigned file in Contents/MacOS makes the next build's
# codesign fail, so each staged copy is ad-hoc signed.
TEST_BUNDLES=()
if [ -d "$BIN_DIR/GargantuaPackageTests.xctest/Contents/MacOS" ]; then
    TEST_BUNDLES+=("$BIN_DIR/GargantuaPackageTests.xctest/Contents/MacOS")
else
    for bundle in "$BIN_DIR"/*Tests.xctest/Contents/MacOS; do
        [ -d "$bundle" ] && TEST_BUNDLES+=("$bundle")
    done
fi

if [ ${#TEST_BUNDLES[@]} -eq 0 ]; then
    die "no test bundle found under $BIN_DIR
     Did --build-tests succeed?"
fi

"$_SCRIPT_DIR/build-metallib.sh" --output "${TEST_BUNDLES[0]}/mlx.metallib"
for bundle in "${TEST_BUNDLES[@]}"; do
    [ "$bundle" = "${TEST_BUNDLES[0]}" ] || cp "${TEST_BUNDLES[0]}/mlx.metallib" "$bundle/mlx.metallib"
    codesign --force --sign - "$bundle/mlx.metallib" 2>/dev/null
done

log "Running swift test ${SWIFT_TEST_ARGS[*]}..."
exec swift test "${SWIFT_TEST_ARGS[@]}"
