#!/usr/bin/env bash
# Compute SHA-256 pins for an mlx-community HF model and emit a Swift
# `ModelFile(...)` snippet suitable for pasting into
# `Sources/GargantuaCore/Services/ModelDownloadManager.swift`'s
# `defaultModel` definition.
#
# For LFS files (large — model.safetensors, tokenizer.json) the pin is
# lifted directly from the HF LFS pointer's `oid` (no download). For
# non-LFS files (small JSON configs) the script downloads the bytes and
# hashes them locally.
#
# Usage:
#   Scripts/pin-model.sh [REPO_ID]
#
# Example:
#   Scripts/pin-model.sh mlx-community/Llama-3.2-1B-Instruct-4bit
#
# Defaults to the current pinned model if no REPO_ID is given.
#
# Requirements:
#   - curl, shasum, python3 (for JSON parsing) in PATH

set -euo pipefail

REPO_ID="${1:-mlx-community/Llama-3.2-1B-Instruct-4bit}"

die() {
    echo "error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH"
}

require_command curl
require_command shasum
require_command python3

# Files a HF-layout MLX model needs for MLXInferenceEngine to load it.
NEEDED_FILES=(
    "config.json"
    "tokenizer_config.json"
    "special_tokens_map.json"
    "tokenizer.json"
    "model.safetensors"
)

API_URL="https://huggingface.co/api/models/$REPO_ID/tree/main"
RESOLVE_URL="https://huggingface.co/$REPO_ID/resolve/main"

echo "Fetching file tree for $REPO_ID..." >&2
TREE_JSON="$(curl -fsSL --max-time 30 "$API_URL")"

TMP_DIR="$(mktemp -d -t gargantua-pin-model-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

derive_id() {
    # Directory name = last path component of REPO_ID.
    echo "${REPO_ID##*/}"
}

MODEL_ID="$(derive_id)"

printf '\n// Paste into ModelDownloadManager.swift, inside `defaultModel.files`:\n\n'
printf '// id: %s\n' "$MODEL_ID"

for name in "${NEEDED_FILES[@]}"; do
    ENTRY="$(printf '%s' "$TREE_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
target = sys.argv[1]
for entry in data:
    if entry.get('path') == target:
        print(json.dumps(entry))
        sys.exit(0)
sys.exit(1)
" "$name" || true)"

    [ -n "$ENTRY" ] || die "file $name not found in $REPO_ID tree"

    SIZE="$(printf '%s' "$ENTRY" | python3 -c "import json,sys; print(json.load(sys.stdin)['size'])")"
    LFS_SHA="$(printf '%s' "$ENTRY" | python3 -c "
import json, sys
e = json.load(sys.stdin)
lfs = e.get('lfs') or {}
print(lfs.get('oid') or '')
")"

    if [ -n "$LFS_SHA" ]; then
        SHA="$LFS_SHA"
    else
        # Non-LFS: fetch bytes and hash locally.
        curl -fsSL --max-time 120 "$RESOLVE_URL/$name" -o "$TMP_DIR/$name"
        SHA="$(shasum -a 256 "$TMP_DIR/$name" | awk '{print $1}')"
        ACTUAL_SIZE="$(stat -f%z "$TMP_DIR/$name")"
        if [ "$ACTUAL_SIZE" != "$SIZE" ]; then
            die "$name size mismatch: tree says $SIZE, download is $ACTUAL_SIZE"
        fi
    fi

    cat <<EOF
ModelFile(
    name: "$name",
    url: URL(string: "$RESOLVE_URL/$name")!,
    sha256: "$SHA",
    size: $SIZE
),
EOF
done
