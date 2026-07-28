#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/zapret2/scripts/hosts-overlay.sh"
POST_FS_DATA="$ROOT/post-fs-data.sh"

fail() { echo "FAIL: hosts-overlay: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "missing fragment in $1: $2"; }

[ -f "$SCRIPT" ] && [ ! -L "$SCRIPT" ] && [ -x "$SCRIPT" ] ||
    fail "hosts-overlay.sh is not a regular executable"
[ -f "$POST_FS_DATA" ] && [ ! -L "$POST_FS_DATA" ] && [ -x "$POST_FS_DATA" ] ||
    fail "post-fs-data.sh is not a regular executable"
[ "$(sed -n '1p' "$SCRIPT")" = '#!/system/bin/sh' ] || fail "hosts-overlay shebang"
[ "$(sed -n '1p' "$POST_FS_DATA")" = '#!/system/bin/sh' ] || fail "post-fs-data shebang"

# The boot entry point is the only thing that may publish at boot, and it must
# never fail the stage it blocks.
assert_contains "$POST_FS_DATA" 'hosts-overlay.sh'
assert_contains "$POST_FS_DATA" '--boot'
assert_contains "$POST_FS_DATA" '|| exit 0'

# Everything below publishes root-owned files and asks the script to accept
# them, which is exactly what it refuses to do for anything else. Without uid 0
# the scenarios cannot be set up at all, so say so rather than assert nothing.
if [ "$(id -u)" != 0 ]; then
    echo "hosts-overlay: OK (static checks only; scenarios need uid 0)"
    exit 0
fi

if [ -n "${Z2_TEST_WORKDIR:-}" ]; then
    TMP="$Z2_TEST_WORKDIR/hosts-overlay"
    mkdir -p "$TMP"
else
    TMP=$(mktemp -d "${Z2_TEST_TMP:-${TMPDIR:-/tmp}}/zapret2-hosts.XXXXXX")
fi
# A failed assertion between mount and umount must not leave the fixture
# mounted, whichever branch created the workdir.
cleanup_fixture() {
    cleanup_attempt=0
    while [ "$cleanup_attempt" -lt 8 ] && umount "$TMP/system-hosts" 2>/dev/null; do
        cleanup_attempt=$((cleanup_attempt + 1))
    done
    [ -n "${Z2_TEST_WORKDIR:-}" ] || rm -rf "$TMP" 2>/dev/null || :
}
trap cleanup_fixture EXIT HUP INT TERM

SYSTEM_HOSTS="$TMP/system-hosts"
OVERLAY_DIR="$TMP/zapret2-hosts"
MODULES_DIR="$TMP/modules"
mkdir -p "$MODULES_DIR/zapret2"

run_overlay() {
    HOSTS_OVERLAY_DIR="$OVERLAY_DIR" SYSTEM_HOSTS="$SYSTEM_HOSTS" \
        MODULES_DIR="$MODULES_DIR" sh "$SCRIPT" "$@"
}

machine_field() {
    printf '%s\n' "$2" | awk -F'\t' -v key="$1" '$1 == key { print $2 }'
}

reset_fixture() {
    # A scenario that published a mount owns the system path until it is
    # released; removing the fixture underneath it would fail on a busy inode.
    reset_attempt=0
    while [ "$reset_attempt" -lt 8 ] && umount "$SYSTEM_HOSTS" 2>/dev/null; do
        reset_attempt=$((reset_attempt + 1))
    done
    rm -rf "$OVERLAY_DIR" "$MODULES_DIR" "$SYSTEM_HOSTS"
    mkdir -p "$MODULES_DIR/zapret2"
    printf '127.0.0.1\tlocalhost\n' > "$SYSTEM_HOSTS"
}

# --- nothing published: a boot must stay a no-op that still captures the base ---
reset_fixture
run_overlay --boot || fail "boot failed with nothing published"
[ -f "$OVERLAY_DIR/system-hosts.base" ] || fail "boot did not capture the system baseline"
cmp -s "$OVERLAY_DIR/system-hosts.base" "$SYSTEM_HOSTS" ||
    fail "captured baseline does not match the system hosts file"
state=$(machine_field Z2_HOSTS_STATE "$(run_overlay --inspect-machine)")
[ "$state" = absent ] || fail "expected absent with nothing published, got $state"

# --- boot never writes into the module's own tree ---
# The installer carries a pre-2.3.0 in-tree overlay across while the old tree
# still exists, and every supported root manager replaces that tree wholesale
# on the activating boot. So this stage has no business reaching into it, and a
# file that is somehow there is left for the manager that owns it.
reset_fixture
mkdir -p "$MODULES_DIR/zapret2/system/etc"
printf '127.0.0.1\tlocalhost\n0.0.0.0\tlegacy.test\n' > "$MODULES_DIR/zapret2/system/etc/hosts"
tree_before=$(find "$MODULES_DIR/zapret2" | sort)
run_overlay --boot >/dev/null 2>&1 || :
[ "$(find "$MODULES_DIR/zapret2" | sort)" = "$tree_before" ] ||
    fail "boot mutated the module tree"
grep -Fq 'legacy.test' "$MODULES_DIR/zapret2/system/etc/hosts" ||
    fail "boot rewrote a file inside the module tree"
[ ! -e "$OVERLAY_DIR/hosts" ] ||
    fail "boot published content it found in the module tree"

# --- another enabled module owning the same path is a conflict, not a race ---
reset_fixture
printf '127.0.0.1\tlocalhost\n0.0.0.0\tblocked.test\n' > "$OVERLAY_DIR-staging" 2>/dev/null || :
mkdir -p "$OVERLAY_DIR"
printf '127.0.0.1\tlocalhost\n0.0.0.0\tblocked.test\n' > "$OVERLAY_DIR/hosts"
chmod 0644 "$OVERLAY_DIR/hosts"
mkdir -p "$MODULES_DIR/bindhosts/system/etc"
: > "$MODULES_DIR/bindhosts/system/etc/hosts"
output=$(run_overlay --inspect-machine)
[ "$(machine_field Z2_HOSTS_STATE "$output")" = conflict ] ||
    fail "a foreign hosts module was not reported as a conflict"
[ "$(machine_field Z2_HOSTS_CONFLICT "$output")" = bindhosts ] ||
    fail "the conflicting module was not named"

# --- a disabled foreign module owns nothing ---
: > "$MODULES_DIR/bindhosts/disable"
output=$(run_overlay --inspect-machine)
[ "$(machine_field Z2_HOSTS_STATE "$output")" = published ] ||
    fail "a disabled foreign module still counted as a conflict"
rm -f "$MODULES_DIR/bindhosts/disable"

# --- clear removes the publication ---
rm -rf "$MODULES_DIR/bindhosts"
run_overlay --clear >/dev/null || fail "clear failed"
[ ! -e "$OVERLAY_DIR/hosts" ] || fail "clear left the published file behind"

# --- an unsafe publication is never mounted ---
reset_fixture
mkdir -p "$OVERLAY_DIR"
ln -s /etc/passwd "$OVERLAY_DIR/hosts"
if run_overlay --boot >/dev/null 2>&1; then fail "a symlinked publication was accepted"; fi
[ "$(machine_field Z2_HOSTS_STATE "$(run_overlay --inspect-machine)")" = absent ] ||
    fail "a symlinked publication was not rejected by inspection"
rm -f "$OVERLAY_DIR/hosts"

# --- the mount itself, where the kernel allows one ---
reset_fixture
mkdir -p "$OVERLAY_DIR"
printf '127.0.0.1\tlocalhost\n0.0.0.0\tmounted.test\n' > "$OVERLAY_DIR/hosts"
chmod 0644 "$OVERLAY_DIR/hosts"
if [ "$(id -u)" = 0 ] && mount -o bind "$SYSTEM_HOSTS" "$SYSTEM_HOSTS" 2>/dev/null; then
    umount "$SYSTEM_HOSTS" 2>/dev/null || umount -l "$SYSTEM_HOSTS" 2>/dev/null || :
    run_overlay --boot || fail "boot did not publish the mount"
    grep -Fq 'mounted.test' "$SYSTEM_HOSTS" || fail "the published file is not visible at the system path"
    [ "$(machine_field Z2_HOSTS_STATE "$(run_overlay --inspect-machine)")" = mounted ] ||
        fail "a live mount was not reported as mounted"

    # An atomic rename leaves the mount on the replaced inode; --apply is what
    # makes the edit live without a reboot.
    printf '127.0.0.1\tlocalhost\n0.0.0.0\tsecond.test\n' > "$OVERLAY_DIR/hosts.tmp"
    chmod 0644 "$OVERLAY_DIR/hosts.tmp"
    mv -f "$OVERLAY_DIR/hosts.tmp" "$OVERLAY_DIR/hosts"
    grep -Fq 'mounted.test' "$SYSTEM_HOSTS" ||
        fail "the stale mount unexpectedly followed the rename"
    run_overlay --apply >/dev/null || fail "apply failed"
    grep -Fq 'second.test' "$SYSTEM_HOSTS" || fail "apply did not republish the edit"

    run_overlay --clear >/dev/null || fail "clear failed while mounted"
    grep -Fq 'localhost' "$SYSTEM_HOSTS" || fail "clear did not restore the system path"
    if grep -Fq 'second.test' "$SYSTEM_HOSTS"; then fail "clear left the publication mounted"; fi
else
    echo "hosts-overlay: skipping mount assertions (no bind-mount capability)"
fi

echo "hosts-overlay: OK"
