#!/usr/bin/env bash
# Behaviour of tools/build-lock.sh: a second build waits, then gives up;
# builds started by the lock holder pass; the lock frees when the build exits.
set -euo pipefail

ROOT="$(cd -- "${1:-$(dirname "$0")/../..}" && pwd -P)"
HELPER="$ROOT/tools/build-lock.sh"

fail() {
    printf 'build-lock test: %s\n' "$*" >&2
    exit 1
}

[[ -f "$HELPER" && ! -L "$HELPER" ]] || fail "tools/build-lock.sh is missing"
command -v flock >/dev/null 2>&1 || {
    printf 'build-lock test: skipped (flock is unavailable)\n'
    exit 0
}
for entry in build.sh .codex/skills/build-zapret2-locally/scripts/build-local-release.sh; do
    grep -Fq 'zapret2_build_lock' "$ROOT/$entry" ||
        fail "$entry does not take the one-build lock"
done
grep -Fq 'sudo env ZAPRET2_BUILD_LOCK_HELD=1 bash -c' \
    "$ROOT/.codex/skills/build-zapret2-locally/scripts/build-local-release.sh" ||
    fail "the release builder would wait for its own lock in build.sh"

TMP="$(mktemp -d)"
holder=""
cleanup() {
    if [[ -n "$holder" ]]; then kill "$holder" 2>/dev/null || true; fi
    rm -rf "$TMP"
}
trap cleanup EXIT
export ZAPRET2_BUILD_LOCK_FILE="$TMP/build.lock"
unset ZAPRET2_BUILD_LOCK_HELD

take_lock() {
    bash -c '. "$1"; zapret2_build_lock' _ "$HELPER"
}

take_lock || fail "a free lock was not taken"
# The holder keeps running after its child (the trailing exit stops bash
# from exec-ing the child in its place and handing the lock over).
bash -c '. "$1"; zapret2_build_lock || exit 1
    ZAPRET2_BUILD_LOCK_WAIT=1 bash -c ". \"\$1\"; zapret2_build_lock" _ "$1"
    rc=$?; exit "$rc"' _ "$HELPER" ||
    fail "a child build of the lock holder waited for its own lock"

# One process that owns the lock itself, so killing it frees the lock
# (`flock FILE sleep` would leave the sleeping child holding it).
bash -c 'exec 9<"$1"; flock 9; exec sleep 30' _ "$ZAPRET2_BUILD_LOCK_FILE" &
holder=$!
for _ in $(seq 50); do
    flock -n "$ZAPRET2_BUILD_LOCK_FILE" true 2>/dev/null || break
    sleep 0.1
done

if ZAPRET2_BUILD_LOCK_WAIT=1 take_lock 2>"$TMP/err"; then
    fail "a second build started while another one held the lock"
fi
grep -Fq 'not starting a second one' "$TMP/err" || fail "the refusal does not say why"

ZAPRET2_BUILD_LOCK_HELD=1 ZAPRET2_BUILD_LOCK_WAIT=1 take_lock ||
    fail "a build started by the lock holder waited for its own lock"

kill "$holder"
wait "$holder" 2>/dev/null || true
holder=""
ZAPRET2_BUILD_LOCK_WAIT=5 take_lock || fail "the lock did not free when the holder exited"

printf 'build-lock contract: passed\n'
