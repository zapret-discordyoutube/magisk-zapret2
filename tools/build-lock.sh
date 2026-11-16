# shellcheck shell=sh
# One build at a time on this machine (owner decision 2026-11-16).
#
# On 2026-11-15 two parallel Gradle builds in the build container loaded the
# host disks so much that a neighbouring virtual machine froze. Every build
# entry point (build.sh, build-local-release.sh) calls zapret2_build_lock
# first, so a second build waits here instead of running alongside the first.
#
# ZAPRET2_BUILD_LOCK_FILE  lock file (default /run/lock/magisk-zapret2-build.lock,
#                          or /tmp/... where /run/lock is not writable)
# ZAPRET2_BUILD_LOCK_WAIT  seconds to wait for the running build (default 5400)
# ZAPRET2_BUILD_LOCK_HELD  set to 1 by the build that holds the lock, for the
#                          builds it starts itself (they must not wait for it)
#
# The lock lives on file descriptor 9 until the build process exits.

zapret2_build_lock() {
    if [ "${ZAPRET2_BUILD_LOCK_HELD:-}" = 1 ]; then
        return 0
    fi
    if ! command -v flock >/dev/null 2>&1; then
        printf 'WARNING: flock is unavailable; this build does not wait for other builds\n' >&2
        return 0
    fi
    if [ -n "${ZAPRET2_BUILD_LOCK_FILE:-}" ]; then
        zapret2_lock_file=$ZAPRET2_BUILD_LOCK_FILE
    elif [ -d /run/lock ] && [ -w /run/lock ]; then
        zapret2_lock_file=/run/lock/magisk-zapret2-build.lock
    else
        zapret2_lock_file=/tmp/magisk-zapret2-build.lock
    fi
    zapret2_lock_wait=${ZAPRET2_BUILD_LOCK_WAIT:-5400}
    if [ ! -e "$zapret2_lock_file" ]; then
        (umask 000 && : >>"$zapret2_lock_file") 2>/dev/null || true
    fi
    # Opened read-only: in a sticky shared directory a file of another user
    # cannot be reopened for writing (fs.protected_regular), and flock works
    # on a read-only descriptor as well.
    if ! { exec 9<"$zapret2_lock_file"; } 2>/dev/null; then
        printf 'ERROR: cannot open the build lock %s\n' "$zapret2_lock_file" >&2
        return 1
    fi
    if ! flock -n 9; then
        printf 'Another build is running on this machine; waiting up to %s s for it to finish...\n' \
            "$zapret2_lock_wait" >&2
        if ! flock -w "$zapret2_lock_wait" 9; then
            exec 9<&-
            printf 'ERROR: the other build still runs after %s s; not starting a second one\n' \
                "$zapret2_lock_wait" >&2
            return 1
        fi
    fi
    ZAPRET2_BUILD_LOCK_HELD=1
    export ZAPRET2_BUILD_LOCK_HELD
}
