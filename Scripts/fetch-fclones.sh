#!/usr/bin/env bash
# Build the bundled `fclones` binary from source and place it at
# Sources/GargantuaCore/Resources/bin/fclones so SPM can embed it
# into the GargantuaCore module resource bundle.
#
# Upstream does not publish prebuilt macOS binaries, so we compile from
# crates.io. Current scope: aarch64-apple-darwin only. Intel + universal
# + team-ID signing are tracked separately (see bean gargantua-vchj
# summary for follow-up references).
#
# Usage:
#   Scripts/fetch-fclones.sh              # builds pinned version
#   FCLONES_VERSION=0.35.0 Scripts/fetch-fclones.sh
#
# Requirements:
#   - cargo in PATH
#   - aarch64-apple-darwin toolchain (the host toolchain on Apple Silicon)
set -euo pipefail

FCLONES_VERSION="${FCLONES_VERSION:-0.35.0}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$REPO_ROOT/Sources/GargantuaCore/Resources/bin"
DEST_BIN="$DEST_DIR/fclones"

if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found in PATH" >&2
    exit 1
fi

HOST_TRIPLE="$(rustc -vV | awk '/^host:/ {print $2}')"
if [ "$HOST_TRIPLE" != "aarch64-apple-darwin" ]; then
    echo "error: this script currently only supports aarch64-apple-darwin hosts (got $HOST_TRIPLE)" >&2
    echo "       Intel + universal builds are tracked as follow-up work." >&2
    exit 1
fi

BUILD_ROOT="$(mktemp -d -t fclones-build-XXXXXX)"
trap 'rm -rf "$BUILD_ROOT"' EXIT

echo "Building fclones $FCLONES_VERSION for $HOST_TRIPLE..."
cargo install fclones \
    --version "$FCLONES_VERSION" \
    --root "$BUILD_ROOT" \
    --locked \
    --quiet

SRC_BIN="$BUILD_ROOT/bin/fclones"
if [ ! -x "$SRC_BIN" ]; then
    echo "error: cargo did not produce an executable at $SRC_BIN" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SRC_BIN" "$DEST_BIN"
chmod 0755 "$DEST_BIN"
strip "$DEST_BIN" 2>/dev/null || true

SIZE_BYTES=$(stat -f%z "$DEST_BIN")
SIZE_MB=$(awk "BEGIN { printf \"%.2f\", $SIZE_BYTES / 1024 / 1024 }")
echo "Bundled fclones -> $DEST_BIN (${SIZE_MB} MB)"

"$DEST_BIN" --version
