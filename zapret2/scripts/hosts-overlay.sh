#!/system/bin/sh
# Systemless hosts publication for the DNS manager.
#
# The published file lives in /data and is bind-mounted over /system/etc/hosts
# by this module, so the DNS manager never mutates the live module tree. That
# matters for three reasons: a root manager that assembles /system from module
# directories (KernelSU metamodule/OverlayFS, Magisk magic mount) only reads
# those directories while it builds the mount, so a file dropped in afterwards
# is at best inert until the next boot; a second hosts module publishing the
# same path is a conflict this script can detect and yield to instead of
# silently racing it; and a module upgrade replaces the whole tree, which used
# to discard the user's DNS selection with it.
#
# The bind mount is also what makes an edit take effect immediately: --apply
# republishes the mount instead of asking the user to reboot.
#
# This runs from post-fs-data.sh, so it stays self-contained: no common.sh, no
# lifecycle state, and no dependency on anything the boot has not mounted yet.

HOSTS_OVERLAY_DIR="${HOSTS_OVERLAY_DIR:-/data/adb/zapret2-hosts}"
HOSTS_OVERLAY_FILE="$HOSTS_OVERLAY_DIR/hosts"
HOSTS_OVERLAY_BASE="$HOSTS_OVERLAY_DIR/system-hosts.base"
# device:inode of whatever this module mounted, written when the mount is
# published. An edit replaces the file by rename, so after one the live mount
# is our own previous inode and no longer matches the current file — this is
# what still proves the mount is ours and safe to release.
HOSTS_OVERLAY_MOUNT_ID="$HOSTS_OVERLAY_DIR/mounted.id"
SYSTEM_HOSTS="${SYSTEM_HOSTS:-/system/etc/hosts}"
MODULES_DIR="${MODULES_DIR:-/data/adb/modules}"
MODULE_ID="zapret2"
# The same envelope the app enforces before it hands content over.
HOSTS_MAX_BYTES=1048576
HOSTS_FILE_CONTEXT="u:object_r:system_file:s0"

HOSTS_STATE="absent"
HOSTS_CONFLICT="none"
HOSTS_DETAIL=""

hosts_log() {
    [ -x /system/bin/log ] || return 0
    /system/bin/log -t Zapret2 "[HOSTS] $1" 2>/dev/null || return 0
}

# A published hosts file must be an ordinary root-owned file with no second
# link, because the bind mount exposes whatever inode this path resolves to.
hosts_regular_root_file() {
    local path="$1" meta uid mode links size
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    meta="$(stat -c '%u:%a:%h:%s' "$path" 2>/dev/null)" || return 1
    uid="${meta%%:*}"; meta="${meta#*:}"
    mode="${meta%%:*}"; meta="${meta#*:}"
    links="${meta%%:*}"; size="${meta#*:}"
    [ "$uid" = 0 ] && [ "$links" = 1 ] || return 1
    case "$mode" in 600|644) ;; *) return 1 ;; esac
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    [ "$size" -le "$HOSTS_MAX_BYTES" ] 2>/dev/null
}

hosts_ensure_dir() {
    if [ -e "$HOSTS_OVERLAY_DIR" ] || [ -L "$HOSTS_OVERLAY_DIR" ]; then
        [ -d "$HOSTS_OVERLAY_DIR" ] && [ ! -L "$HOSTS_OVERLAY_DIR" ] &&
            [ "$(stat -c %u "$HOSTS_OVERLAY_DIR" 2>/dev/null)" = 0 ] ||
            return 1
    else
        mkdir -p "$HOSTS_OVERLAY_DIR" 2>/dev/null || return 1
    fi
    chmod 0755 "$HOSTS_OVERLAY_DIR" 2>/dev/null
}

# /proc/mounts is the only authority that answers "is something already
# mounted here" without depending on a mountpoint(1) that Android may not ship.
hosts_is_mounted() {
    local mounts=/proc/self/mounts target
    [ -r "$mounts" ] || mounts=/proc/mounts
    [ -r "$mounts" ] || return 1
    while read -r _ target _; do
        [ "$target" = "$SYSTEM_HOSTS" ] && return 0
    done < "$mounts"
    return 1
}

