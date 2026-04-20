#!/usr/bin/env bash
# build-metallib.sh — compile mlx-swift's Metal shaders into a .metallib.
#
# mlx-swift consumed via SPM does not ship a precompiled default.metallib;
# the shader sources live in the SPM checkout and are expected to be compiled
# by Xcode's build system. `swift build` from the CLI skips that step, so any
# MLX runtime op fails with "Failed to load the default metallib".
#
# This script fills the gap: it finds the mlx-swift checkout under .build/,
# invokes `xcrun metal` on each shader to produce .air files, links them into
# a single `mlx.metallib`, and writes it to the caller-specified output.
#
# MLX's load_default_library (see mlx/backend/metal/device.cpp) checks for a
# colocated `mlx.metallib` next to the binary first, so dropping the artifact
# next to the Gargantua executable (or the test binary) is sufficient — no
# SWIFTPM_BUNDLE plumbing required.
#
# Usage:
#   Scripts/build-metallib.sh --output /path/to/mlx.metallib
#
# Requires: Xcode Metal Toolchain
# (install via `xcodebuild -downloadComponent MetalToolchain`).

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

OUTPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --output)
            OUTPUT="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[ -n "$OUTPUT" ] || die "--output is required"

# ----- Preflight ------------------------------------------------------------

command -v xcrun >/dev/null 2>&1 \
    || die "xcrun not found — install Xcode Command Line Tools"

if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    die "xcrun metal is not available. Install the Metal Toolchain:
     xcodebuild -downloadComponent MetalToolchain"
fi

# mlx-swift source tree — SPM drops checkouts under .build/checkouts/.
MLX_SWIFT_ROOT="$REPO_ROOT/.build/checkouts/mlx-swift"
if [ ! -d "$MLX_SWIFT_ROOT" ]; then
    log "No .build/checkouts/mlx-swift — running swift package resolve first..."
    (cd "$REPO_ROOT" && swift package resolve)
fi
[ -d "$MLX_SWIFT_ROOT" ] \
    || die "mlx-swift checkout still not present at $MLX_SWIFT_ROOT after resolve"

METAL_ROOT="$MLX_SWIFT_ROOT/Source/Cmlx/mlx-generated/metal"
[ -d "$METAL_ROOT" ] \
    || die "unexpected mlx-swift layout: no $METAL_ROOT (did the SPM tree change?)"

# ----- Shader list ----------------------------------------------------------
# Mirrors mlx/mlx/backend/metal/kernels/CMakeLists.txt's `build_kernel(...)`
# invocations. If mlx-swift adds/removes shaders on a version bump, update
# this list and re-run the design doc's build-size measurement.

SHADERS=(
    "$METAL_ROOT/arg_reduce.metal"
    "$METAL_ROOT/conv.metal"
    "$METAL_ROOT/gemv.metal"
    "$METAL_ROOT/layer_norm.metal"
    "$METAL_ROOT/random.metal"
    "$METAL_ROOT/rms_norm.metal"
    "$METAL_ROOT/rope.metal"
    "$METAL_ROOT/scaled_dot_product_attention.metal"
    "$METAL_ROOT/steel/attn/kernels/steel_attention.metal"
)

for s in "${SHADERS[@]}"; do
    [ -f "$s" ] || die "missing shader source $s — mlx-swift layout changed?"
done

# ----- Compile --------------------------------------------------------------

WORKDIR="$(mktemp -d -t gargantua-metallib.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

METAL_FLAGS=(
    -x metal
    -Wall
    -Wextra
    -fno-fast-math
    -Wno-c++17-extensions
    -Wno-c++20-extensions
)

log "Compiling ${#SHADERS[@]} shaders..."
for shader in "${SHADERS[@]}"; do
    base="$(basename "$shader" .metal)"
    xcrun -sdk macosx metal "${METAL_FLAGS[@]}" \
        -c "$shader" \
        -I "$METAL_ROOT" \
        -o "$WORKDIR/$base.air" \
        || die "metal compile failed on $shader"
done

# ----- Link -----------------------------------------------------------------

log "Linking $(basename "$OUTPUT")..."
mkdir -p "$(dirname "$OUTPUT")"
xcrun -sdk macosx metallib "$WORKDIR"/*.air -o "$OUTPUT" \
    || die "metallib link failed"

size="$(stat -f '%z' "$OUTPUT")"
log "Wrote $OUTPUT ($size bytes)"
