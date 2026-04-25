#!/usr/bin/env bash
# Tenet Toolchain Installer
# Generated: 2026-04-24
# Platform: macOS (Apple Silicon, Homebrew available)
#
# Review this script before running it.
# Usage: chmod +x .healthcheck/install-tools.sh && ./.healthcheck/install-tools.sh

set -euo pipefail

echo "Installing Tenet toolchain dependencies for Gargantua..."
echo ""

# ── Brew tools ─────────────────────────────────────────────────────────────
echo "→ Installing via Homebrew..."
brew install trufflehog swiftformat

# ── npm tools ──────────────────────────────────────────────────────────────
echo "→ Installing via npm..."
npm install -g markdownlint-cli

echo ""
echo "Verifying installation..."
echo -n "  trufflehog:   "; trufflehog --version 2>/dev/null | head -1 || echo "FAILED"
echo -n "  swiftformat:  "; swiftformat --version 2>/dev/null | head -1 || echo "FAILED"
echo -n "  markdownlint: "; markdownlint --version 2>/dev/null | head -1 || echo "FAILED"
echo ""
echo "Done. Re-run /tenet-skills:tenet-toolchain-setup to update .healthcheck.toml."
