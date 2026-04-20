#!/usr/bin/env bash
# run.sh — `swift run` wrapper that stages mlx.metallib alongside the
# Gargantua binary so any MLX-touching UI (Explain button, etc.) can
# actually init Metal without crashing.
#
# Why: `swift run` launches the executable from
# `.build/<arch>/<config>/Gargantua`, and mlx-swift's runtime looks for a
# colocated `mlx.metallib` at that path first. The release pipeline stages
# this via `Scripts/release/build.sh`; `swift run` does not. Without it,
# MLXInferenceEngine.load aborts inside MLX C++ with "Failed to load the
# default metallib" — an un-catchable crash from the Swift side.
#
# This wrapper:
#   1. Runs `swift package resolve` (if needed) so the mlx-swift shader
#      sources are present under .build/checkouts/.
#   2. Does an incremental `swift build` so the binary directory exists.
#   3. Calls Scripts/build-metallib.sh to compile mlx.metallib into the
#      same directory as the Gargantua binary.
#   4. Exec's `swift run Gargantua "$@"` so any additional args flow through.
#
# Mirrors `Scripts/test.sh`'s strategy. Use this (or a similar pre-step in
# Xcode's scheme) whenever launching the app locally for AI testing.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

log()  { printf '==> %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

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

log "Building Gargantua ($CONFIG)..."
swift build -c "$CONFIG" --product Gargantua >/dev/null

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/Gargantua"

if [ ! -x "$BIN" ]; then
    die "expected binary missing: $BIN
     Did the build succeed?"
fi

"$_SCRIPT_DIR/build-metallib.sh" --output "$BIN_DIR/mlx.metallib"

log "Running Gargantua..."
exec swift run -c "$CONFIG" Gargantua "$@"
