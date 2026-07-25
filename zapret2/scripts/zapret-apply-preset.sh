#!/system/bin/sh
# One transaction for "switch the active preset". The app used to conduct the
# selection snapshot, the runtime.ini write, the restart, and the failure
# rollback over separate root round-trips, with the rollback decision seated
# in Kotlin. The module owns the whole mutation now and answers with one typed
# receipt, so a preset apply pays for exactly one shell initialization and the
# caller only projects the outcome.
#
# Receipt keys (stdout, alongside the replace transaction's own output):
#   Z2_APPLY_SCHEMA=1
#   Z2_APPLY_OUTCOME=applied|saved|rejected|io_failed|
#                    restart_failed_rolled_back|rollback_failed
#   Z2_APPLY_WAS_RUNNING=0|1
# plus the shared Z2_ERROR_* machine fields. Outcome semantics mirror the
# app's historical multi-step flow exactly, including the was-running check:
# a stopped service persists the selection without starting anything.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

REQUESTED_PRESET="${1:-}"
WAS_RUNNING=0
APPLY_BACKUP=""

emit_apply_receipt() {
    printf 'Z2_APPLY_SCHEMA=1\n'
    printf 'Z2_APPLY_OUTCOME=%s\n' "$1"
    printf 'Z2_APPLY_WAS_RUNNING=%s\n' "$WAS_RUNNING"
    z2_error_emit_machine
}

apply_succeed() { # outcome human-message
    rm -f "$APPLY_BACKUP" 2>/dev/null
    z2_error_clear
    emit_apply_receipt "$1"
    echo "$2"
    exit 0
}

apply_fail() { # outcome code detail
    # A failed rollback keeps the backup: those bytes are the only remaining
    # copy of the previous selection and belong to repair, not cleanup.
    [ "$1" = rollback_failed ] || rm -f "$APPLY_BACKUP" 2>/dev/null
    z2_error_set CONFIG "$2" APPLY_PRESET "$3" ||
        z2_error_set CONFIG CONFIG_INVALID APPLY_PRESET "preset apply failed"
    log_msg "ERROR: $3"
    emit_apply_receipt "$1"
    echo "ERROR: preset apply incomplete: $3"
    exit 1
}

# The active_preset gate below is byte-for-byte the one apply_core_config_key
# enforces, so a selection this transaction persists is one every later boot
# will accept.
requested_name_is_valid() {
    is_safe_runtime_file_name "$REQUESTED_PRESET" || return 1
    case "$REQUESTED_PRESET" in *.txt) ;; *) return 1 ;; esac
    case "$REQUESTED_PRESET" in _*) return 1 ;; esac
    return 0
}

main() {
    umask 077
    requested_name_is_valid ||
        apply_fail rejected CONFIG_INVALID "unsafe preset name"

    set_core_config_defaults
    load_effective_core_config ||
        apply_fail io_failed STATE_UNAVAILABLE "active runtime configuration is unreadable"
    [ -f "$RUNTIME_CONFIG" ] && [ ! -L "$RUNTIME_CONFIG" ] ||
        apply_fail io_failed STATE_UNAVAILABLE "runtime.ini is not an authoritative regular file"

    # A read-only liveness proof decides apply-versus-save exactly like the
    # app's historical isServiceRunning gate did.
    if read_verified_pidfile >/dev/null 2>&1; then WAS_RUNNING=1; fi

    ensure_state_tmp_dir ||
        apply_fail io_failed STATE_UNAVAILABLE "state scratch directory is unavailable"
    APPLY_BACKUP="$Z2_STATE_TMP/runtime.ini.apply.$$"
    state_path_is_managed_file "$APPLY_BACKUP" ||
        apply_fail io_failed STATE_UNAVAILABLE "unsafe selection backup path"
    rm -f "$APPLY_BACKUP" 2>/dev/null
    cp "$RUNTIME_CONFIG" "$APPLY_BACKUP" 2>/dev/null &&
        chmod 0600 "$APPLY_BACKUP" 2>/dev/null ||
        apply_fail io_failed STATE_UNAVAILABLE "cannot retain the previous selection"

    candidate="$Z2_STATE_TMP/runtime.ini.candidate.$$"
    rm -f "$candidate" 2>/dev/null
    awk -v new="$REQUESTED_PRESET" '
        /^active_preset=/ { print "active_preset=" new; replaced = 1; next }
        { print }
        END { if (!replaced) exit 1 }
    ' "$RUNTIME_CONFIG" > "$candidate" 2>/dev/null &&
        chmod 0600 "$candidate" 2>/dev/null || {
        rm -f "$candidate" 2>/dev/null
        apply_fail io_failed STATE_UNAVAILABLE "cannot stage the new selection"
    }
    if ! mv "$candidate" "$RUNTIME_CONFIG" 2>/dev/null; then
        rm -f "$candidate" 2>/dev/null
        apply_fail io_failed STATE_UNAVAILABLE "cannot publish the new selection"
    fi

    if [ "$WAS_RUNNING" = 0 ]; then
        apply_succeed saved "Preset saved: $REQUESTED_PRESET (service not running)"
    fi

    if sh "$SCRIPT_DIR/zapret-start.sh" --replace; then
        apply_succeed applied "Preset applied: $REQUESTED_PRESET"
    fi

    # The replace transaction rolled its own state back; this transaction still
    # owes the caller the previous selection bytes.
    if mv "$APPLY_BACKUP" "$RUNTIME_CONFIG" 2>/dev/null &&
       chmod 0600 "$RUNTIME_CONFIG" 2>/dev/null; then
        apply_fail restart_failed_rolled_back LIFECYCLE_FAILED \
            "replace transaction failed; previous selection restored"
    fi
    apply_fail rollback_failed LIFECYCLE_FAILED \
        "replace transaction failed and the previous selection could not be restored"
}

main "$@"
