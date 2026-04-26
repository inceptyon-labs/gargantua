#!/usr/bin/env bash
# run-mutation.sh — opt-in mutation testing for Gargantua via Muter.
#
# This is NOT wired into `swift test` or the default CI pipeline.
# Invoke it explicitly:
#
#   Scripts/run-mutation.sh                        # mutate Swift files
#                                                  # changed vs. main
#   Scripts/run-mutation.sh --base origin/main     # change base
#   Scripts/run-mutation.sh --all                  # run full mutation
#   Scripts/run-mutation.sh --files A.swift,B.swift  # explicit file list
#
# Output (Tenet-compatible): .healthcheck/mutation/muter.json
#
# Install Muter:
#   brew install muter-mutation-testing/formulae/muter
#
# Exit codes:
#   0 — mutation report generated, OR no Swift files in scope (skipped).
#   1 — Muter is not installed.
#   2 — Muter ran but failed to produce a valid report.
#   3 — Bad arguments.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

OUTPUT_DIR="$REPO_ROOT/.healthcheck/mutation"
OUTPUT_FILE="$OUTPUT_DIR/muter.json"
DEFAULT_BASE="origin/main"

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
    cat <<'USAGE' >&2
Usage: run-mutation.sh [--base <ref>] [--files <comma-list>] [--all]
                      [--output <path>]

Options:
  --base <ref>      Diff base for changed-file detection.
                    Default: origin/main (falls back to merge-base with
                    HEAD~1 if origin/main is unavailable).
  --files <list>    Comma-separated Swift files to mutate. Overrides
                    changed-file detection.
  --all             Run a full mutation pass (no --files-to-mutate).
  --output <path>   Override JSON report path. Default:
                    .healthcheck/mutation/muter.json
  -h, --help        Show this message.
USAGE
}

BASE_REF=""
EXPLICIT_FILES=""
RUN_ALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --base)    BASE_REF="${2:-}"; shift 2 ;;
        --files)   EXPLICIT_FILES="${2:-}"; shift 2 ;;
        --all)     RUN_ALL=1; shift ;;
        --output)  OUTPUT_FILE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)         usage; exit 3 ;;
    esac
done

cd "$REPO_ROOT"
mkdir -p "$OUTPUT_DIR"

require_muter() {
    if ! command -v muter >/dev/null 2>&1; then
        cat <<'MSG' >&2
error: muter is not installed.

Install with:
  brew install muter-mutation-testing/formulae/muter

Then re-run Scripts/run-mutation.sh.
MSG
        exit 1
    fi
}

