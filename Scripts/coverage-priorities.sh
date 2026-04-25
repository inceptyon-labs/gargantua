#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: Scripts/coverage-priorities.sh [coverage.lcov] [--limit N] [--min-lines N] [--fail-under PERCENT]

Print the lowest-covered GargantuaCore service/model files from an lcov report.
The optional --fail-under gate is intentionally opt-in so CI can report
priorities before the project agrees on a coverage baseline.
USAGE
}

LCOV_PATH="coverage.lcov"
LIMIT=20
MIN_LINES=20
FAIL_UNDER=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --limit)
            if [ "$#" -lt 2 ]; then
                echo "--limit requires a value" >&2
                exit 64
            fi
            LIMIT="$2"
            shift 2
            ;;
        --min-lines)
            if [ "$#" -lt 2 ]; then
                echo "--min-lines requires a value" >&2
                exit 64
            fi
            MIN_LINES="$2"
            shift 2
            ;;
        --fail-under)
            if [ "$#" -lt 2 ]; then
                echo "--fail-under requires a value" >&2
                exit 64
            fi
            FAIL_UNDER="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
        *)
            LCOV_PATH="$1"
            shift
            ;;
    esac
done

if [ ! -f "$LCOV_PATH" ]; then
    echo "Coverage report not found: $LCOV_PATH" >&2
    exit 66
fi

case "$LIMIT" in
    ""|*[!0-9]*)
        echo "--limit must be an integer" >&2
        exit 64
        ;;
esac

case "$MIN_LINES" in
    ""|*[!0-9]*)
        echo "--min-lines must be an integer" >&2
        exit 64
        ;;
esac

if [ -n "$FAIL_UNDER" ] && [[ ! "$FAIL_UNDER" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "--fail-under must be numeric" >&2
        exit 64
fi

PRIORITIES="$(mktemp)"
SUMMARY="$(mktemp)"
trap 'rm -f "$PRIORITIES" "$SUMMARY"' EXIT

awk -v out="$PRIORITIES" -v summary="$SUMMARY" -v minLines="$MIN_LINES" '
function reset_record() {
    file = ""
    linesFound = 0
    linesHit = 0
}

function emit_record() {
    if (file ~ /Sources\/GargantuaCore\/(Services|Models)\//) {
        totalFound += linesFound
        totalHit += linesHit
        if (linesFound >= minLines) {
            percent = linesFound == 0 ? 100 : (linesHit * 100 / linesFound)
            printf "%.2f\t%d\t%d\t%s\n", percent, linesFound - linesHit, linesFound, file >> out
        }
    }
}

BEGIN {
    reset_record()
}

/^SF:/ {
    if (file != "") {
        emit_record()
    }
    reset_record()
    file = substr($0, 4)
    sub(/^.*\/Sources\//, "Sources/", file)
    next
}

/^DA:/ {
    split(substr($0, 4), parts, ",")
    linesFound += 1
    if ((parts[2] + 0) > 0) {
        linesHit += 1
    }
    next
}

/^end_of_record/ {
    emit_record()
    reset_record()
    next
}

END {
    if (file != "") {
        emit_record()
    }
    totalPercent = totalFound == 0 ? 100 : (totalHit * 100 / totalFound)
    printf "%.2f\t%d\t%d\n", totalPercent, totalHit, totalFound > summary
}
' "$LCOV_PATH"

IFS="$(printf '\t')" read -r TOTAL_PERCENT TOTAL_HIT TOTAL_FOUND < "$SUMMARY"

echo "GargantuaCore service/model line coverage: ${TOTAL_PERCENT}% (${TOTAL_HIT}/${TOTAL_FOUND})"
echo
echo "Lowest-covered service/model files:"
printf "%8s  %9s  %7s  %s\n" "lines" "uncovered" "total" "file"
sort -n -k1,1 "$PRIORITIES" | head -n "$LIMIT" | awk -F '\t' '{
    printf "%7.2f%%  %9d  %7d  %s\n", $1, $2, $3, $4
}'

if [ -n "$FAIL_UNDER" ]; then
    awk -v actual="$TOTAL_PERCENT" -v expected="$FAIL_UNDER" 'BEGIN {
        if ((actual + 0) < (expected + 0)) {
            printf "Coverage %.2f%% is below required %.2f%%\n", actual, expected > "/dev/stderr"
            exit 1
        }
    }'
fi
