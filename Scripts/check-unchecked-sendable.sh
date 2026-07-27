#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: Scripts/check-unchecked-sendable.sh

Fail if the number of `@unchecked Sendable` occurrences under Sources/ has
changed from the recorded baseline.

Every `@unchecked Sendable` is a type opted out of the compiler's data-race
checking - the author asserting a safety invariant the compiler cannot see.
That is sometimes the right call, but it is never free, and without a gate
the count only drifts upward.

This is a ratchet, not a ceiling. The count must match BASELINE exactly:

  above baseline - a new opt-out landed. Justify it and raise BASELINE in
                   the same commit, or remove it.
  below baseline - an opt-out was removed. Lower BASELINE to match, so the
                   reduction cannot be silently re-spent by a later commit.
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

# Raise only with a reviewed justification; lower whenever an opt-out goes away.
BASELINE=64

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --include='*.swift' so a doc or fixture mentioning the attribute cannot
# move the count. `|| true` because grep exits 1 on no matches, which is a
# legitimate (if currently unreachable) state under `set -e`.
occurrences="$(grep -rn --include='*.swift' '@unchecked Sendable' Sources/ | sort || true)"
count="$(printf '%s' "$occurrences" | grep -c . || true)"

if [ "$count" -gt "$BASELINE" ]; then
    echo ""
    echo "@unchecked Sendable under Sources/: $count (baseline $BASELINE)"
    echo ""
    printf '%s\n' "$occurrences"
    echo ""
    echo "A new @unchecked Sendable landed. Prefer making the type actually"
    echo "Sendable - an actor, a value type, or a lock the compiler can see."
    echo "If the opt-out is genuinely warranted, raise BASELINE in"
    echo "Scripts/check-unchecked-sendable.sh in the same commit so it gets"
    echo "reviewed alongside the code."
    exit 1
fi

if [ "$count" -lt "$BASELINE" ]; then
    echo ""
    echo "@unchecked Sendable under Sources/: $count (baseline $BASELINE)"
    echo ""
    echo "An opt-out was removed - nice. Lock it in by setting BASELINE=$count"
    echo "in Scripts/check-unchecked-sendable.sh, so the headroom cannot be"
    echo "silently re-spent later."
    exit 1
fi

echo "OK - $count @unchecked Sendable occurrences under Sources/ (baseline $BASELINE)"
