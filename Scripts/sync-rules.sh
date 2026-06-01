#!/usr/bin/env bash
#
# Reconcile the bundled rule snapshot with the gargantua-rules source of truth
# and maintain Resources/rules-sync.json.
#
#   sync-rules.sh check          Verify the bundle matches its recorded upstream
#                                commit (honoring localOnly / pendingFromUpstream).
#                                Exits non-zero on undeclared drift. For CI.
#   sync-rules.sh status         Print the manifest + drift summary vs upstream HEAD.
#   sync-rules.sh apply [ref] [--no-validate]
#                                Pull upstream rules into the snapshot (never
#                                deletes local-only files), regenerate the
#                                manifest, and run the rule validators.
#                                --no-validate skips the swift-test validators
#                                (for CI that has no Swift toolchain; the opened
#                                PR's own CI validates instead).
#
# The snapshot is allowed to diverge from upstream in two bounded ways:
#   localOnly           - rules authored in this repo, absent upstream (kept).
#   pendingFromUpstream - upstream paths not yet reviewed in (allowed to differ).
# Any OTHER difference is "undeclared drift" and fails `check`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES="$REPO_ROOT/Sources/GargantuaCore/Resources"
MANIFEST="$RESOURCES/rules-sync.json"
UPSTREAM_DEFAULT="https://github.com/inceptyon-labs/gargantua-rules"

# lane -> "upstream/subdir:bundle/subdir"
LANES=(
    "cleanup:rules/cleanup:cleanup_rules"
    "uninstall:rules/uninstall:uninstall_rules"
    "command:rules/command:command_rules"
)

die() { echo "error: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have python3 || die "python3 is required"
have git || die "git is required"

# Read a top-level string field from the manifest.
manifest_field() {
    python3 -c "import json,sys; print(json.load(open('$MANIFEST')).get('$1',''))"
}

# Read a list field as newline-separated values.
manifest_list() {
    python3 -c "import json,sys; [print(x) for x in json.load(open('$MANIFEST')).get('$1',[])]"
}

clone_upstream() {
    local ref="$1" dest="$2" url
    url="$(manifest_field upstream)"; [ -n "$url" ] || url="$UPSTREAM_DEFAULT"
    rm -rf "$dest"
    git clone --quiet "$url" "$dest"
    git -C "$dest" checkout --quiet "$ref"
}

# Emit drift lines comparing upstream tree $1 against the bundle, honoring the
# declared exception lists. Each line: "<MISSING|CHANGED|EXTRA>\t<bundle-path>".
compute_drift() {
    local upstream_root="$1"
    local local_only pending
    local_only="$(manifest_list localOnly)"
    pending="$(manifest_list pendingFromUpstream)"

    is_excepted() { grep -qxF "$1" <<<"$2"; }

    for lane in "${LANES[@]}"; do
        IFS=":" read -r _name usub bsub <<<"$lane"
        local udir="$upstream_root/$usub" bdir="$RESOURCES/$bsub"
        [ -d "$udir" ] || continue

        # Upstream files: must exist + match in the bundle, unless pending.
        while IFS= read -r rel; do
            local mpath="$bsub/$rel"
            is_excepted "$mpath" "$pending" && continue
            if [ ! -f "$bdir/$rel" ]; then
                printf 'MISSING\t%s\n' "$mpath"
            elif ! diff -q "$udir/$rel" "$bdir/$rel" >/dev/null 2>&1; then
                printf 'CHANGED\t%s\n' "$mpath"
            fi
        done < <(cd "$udir" && find . -type f -name '*.yaml' | sed 's|^\./||' | sort)

        # Bundle files absent upstream: undeclared unless localOnly.
        [ -d "$bdir" ] || continue
        while IFS= read -r rel; do
            local mpath="$bsub/$rel"
            [ -f "$udir/$rel" ] && continue
            is_excepted "$mpath" "$local_only" && continue
            printf 'EXTRA\t%s\n' "$mpath"
        done < <(cd "$bdir" && find . -type f -name '*.yaml' | sed 's|^\./||' | sort)
    done
}

count_lane() {
    local bsub="$1"
    find "$RESOURCES/$bsub" -type f -name '*.yaml' -exec grep -h '^[[:space:]]*- id:' {} + 2>/dev/null | wc -l | tr -d ' '
}

cmd_check() {
    [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST"
    local commit tmp drift
    commit="$(manifest_field commit)"
    [ -n "$commit" ] || die "manifest has no commit"
    tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" EXIT
    echo "Checking bundle against $(manifest_field upstream)@${commit:0:7}..."
    clone_upstream "$commit" "$tmp"
    drift="$(compute_drift "$tmp")"
    if [ -n "$drift" ]; then
        echo "Undeclared drift from upstream@${commit:0:7}:" >&2
        echo "$drift" | sort >&2
        echo >&2
        echo "Resolve by syncing (Scripts/sync-rules.sh apply), or declare the" >&2
        echo "difference in rules-sync.json (localOnly / pendingFromUpstream)." >&2
        exit 1
    fi
    echo "OK — bundle matches upstream@${commit:0:7} (declared exceptions aside)."
}

cmd_status() {
    [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST"
    echo "Manifest ($MANIFEST):"
    python3 -m json.tool "$MANIFEST"
    echo
    local tmp head
    tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" EXIT
    clone_upstream "main" "$tmp"
    head="$(git -C "$tmp" rev-parse HEAD)"
    echo "Upstream main HEAD: ${head:0:7} (manifest commit: $(manifest_field commit | cut -c1-7))"
    echo "Drift vs main HEAD:"
    local drift; drift="$(compute_drift "$tmp")"
    [ -n "$drift" ] && echo "$drift" | sort || echo "  (none beyond declared exceptions)"
}

cmd_apply() {
    local ref="" validate=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-validate) validate=0 ;;
            -*) die "unknown apply option '$1'" ;;
            *) ref="$1" ;;
        esac
        shift
    done
    [ -n "$ref" ] || ref="$(manifest_field ref)"
    [ -n "$ref" ] || ref="main"

    local tmp commit today pending pending_json
    tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" EXIT
    echo "Cloning $(manifest_field upstream) @ ${ref}..."
    clone_upstream "$ref" "$tmp"
    commit="$(git -C "$tmp" rev-parse HEAD)"

    # pendingFromUpstream files are maintainer-managed: never auto-overwritten,
    # and carried forward in the manifest. Used for files intentionally held
    # divergent in either direction (upstream ahead, or bundle ahead).
    pending="$(manifest_list pendingFromUpstream)"
    pending_json="$(manifest_list pendingFromUpstream \
        | python3 -c "import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")"

    # Copy upstream rules in WITHOUT deleting — local-only files survive, an
    # upstream removal never silently drops a bundled rule (do that
    # deliberately), and pendingFromUpstream files are left untouched.
    for lane in "${LANES[@]}"; do
        IFS=":" read -r _name usub bsub <<<"$lane"
        [ -d "$tmp/$usub" ] || continue
        mkdir -p "$RESOURCES/$bsub"
        (cd "$tmp/$usub" && find . -type f -name '*.yaml' -print0) \
            | while IFS= read -r -d '' rel; do
                rel="${rel#./}"
                grep -qxF "$bsub/$rel" <<<"$pending" && continue
                mkdir -p "$RESOURCES/$bsub/$(dirname "$rel")"
                cp "$tmp/$usub/$rel" "$RESOURCES/$bsub/$rel"
            done
    done

    # Recompute localOnly: bundle files with no upstream counterpart.
    local local_only_json="[]"
    local_only_json="$(
        for lane in "${LANES[@]}"; do
            IFS=":" read -r _name usub bsub <<<"$lane"
            [ -d "$RESOURCES/$bsub" ] || continue
            (cd "$RESOURCES/$bsub" && find . -type f -name '*.yaml' | sed 's|^\./||') \
                | while IFS= read -r rel; do
                    [ -f "$tmp/$usub/$rel" ] || echo "$bsub/$rel"
                done
        done | python3 -c "import json,sys; print(json.dumps(sorted(l.strip() for l in sys.stdin if l.strip())))"
    )"

    today="$(date +%F)"
    local c_clean c_uninstall c_command
    c_clean="$(count_lane cleanup_rules)"
    c_uninstall="$(count_lane uninstall_rules)"
    c_command="$(count_lane command_rules)"

    UPSTREAM_URL="$(manifest_field upstream)" \
    REF="$ref" COMMIT="$commit" SYNCED="$today" \
    CLEAN="$c_clean" UNINSTALL="$c_uninstall" COMMAND="$c_command" \
    LOCAL_ONLY="$local_only_json" PENDING="$pending_json" \
    python3 - "$MANIFEST" <<'PY'