# OUTPUT_FILE may be absolute or repo-relative; normalise for messaging.
case "$OUTPUT_FILE" in
    /*) OUTPUT_FILE_ABS="$OUTPUT_FILE" ;;
    *)  OUTPUT_FILE_ABS="$REPO_ROOT/$OUTPUT_FILE" ;;
esac
mkdir -p "$(dirname "$OUTPUT_FILE_ABS")"

# Resolve the diff base when we need to detect changed files.
resolve_base() {
    local ref="$1"
    if [ -z "$ref" ]; then ref="$DEFAULT_BASE"; fi
    if git rev-parse --verify --quiet "$ref" >/dev/null; then
        printf '%s' "$ref"
        return 0
    fi
    # Fallback: previous commit on this branch.
    if git rev-parse --verify --quiet HEAD~1 >/dev/null; then
        printf '%s' "HEAD~1"
        return 0
    fi
    return 1
}

# Filter raw diff output down to mutable Swift sources. Mirrors the
# substring exclusions in muter.conf.yml so the script and config agree.
filter_mutable_swift() {
    awk '
        /\.swift$/ \
            && !/^Tests\// \
            && !/\/Tests\// \
            && /^Sources\// \
            && !/Tests\.swift$/ \
            && !/Package\.swift$/ \
            && !/\/Resources\// \
            && !/AppShell\// \
            && !/\.build\// \
            && !/DerivedData\// \
            && !/Pods\// \
            && !/Carthage\//
    '
}

CHANGED_FILES=""
SCOPE_DESC=""

if [ "$RUN_ALL" -eq 1 ] && [ -n "$EXPLICIT_FILES" ]; then
    die "--all and --files are mutually exclusive" 3
fi

if [ "$RUN_ALL" -eq 1 ]; then
    SCOPE_DESC="full mutation pass"
elif [ -n "$EXPLICIT_FILES" ]; then
    CHANGED_FILES="$EXPLICIT_FILES"
    SCOPE_DESC="explicit files: $CHANGED_FILES"
else
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "not inside a git repository; pass --files or --all"
    fi
    if ! BASE="$(resolve_base "$BASE_REF")"; then
        warn "could not resolve diff base; nothing to mutate"
        printf '{"mutationScore":null,"totalAppliedMutationOperators":0,"killedMutants":0,"survivedMutants":0,"timedOutMutants":0,"runtimeErrors":0,"skipped":true,"skipReason":"no diff base available"}\n' > "$OUTPUT_FILE_ABS"
        log "wrote skip marker to $OUTPUT_FILE_ABS"
        exit 0
    fi
    log "detecting changed Swift files vs. $BASE..."
    CHANGED_RAW="$(git diff --name-only --diff-filter=ACMR "$BASE"...HEAD || true)"
    # Include tracked-but-uncommitted edits too, so local runs target the
    # files the developer is actually working on.
    CHANGED_RAW="$CHANGED_RAW
$(git diff --name-only --diff-filter=ACMR || true)
$(git diff --name-only --diff-filter=ACMR --cached || true)"
    CHANGED_FILTERED="$(printf '%s\n' "$CHANGED_RAW" | sort -u | filter_mutable_swift)"
    if [ -z "$CHANGED_FILTERED" ]; then
        log "no mutable Swift files changed vs. $BASE; skipping mutation run"
        printf '{"mutationScore":null,"totalAppliedMutationOperators":0,"killedMutants":0,"survivedMutants":0,"timedOutMutants":0,"runtimeErrors":0,"skipped":true,"skipReason":"no changed Swift sources","base":"%s"}\n' "$BASE" > "$OUTPUT_FILE_ABS"
        log "wrote skip marker to $OUTPUT_FILE_ABS"
        exit 0
    fi
    CHANGED_FILES="$(printf '%s' "$CHANGED_FILTERED" | paste -sd, -)"
    SCOPE_DESC="$(printf '%s\n' "$CHANGED_FILTERED" | wc -l | tr -d ' ') changed Swift file(s) vs. $BASE"
fi

log "scope: $SCOPE_DESC"
log "report: $OUTPUT_FILE_ABS"

# We only need muter once we know there is something to mutate.
require_muter

MUTER_ARGS=(
    --skip-update-check
    --format json
    --output "$OUTPUT_FILE_ABS"
)
if [ "$RUN_ALL" -ne 1 ] && [ -n "$CHANGED_FILES" ]; then
    MUTER_ARGS+=(--files-to-mutate "$CHANGED_FILES")
fi

log "running: muter ${MUTER_ARGS[*]}"
# Muter exits non-zero when survivors exist; that is a *result*, not an
# infrastructure failure, so don't propagate it. Only fail the script if
# the JSON report is missing or unparseable.
set +e
muter "${MUTER_ARGS[@]}"
MUTER_EXIT=$?
set -e

if [ ! -s "$OUTPUT_FILE_ABS" ]; then
    die "muter exited with status $MUTER_EXIT and produced no report at $OUTPUT_FILE_ABS" 2
fi

# Validate that the report is JSON (Tenet ingestion requires this).
if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OUTPUT_FILE_ABS" >/dev/null 2>&1; then
        die "muter wrote a non-JSON report to $OUTPUT_FILE_ABS" 2
    fi
fi

log "mutation report written to $OUTPUT_FILE_ABS (muter exit=$MUTER_EXIT)"
exit 0
