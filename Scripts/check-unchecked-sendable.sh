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
BASELINE=63

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# A gate that fails open is worse than no gate, so bail loudly rather than
# letting `set -e` surface this as a bare non-zero exit.
if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is required by this gate but was not found" >&2
    exit 2
fi

# Scanned in python rather than grep for two reasons a literal-string grep
# gets wrong:
#
#   * `@unchecked` and `Sendable` are separate tokens, so Swift accepts any
#     whitespace between them - including a newline. `: @unchecked\n Sendable`
#     compiles, and no formatter here rejoins it, so a literal grep would miss
#     a real opt-out.
#   * A `///` comment *explaining* an opt-out is prose, not an opt-out. Counting
#     it means comment edits move the number with no safety change.
occurrences="$(python3 - <<'PY'
import pathlib
import re

ATTRIBUTE = re.compile(r"@unchecked\s+Sendable")

# Strips `//` line comments, which covers `///` doc comments too. A `/* */`
# block comment mentioning the attribute would still count; that has not come
# up in this tree and parsing for it costs more than it saves.
LINE_COMMENT = re.compile(r"//.*")

for path in sorted(pathlib.Path("Sources").rglob("*.swift")):
    raw = path.read_text(encoding="utf-8", errors="replace")
    # Blank the comments in place rather than dropping the lines, so the line
    # numbers reported below still match the file on disk.
    code = "\n".join(LINE_COMMENT.sub("", line) for line in raw.split("\n"))
    for match in ATTRIBUTE.finditer(code):
        print(f"{path}:{code.count(chr(10), 0, match.start()) + 1}")
PY
)"

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