import json, os, sys
path = sys.argv[1]
manifest = {
    "$comment": "Records which gargantua-rules commit the bundled rule snapshot was reconciled against. Maintained by Scripts/sync-rules.sh — do not hand-edit. localOnly = rule files authored in this repo, absent upstream, preserved by sync. pendingFromUpstream = maintainer-managed files never auto-overwritten by sync, held divergent in either direction (upstream ahead and not yet reviewed in, or bundle ahead and not yet backflowed).",
    "upstream": os.environ["UPSTREAM_URL"],
    "ref": os.environ["REF"],
    "commit": os.environ["COMMIT"],
    "syncedAt": os.environ["SYNCED"],
    "bundledRuleCounts": {
        "cleanup": int(os.environ["CLEAN"]),
        "uninstall": int(os.environ["UNINSTALL"]),
        "command": int(os.environ["COMMAND"]),
    },
    "localOnly": json.loads(os.environ["LOCAL_ONLY"]),
    "pendingFromUpstream": json.loads(os.environ["PENDING"]),
}
with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY

    if [ "$validate" -eq 1 ]; then
        echo "Synced to ${commit:0:7}. Manifest updated. Validating rules..."
        "$SCRIPT_DIR/validate-rules.sh" all
    else
        echo "Synced to ${commit:0:7}. Manifest updated. Skipped local validation (--no-validate)."
    fi
    echo "Done. Review 'git diff' before committing — synced rule changes are destructive surface area."
}

main() {
    local cmd="${1:-check}"
    case "$cmd" in
        check) cmd_check ;;
        status) cmd_status ;;
        apply) shift; cmd_apply "$@" ;;
        -h|--help|help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            ;;
        *) die "unknown command '$cmd' (try: check | status | apply)";;
    esac
}

main "$@"