# Whoever is mounted there, only the inode decides whether it is ours. Another
# module's mount must survive everything this script does.
hosts_mount_is_ours() {
    local live source recorded
    hosts_is_mounted || return 1
    live="$(stat -c '%d:%i' "$SYSTEM_HOSTS" 2>/dev/null)" || return 1
    [ -n "$live" ] || return 1
    source="$(stat -c '%d:%i' "$HOSTS_OVERLAY_FILE" 2>/dev/null)" || source=""
    [ "$live" != "$source" ] || return 0
    # The published file was replaced since it was mounted. The receipt is only
    # consulted against a live mount, so a stale one cannot claim anything.
    recorded="$(cat "$HOSTS_OVERLAY_MOUNT_ID" 2>/dev/null)" || return 1
    [ -n "$recorded" ] && [ "$live" = "$recorded" ]
}

# Any other enabled module that publishes /system/etc/hosts owns the same file
# we would. Yielding keeps two modules from fighting over one path across
# reboots; whichever the user actually wants stays in charge.
hosts_find_conflicting_module() {
    local candidate module_id
    for candidate in "$MODULES_DIR"/*/system/etc/hosts; do
        [ -e "$candidate" ] || [ -L "$candidate" ] || continue
        module_id="${candidate#"$MODULES_DIR"/}"
        module_id="${module_id%%/*}"
        [ "$module_id" != "$MODULE_ID" ] || continue
        [ ! -f "$MODULES_DIR/$module_id/disable" ] || continue
        [ ! -f "$MODULES_DIR/$module_id/remove" ] || continue
        printf '%s\n' "$module_id"
        return 0
    done
    return 1
}

# Snapshot the untouched system hosts before this module covers it. The DNS
# manager merges its block into this base, and --clear restores exactly it.
# Only a boot that finds the path unmounted can see the real file, so a boot
# where another hosts module got there first must not overwrite the snapshot.
hosts_capture_base() {
    local tmp
    hosts_is_mounted && return 0
    [ -f "$SYSTEM_HOSTS" ] && [ ! -L "$SYSTEM_HOSTS" ] || return 0
    hosts_ensure_dir || return 1
    tmp="$HOSTS_OVERLAY_BASE.tmp.$$"
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
    cp "$SYSTEM_HOSTS" "$tmp" 2>/dev/null &&
        chmod 0644 "$tmp" 2>/dev/null &&
        hosts_regular_root_file "$tmp" &&
        mv -f "$tmp" "$HOSTS_OVERLAY_BASE" 2>/dev/null || {
            rm -f "$tmp" 2>/dev/null
            return 1
        }
}

# Releases only the mount this module published. A foreign mount is left
# exactly as it was found.
hosts_umount_ours() {
    local attempt=0
    while hosts_mount_is_ours; do
        attempt=$((attempt + 1))
        [ "$attempt" -le 8 ] || return 1
        umount "$SYSTEM_HOSTS" 2>/dev/null ||
            umount -l "$SYSTEM_HOSTS" 2>/dev/null ||
            return 1
    done
    rm -f "$HOSTS_OVERLAY_MOUNT_ID" 2>/dev/null
    return 0
}

# netd reads /system/etc/hosts and has no access to adb_data_file. A bind
# mount carries the source inode's label with it, so the label has to be
# corrected on the source before it is published, not after.
hosts_publish_mount() {
    hosts_regular_root_file "$HOSTS_OVERLAY_FILE" || {
        HOSTS_DETAIL="published hosts file is missing or unsafe"
        return 1
    }
    [ -f "$SYSTEM_HOSTS" ] && [ ! -L "$SYSTEM_HOSTS" ] || {
        HOSTS_DETAIL="system hosts path is not a regular file"
        return 1
    }
    chmod 0644 "$HOSTS_OVERLAY_FILE" 2>/dev/null || {
        HOSTS_DETAIL="cannot normalize published hosts permissions"
        return 1
    }
    if command -v chcon >/dev/null 2>&1; then
        chcon "$HOSTS_FILE_CONTEXT" "$HOSTS_OVERLAY_FILE" 2>/dev/null ||
            hosts_log "cannot relabel $HOSTS_OVERLAY_FILE; DNS resolution may ignore it"
    fi
    mount -o bind "$HOSTS_OVERLAY_FILE" "$SYSTEM_HOSTS" 2>/dev/null ||
        mount --bind "$HOSTS_OVERLAY_FILE" "$SYSTEM_HOSTS" 2>/dev/null || {
            HOSTS_DETAIL="bind mount over $SYSTEM_HOSTS was refused"
            return 1
        }
    hosts_record_mount_identity || {
        HOSTS_DETAIL="cannot record the published mount identity"
        return 1
    }
    hosts_mount_is_ours || {
        HOSTS_DETAIL="bind mount did not take effect"
        return 1
    }
    HOSTS_STATE="mounted"
    return 0
}

# Written after the mount and before anything can replace the file, so a later
# --apply can still recognize the mount it has to release.
hosts_record_mount_identity() {
    local identity tmp
    identity="$(stat -c '%d:%i' "$SYSTEM_HOSTS" 2>/dev/null)" || return 1
    [ -n "$identity" ] || return 1
    tmp="$HOSTS_OVERLAY_MOUNT_ID.tmp.$$"
    printf '%s' "$identity" > "$tmp" 2>/dev/null &&
        chmod 0644 "$tmp" 2>/dev/null &&
        mv -f "$tmp" "$HOSTS_OVERLAY_MOUNT_ID" 2>/dev/null || {
            rm -f "$tmp" 2>/dev/null
            return 1
        }
}

# Publication is one decision: keep an existing mount of ours, yield to
# another hosts publisher, mount nothing when the user published nothing, or
# take the path.
hosts_mount_if_published() {
    local conflict
    if hosts_mount_is_ours; then
        HOSTS_STATE="mounted"
        return 0
    fi
    if [ ! -e "$HOSTS_OVERLAY_FILE" ] && [ ! -L "$HOSTS_OVERLAY_FILE" ]; then
        HOSTS_STATE="absent"
        return 0
    fi
    conflict="$(hosts_find_conflicting_module)" || conflict=""
    if [ -z "$conflict" ] && hosts_is_mounted; then
        conflict="unknown"
    fi
    if [ -n "$conflict" ]; then
        HOSTS_STATE="conflict"
        HOSTS_CONFLICT="$conflict"
        hosts_log "another hosts publisher owns $SYSTEM_HOSTS ($conflict); zapret2 DNS entries were not mounted"
        return 0
    fi
    hosts_publish_mount || return 1
    hosts_log "published $HOSTS_OVERLAY_FILE over $SYSTEM_HOSTS"
    return 0
}

hosts_probe_state() {
    if hosts_mount_is_ours; then
        HOSTS_STATE="mounted"
    elif hosts_regular_root_file "$HOSTS_OVERLAY_FILE"; then
        HOSTS_STATE="published"
    else
        HOSTS_STATE="absent"
    fi
    if [ "$HOSTS_STATE" != mounted ]; then
        HOSTS_CONFLICT="$(hosts_find_conflicting_module)" || HOSTS_CONFLICT=""
        if [ -z "$HOSTS_CONFLICT" ] && [ "$HOSTS_STATE" = published ] && hosts_is_mounted; then
            HOSTS_CONFLICT="unknown"
        fi
        if [ -n "$HOSTS_CONFLICT" ]; then
            [ "$HOSTS_STATE" = absent ] || HOSTS_STATE="conflict"
        else
            HOSTS_CONFLICT="none"
        fi
    fi
}

hosts_emit_machine() {
    local digest="-" base_digest="-"
    if hosts_regular_root_file "$HOSTS_OVERLAY_FILE"; then
        digest="$(sha256sum "$HOSTS_OVERLAY_FILE" 2>/dev/null)" || digest=""
        digest="${digest%% *}"
        [ -n "$digest" ] || digest="-"
    fi
    if hosts_regular_root_file "$HOSTS_OVERLAY_BASE"; then
        base_digest="$(sha256sum "$HOSTS_OVERLAY_BASE" 2>/dev/null)" || base_digest=""
        base_digest="${base_digest%% *}"
        [ -n "$base_digest" ] || base_digest="-"
    fi
    printf 'Z2_HOSTS_SCHEMA\t1\n'
    printf 'Z2_HOSTS_STATE\t%s\n' "$HOSTS_STATE"
    printf 'Z2_HOSTS_CONFLICT\t%s\n' "$HOSTS_CONFLICT"
    printf 'Z2_HOSTS_FILE\t%s\n' "$HOSTS_OVERLAY_FILE"
    printf 'Z2_HOSTS_BASE\t%s\n' "$HOSTS_OVERLAY_BASE"
    printf 'Z2_HOSTS_SHA256\t%s\n' "$digest"
    printf 'Z2_HOSTS_BASE_SHA256\t%s\n' "$base_digest"
    printf 'Z2_HOSTS_DETAIL\t%s\n' "$HOSTS_DETAIL"
}

case "${1:---inspect-machine}" in
    --boot)
        # The snapshot has to happen while the real file is still visible, so
        # it comes before anything is mounted over it.
        #
        # Nothing here reaches into the module tree. Installations up to v2.2.5
        # kept the published file there, and customize.sh carries that content
        # over while the old tree still exists — which is the only moment it
        # does, since every supported root manager replaces the tree wholesale
        # on the activating boot. By the time this runs there is no old file
        # left to find, and looking for one would only be a path that never
        # executes in the field.
        hosts_capture_base || hosts_log "cannot snapshot $SYSTEM_HOSTS"
        hosts_mount_if_published || {
            hosts_log "ERROR: ${HOSTS_DETAIL:-hosts publication failed}"
            exit 1
        }
        exit 0
        ;;
    --apply)
        # An edit is published by atomic rename, which leaves the existing
        # bind mount pointing at the replaced inode. Republish so the change
        # is live now instead of at the next boot.
        hosts_umount_ours || {
            HOSTS_DETAIL="cannot release the previous hosts mount"
            hosts_probe_state
            hosts_emit_machine
            exit 1
        }
        hosts_mount_if_published || {
            hosts_emit_machine
            exit 1
        }
        hosts_emit_machine
        exit 0
        ;;
    --unmount)
        # Releases the mount and leaves the published file alone. The full
        # rollback needs exactly this between backing the file up and
        # unlinking it.
        hosts_umount_ours || {
            HOSTS_DETAIL="cannot release the hosts mount"
            hosts_probe_state
            hosts_emit_machine
            exit 1
        }
        hosts_probe_state
        hosts_emit_machine
        exit 0
        ;;
    --clear)
        hosts_umount_ours || {
            HOSTS_DETAIL="cannot release the hosts mount"
            hosts_probe_state
            hosts_emit_machine
            exit 1
        }
        if [ -e "$HOSTS_OVERLAY_FILE" ] || [ -L "$HOSTS_OVERLAY_FILE" ]; then
            rm -f "$HOSTS_OVERLAY_FILE" 2>/dev/null || {
                HOSTS_DETAIL="cannot remove the published hosts file"
                hosts_probe_state
                hosts_emit_machine
                exit 1
            }
        fi
        hosts_probe_state
        hosts_emit_machine
        exit 0
        ;;
    --inspect-machine)
        hosts_probe_state
        hosts_emit_machine
        exit 0
        ;;
    *)
        echo "ERROR: usage: hosts-overlay.sh [--boot|--apply|--unmount|--clear|--inspect-machine]" >&2
        exit 2
        ;;
esac
