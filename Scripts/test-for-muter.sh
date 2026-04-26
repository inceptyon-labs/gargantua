#!/usr/bin/env bash
# test-for-muter.sh — test runner Muter calls inside its project sandbox.
#
# Why this exists: Muter copies the entire project (including `.build/`)
# into a sibling directory like `<repo>_mutated`. SwiftPM's precompiled
# module cache (`.build/**/ModuleCache/`) records absolute paths from the
# original location, so the first build inside the sandbox fails with:
#
#   error: precompiled file '<sandbox>/.build/.../*.pcm' was compiled with
#   module cache path '<original>/.build/...', but the path is currently
#   '<sandbox>/.build/...'
#
# Strategy: do a quick `swift build --build-tests`. If it fails, assume it
# failed for the cache-path reason, wipe `.build`, and retry. After the
# first mutant the cache is rebuilt under the sandbox path and subsequent
# invocations are fast no-ops here.
#
# Then delegate to the normal `Scripts/test.sh` wrapper, which handles
# MLX metallib staging.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

# Muter spawns the test command with a minimal PATH, which can omit the
# system tools SwiftPM shells out to (`codesign`, `xcrun`, …). Restore a
# baseline PATH so the build can find them.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:${PATH:-}"
if XCODE_DEV="$(/usr/bin/xcode-select -p 2>/dev/null)"; then
    export PATH="$XCODE_DEV/usr/bin:$PATH"
fi

cd "$REPO_ROOT"

BUILD_LOG="$(mktemp -t muter-build.XXXXXX)"
trap 'rm -f "$BUILD_LOG"' EXIT
# Swift's diagnostics go to stdout, not stderr, so capture both.
if ! swift build -c debug --build-tests >"$BUILD_LOG" 2>&1; then
    if grep -q "ModuleCache" "$BUILD_LOG"; then
        # Drop only path-encoded build artifacts. Keep `.build/checkouts/`
        # and `.build/repositories/` so SwiftPM doesn't refetch deps —
        # that fails inside Muter's sandbox when the package cache is
        # busy or rate-limited.
        printf '==> %s\n' "stale ModuleCache detected (Muter project copy); clearing path-encoded .build subtrees" >&2
        rm -rf \
            .build/arm64-apple-macosx \
            .build/x86_64-apple-macosx \
            .build/debug \
            .build/release \
            .build/debug.yaml \
            .build/release.yaml \
            .build/index-build \
            .build/plugin-tools.yaml \
            .build/build.db \
            .build/artifacts
    else
        # Build failed for some other reason — surface the log and abort.
        cat "$BUILD_LOG" >&2
        exit 1
    fi
fi

# Cap each mutant's test run. Muter v16 ignores `testSuiteTimeout` in
# muter.conf.yml, and an infinite-loop mutant (e.g. swapping a relational
# operator inside a loop guard) will otherwise hang forever. Default 360s
# (six minutes) — comfortably above a clean ~3-minute pass on this repo.
# Override with TEST_FOR_MUTER_TIMEOUT=<seconds>. macOS lacks GNU
# `timeout`, so we implement one with perl + a fresh process group so
# SIGTERM reaches every descendant the test wrapper spawns.
TIMEOUT_SECS="${TEST_FOR_MUTER_TIMEOUT:-360}"

exec /usr/bin/perl -e '
    use POSIX qw(setpgid);
    my ($secs, @cmd) = @ARGV;
    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        setpgid(0, 0);
        exec { $cmd[0] } @cmd or die "exec: $!";
    }
    setpgid($pid, $pid);
    $SIG{ALRM} = sub {
        print STDERR "==> test command exceeded ${secs}s; killing process group $pid\n";
        kill "-TERM", $pid;
        sleep 5;
        kill "-KILL", $pid;
        waitpid($pid, 0);
        exit 124;
    };
    alarm $secs;
    waitpid($pid, 0);
    my $status = $?;
    exit ($status >> 8) || ($status & 127 ? 128 + ($status & 127) : 0);
' "$TIMEOUT_SECS" "$_SCRIPT_DIR/test.sh" "$@"
