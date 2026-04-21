#!/usr/bin/env bash
# Build vendored helper binaries from pinned crates.io sources and place them
# under Sources/GargantuaCore/Resources/bin so SPM embeds them in the
# GargantuaCore module resource bundle.
#
# Current scope: aarch64-apple-darwin only. Intel + universal binaries are
# tracked by gargantua-qyqd.
#
# Usage:
#   Scripts/fetch-vendored-bins.sh
#
# Requirements:
#   - cargo, curl, shasum in PATH
#   - aarch64-apple-darwin toolchain (the host toolchain on Apple Silicon)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCKFILE="$SCRIPT_DIR/vendored-bins.lock"
DEST_DIR="$REPO_ROOT/Sources/GargantuaCore/Resources/bin"
DEFAULT_RUSTFLAGS="-C opt-level=z -C panic=abort -C link-arg=-Wl,-dead_strip"

die() {
    echo "error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH"
}

[ -f "$LOCKFILE" ] || die "missing lockfile at $LOCKFILE"

require_command cargo
require_command codesign
require_command curl
require_command shasum
require_command rustc

HOST_TRIPLE="$(rustc -vV | awk '/^host:/ {print $2}')"
if [ "$HOST_TRIPLE" != "aarch64-apple-darwin" ]; then
    die "this script currently only supports aarch64-apple-darwin hosts (got $HOST_TRIPLE); Intel + universal builds are tracked in gargantua-qyqd"
fi

# shellcheck source=Scripts/vendored-bins.lock
. "$LOCKFILE"

BUILD_ROOT="$(mktemp -d -t gargantua-vendored-bins-XXXXXX)"
trap 'rm -rf "$BUILD_ROOT"' EXIT

verify_crate_checksum() {
    local crate="$1"
    local version="$2"
    local expected_sha="$3"
    local crate_file="$BUILD_ROOT/$crate-$version.crate"
    local url="https://static.crates.io/crates/$crate/$crate-$version.crate"
    local actual_sha

    echo "Fetching $crate $version source crate..."
    curl -fsSL "$url" -o "$crate_file"
    actual_sha="$(shasum -a 256 "$crate_file" | awk '{print $1}')"

    if [ "$actual_sha" != "$expected_sha" ]; then
        die "$crate $version checksum mismatch: expected $expected_sha, got $actual_sha"
    fi
}

build_one() {
    local crate="$1"
    local bin_name="$2"
    local version="$3"
    local expected_sha="$4"
    local install_root="$BUILD_ROOT/install-$crate"
    local src_bin="$install_root/bin/$bin_name"
    local dest_bin="$DEST_DIR/$bin_name"
    local size_bytes
    local size_mb

    [ -n "$version" ] || die "missing version for $crate"
    [ -n "$expected_sha" ] || die "missing SHA-256 for $crate $version"

    verify_crate_checksum "$crate" "$version" "$expected_sha"

    echo "Building $crate $version for $HOST_TRIPLE..."
    echo "Using RUSTFLAGS=${RUSTFLAGS:-$DEFAULT_RUSTFLAGS}"
    RUSTFLAGS="${RUSTFLAGS:-$DEFAULT_RUSTFLAGS}" cargo install "$crate" \
        --version "$version" \
        --root "$install_root" \
        --locked \
        --quiet

    [ -x "$src_bin" ] || die "cargo did not produce an executable at $src_bin"

    mkdir -p "$DEST_DIR"
    cp "$src_bin" "$dest_bin"
    chmod 0755 "$dest_bin"
    strip "$dest_bin" 2>/dev/null || true
    codesign --force --sign - "$dest_bin"

    size_bytes="$(stat -f%z "$dest_bin")"
    size_mb="$(awk "BEGIN { printf \"%.2f\", $size_bytes / 1024 / 1024 }")"
    echo "Bundled $bin_name -> $dest_bin (${size_mb} MB)"
    "$dest_bin" --version
}

build_one "fclones" "fclones" "$FCLONES_VERSION" "$FCLONES_SHA256"
build_one "czkawka_cli" "czkawka_cli" "$CZKAWKA_CLI_VERSION" "$CZKAWKA_CLI_SHA256"
