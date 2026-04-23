#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: Scripts/validate-rules.sh [all|cleanup|uninstall]

Runs the focused rule-validation test suites used for community rule PRs.
EOF
}

mode="${1:-all}"

case "$mode" in
    all)
        filter='RuleSetIntegrationTests|RemnantRuleParserTests|RemnantRuleSetIntegrationTests|CleanupProfileTests'
        ;;
    cleanup)
        filter='RuleParserTests|RuleSetIntegrationTests|CleanupProfileTests'
        ;;
    uninstall)
        filter='RemnantRuleParserTests|RemnantRuleSetIntegrationTests'
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 1
        ;;
esac

cd "$REPO_ROOT"

cleanup_files="$(find Sources/GargantuaCore/Resources/cleanup_rules -type f | wc -l | tr -d ' ')"
cleanup_rules="$(rg -n '^\s*- id:' Sources/GargantuaCore/Resources/cleanup_rules | wc -l | tr -d ' ')"
uninstall_files="$(find Sources/GargantuaCore/Resources/uninstall_rules -type f | wc -l | tr -d ' ')"
uninstall_rules="$(rg -n '^\s*- id:' Sources/GargantuaCore/Resources/uninstall_rules | wc -l | tr -d ' ')"

printf '==> Cleanup rules: %s files / %s rules\n' "$cleanup_files" "$cleanup_rules"
printf '==> Uninstall rules: %s files / %s rules\n' "$uninstall_files" "$uninstall_rules"
printf '==> Running focused rule validation (%s)\n' "$mode"

exec swift test --filter "$filter"
