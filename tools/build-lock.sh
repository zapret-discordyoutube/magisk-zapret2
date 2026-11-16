# shellcheck shell=bash
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
#
# Where the machine provides `us2-build-lock` (CT 210 on US2-7), the build also
# takes the server-wide lock it shares with the Android CI jobs of the Forgejo
# runner (CT 206): heavy builds of both containers use the same disks. Without
# that command (CI, other machines) only this machine's lock applies; when the
# runner cannot be reached, the build warns and goes on with the local lock.

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
    if [ -n "${BASH_VERSION:-}" ] && command -v us2-build-lock >/dev/null 2>&1; then
        zapret2_shared_build_lock || { exec 9<&-; return 1; }
    fi
    ZAPRET2_BUILD_LOCK_HELD=1
    export ZAPRET2_BUILD_LOCK_HELD
}

# Server-wide lock (us2-build-lock hold): held by a helper process while this
# build process ($$) lives; its answers arrive line by line.
zapret2_shared_build_lock() {
    local state rest
    # fd 9 (this machine's lock) is closed in the helper: it must not keep the
    # local lock after the build itself has exited.
    coproc ZAPRET2_US2_LOCK {
        exec 9<&-
        US2_BUILD_LOCK_WAIT=${ZAPRET2_BUILD_LOCK_WAIT:-5400} \
            us2-build-lock hold "$$" "magisk-zapret2-$(basename "$0")-$$"
    }
    state=""
    while IFS=' ' read -r state rest <&"${ZAPRET2_US2_LOCK[0]}"; do
        case "$state" in
            WAIT)
                printf 'Another heavy build on this server is running (%s); waiting up to %s s...\n' \
                    "${rest:-?}" "${ZAPRET2_BUILD_LOCK_WAIT:-5400}" >&2 ;;
            HELD) return 0 ;;
            TIMEOUT)
                printf 'ERROR: the other build on this server still runs after %s s; not starting a second one\n' \
                    "${ZAPRET2_BUILD_LOCK_WAIT:-5400}" >&2
                return 1 ;;
            *) break ;;
        esac
    done
    printf 'WARNING: the server-wide build lock is unavailable (%s); only this machine waits for other builds\n' \
        "${state:+$state }${rest:-no answer}" >&2
    return 0
}
