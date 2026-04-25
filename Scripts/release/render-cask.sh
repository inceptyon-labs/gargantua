#!/usr/bin/env bash
# render-cask.sh — emit a Homebrew Cask for the current Gargantua release.
#
# Usage: render-cask.sh --version 0.2.0 --sha256 abc... --repo owner/repo
#
# Output (stdout): a `Casks/gargantua.rb` ready to commit into the tap.
# Convention matches inceptyon-labs/homebrew-tap's `freeport` cask:
# DMG hosted on the project repo's GitHub Releases; cask URL points
# at `${repo}/releases/download/v#{version}/...`; livecheck uses
# `:github_latest`. Sparkle is the in-app update mechanism, so the
# Homebrew install/upgrade surface only needs to track latest.

set -euo pipefail

VERSION=""
SHA256=""
REPO=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --sha256)  SHA256="$2";  shift 2 ;;
        --repo)    REPO="$2";    shift 2 ;;
        *) printf 'render-cask.sh: unknown flag: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[ -n "$VERSION" ] || { echo 'render-cask.sh: --version required' >&2; exit 2; }
[ -n "$SHA256"  ] || { echo 'render-cask.sh: --sha256 required'  >&2; exit 2; }
[ -n "$REPO"    ] || { echo 'render-cask.sh: --repo required'    >&2; exit 2; }

cat <<EOF
cask "gargantua" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/${REPO}/releases/download/v#{version}/Gargantua-#{version}.dmg"
  name "Gargantua"
  desc "macOS disk-cleanup and dev-artifact purge tool"
  homepage "https://github.com/${REPO}"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Gargantua.app"

  zap trash: [
    "~/Library/Application Support/Gargantua",
    "~/Library/Caches/com.gargantua.app",
    "~/Library/Preferences/com.gargantua.app.plist",
    "~/Library/Saved Application State/com.gargantua.app.savedState",
  ]
end
EOF
