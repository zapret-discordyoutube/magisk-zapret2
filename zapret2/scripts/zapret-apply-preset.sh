#!/system/bin/sh
# One module-owned transaction that applies a preset selection end to end.
#
# Selecting a preset used to be orchestrated from the Android app as four to six
# privileged round trips: snapshot runtime.ini, observe the service, read/stage/
# commit runtime.ini, then restart, with the rollback decisions living in Kotlin.
# Every one of those trips paid a libsu round trip plus a full common.sh
# sourcing, which is the most expensive thing a script can do on Android.
#
# The module owns that mutation here. One entry point validates the request,
# persists the selection, runs the existing replacement transaction, and reports
# a single typed outcome. The app projects that payload; it never rebuilds the
# steps, and it never decides on its own what the module's state is.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZAPRET_DIR="$(dirname "$SCRIPT_DIR")"
MODDIR="$(dirname "$ZAPRET_DIR")"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/command-builder.sh"

set -f

APPLY_SCHEMA_VERSION=1
APPLY_OUTCOME=IO_FAILED
APPLY_ISSUE=NONE
APPLY_REQUESTED_PRESET=""
APPLY_PREVIOUS_PRESET=""
APPLY_CONFIG_COMMITTED=0
APPLY_SERVICE_WAS_RUNNING=0
APPLY_LOCK_TAKEN=0
APPLY_NONCE=""
RUNTIME_CANONICAL_TEXT=""
RUNTIME_NEXT_TEXT=""
RUNTIME_ACTIVE_PRESET_LINES=0
RUNTIME_PREVIOUS_DIGEST=""
RUNTIME_NEXT_DIGEST=""
RUNTIME_CANONICAL_DIGEST=""
APPLY_PUBLISHED_GENERATION=unknown
CHILD_ERROR_STATUS=""
CHILD_ERROR_DOMAIN=""
CHILD_ERROR_CODE=""
CHILD_ERROR_STAGE=""
CHILD_ERROR_DETAIL=""

log_msg() {
    append_lifecycle_log "$(date '+%Y-%m-%d %H:%M:%S') [APPLY] $1"
}

# The payload is the whole report: an outcome the app maps onto one typed
# mutation result, plus the shared Z2_ERROR envelope carrying the exact failure
# identity of whichever stage refused. The terminal sentinel lets a strict
# caller reject truncated shell output instead of guessing.
emit_apply_machine() {
    printf 'Z2_APPLY_SCHEMA=%s\n' "$APPLY_SCHEMA_VERSION"
    printf 'Z2_APPLY_OUTCOME=%s\n' "$APPLY_OUTCOME"
    printf 'Z2_APPLY_ISSUE=%s\n' "$APPLY_ISSUE"
    printf 'Z2_APPLY_PRESET=%s\n' "$APPLY_REQUESTED_PRESET"
    printf 'Z2_APPLY_PREVIOUS_PRESET=%s\n' "$APPLY_PREVIOUS_PRESET"
    printf 'Z2_APPLY_CONFIG_COMMITTED=%s\n' "$APPLY_CONFIG_COMMITTED"
    printf 'Z2_APPLY_SERVICE_WAS_RUNNING=%s\n' "$APPLY_SERVICE_WAS_RUNNING"
    z2_error_emit_machine || return 1
    printf 'Z2_APPLY_COMPLETE=1\n'
}

apply_release_lock() {
    [ "$APPLY_LOCK_TAKEN" = 1 ] || return 0
    release_lifecycle_lock || return 1
    APPLY_LOCK_TAKEN=0
    return 0
}

apply_report_failure() {
    local domain="$1" code="$2" stage="$3" detail="$4" outcome="$5" issue="${6:-NONE}"
    APPLY_OUTCOME="$outcome"
    APPLY_ISSUE="$issue"
    if ! apply_release_lock; then
        detail="$detail; lifecycle ownership release failed"
    fi
    z2_error_set "$domain" "$code" "$stage" "$detail" ||
        z2_error_set LIFECYCLE LIFECYCLE_FAILED APPLY "$detail" ||
        z2_error_set LIFECYCLE LIFECYCLE_FAILED APPLY "preset application failed"
    log_msg "ERROR: $detail"
    emit_apply_machine
    exit 1
}

# A committed transaction whose lock release fails is deliberately reported with
# an ERROR envelope on a committed outcome: the selection is live, but the
# lifecycle is now fenced, so no caller may read this as an ordinary success.
# The app never reaches it, because an inherited Android lease is released by
# the app that owns it and this release is then a no-op.
apply_report_success() {
    APPLY_OUTCOME="$1"
    APPLY_ISSUE=NONE
    if ! apply_release_lock; then
        z2_error_set LIFECYCLE LIFECYCLE_FAILED APPLY_LOCK_RELEASE \
            "preset application committed but lifecycle ownership release failed" ||
            z2_error_set LIFECYCLE LIFECYCLE_FAILED APPLY_LOCK_RELEASE \
                "lifecycle ownership release failed"
        emit_apply_machine
        exit 1
    fi
    z2_error_clear
    emit_apply_machine
    exit 0
}

apply_interrupted() {
    local signal="$1"
    trap '' HUP INT TERM
    if [ "$APPLY_CONFIG_COMMITTED" = 1 ]; then
        if rollback_runtime_config; then
            apply_report_failure LIFECYCLE LIFECYCLE_FAILED APPLY_SIGNAL \
                "preset application interrupted by $signal; the previous selection was restored" \
                RESTART_FAILED_ROLLED_BACK
        fi
        apply_report_failure LIFECYCLE LIFECYCLE_FAILED APPLY_SIGNAL \
            "preset application interrupted by $signal and the previous selection could not be restored" \
            ROLLBACK_FAILED
    fi
    apply_report_failure LIFECYCLE LIFECYCLE_FAILED APPLY_SIGNAL \
        "preset application interrupted by $signal before any change" IO_FAILED
}

# Adopt the exact typed identity a nested module transaction published instead
# of flattening it into free text. The outcome says what this transaction did
# about the failure; the envelope says what actually refused.
parse_typed_error_envelope() {
    local text="$1" line old_ifs
    CHILD_ERROR_STATUS=""; CHILD_ERROR_DOMAIN=""; CHILD_ERROR_CODE=""
    CHILD_ERROR_STAGE=""; CHILD_ERROR_DETAIL=""
    old_ifs="$IFS"
    IFS='
'
    set -- $text
    IFS="$old_ifs"
    for line in "$@"; do
        case "$line" in
            Z2_ERROR_STATUS=*) CHILD_ERROR_STATUS="${line#Z2_ERROR_STATUS=}" ;;
            Z2_ERROR_DOMAIN=*) CHILD_ERROR_DOMAIN="${line#Z2_ERROR_DOMAIN=}" ;;
            Z2_ERROR_CODE=*) CHILD_ERROR_CODE="${line#Z2_ERROR_CODE=}" ;;
            Z2_ERROR_STAGE=*) CHILD_ERROR_STAGE="${line#Z2_ERROR_STAGE=}" ;;
            Z2_ERROR_DETAIL=*) CHILD_ERROR_DETAIL="${line#Z2_ERROR_DETAIL=}" ;;
        esac
    done
    [ "$CHILD_ERROR_STATUS" = ERROR ] || return 1
    z2_error_fields_are_valid ERROR "$CHILD_ERROR_DOMAIN" "$CHILD_ERROR_STAGE" \
        "$CHILD_ERROR_CODE" "$CHILD_ERROR_DETAIL"
}

# Mirrors runtime-config.sh's canonical runtime identity: CR stripped from each
# line, trailing empty lines dropped, exactly one LF per surviving line. The
# commit boundary computes the same identity from the published file, so any
# divergence fails the compare-and-swap closed instead of publishing a wrong
# generation. tests/shell/preset-apply-transaction.sh pins the two together.
runtime_canonical_digest() {
    local digest
    command -v sha256sum >/dev/null 2>&1 || return 1
    digest="$(printf '%s' "$1" | sha256sum 2>/dev/null)" || return 1
    digest="${digest%% *}"
    is_lower_sha256 "$digest" || return 1
    RUNTIME_CANONICAL_DIGEST="$digest"
    return 0
}

# One bounded pass produces both the canonical current content and the exact
# candidate content, so the previous generation is buffered for rollback before
# anything is staged and neither form needs a second read of the file.
read_runtime_generations() {
    local path="$1" requested="$2" line stripped trimmed key section="" pending="" cr
    RUNTIME_CANONICAL_TEXT=""
    RUNTIME_NEXT_TEXT=""
    RUNTIME_ACTIVE_PRESET_LINES=0
    [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || return 1
    path_uid_is_root "$path" && path_nlink_is_one "$path" || return 1
    cr="$(printf '\r')"
    while IFS= read -r line || [ -n "$line" ]; do
        stripped="${line%"$cr"}"
        if [ -z "$stripped" ]; then
            pending="$pending
"
            continue
        fi
        RUNTIME_CANONICAL_TEXT="$RUNTIME_CANONICAL_TEXT$pending$stripped
"
        trim_config_value_in_place "$stripped"
        trimmed="$CONFIG_VALUE_TRIMMED"
        case "$trimmed" in
            "["*"]")
                section="${trimmed#[}"
                section="${section%]}"
                ;;
            *=*)
                if [ "$section" = core ]; then
                    trim_config_value_in_place "${trimmed%%=*}"
                    key="$CONFIG_VALUE_TRIMMED"
                    if [ "$key" = active_preset ]; then
                        RUNTIME_ACTIVE_PRESET_LINES=$((RUNTIME_ACTIVE_PRESET_LINES + 1))
                        RUNTIME_NEXT_TEXT="$RUNTIME_NEXT_TEXT${pending}active_preset=$requested
"
                        pending=""
                        continue
                    fi
                fi
                ;;
        esac
        RUNTIME_NEXT_TEXT="$RUNTIME_NEXT_TEXT$pending$stripped
"
        pending=""
    done < "$path"
    [ -n "$RUNTIME_CANONICAL_TEXT" ]
}

stage_runtime_candidate() {
    local content="$1" path="$2"
    case "$path" in "$RUNTIME_CONFIG.candidate.$$."*) ;; *) return 1 ;; esac
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
    umask 077
    printf '%s' "$content" > "$path" || { rm -f "$path" 2>/dev/null; return 1; }
    chmod 0644 "$path" 2>/dev/null || { rm -f "$path" 2>/dev/null; return 1; }
    return 0
}

# runtime-config.sh owns runtime.ini publication for every caller, including
# this one: the candidate identity policy, the stale-candidate sweep, the
# compare-and-swap against the expected content, the full core revalidation and
# the durability barrier live there and are not duplicated here.
commit_runtime_candidate() {
    local content="$1" expected="$2" step="$3" candidate output rc=0
    candidate="$RUNTIME_CONFIG.candidate.$$.$APPLY_NONCE$step"
    stage_runtime_candidate "$content" "$candidate" || return 1
    output="$(ZAPRET2_EMIT_STATUS_V6=0 sh "$SCRIPT_DIR/runtime-config.sh" \
        --commit-candidate "$candidate" "$expected" "$RUNTIME_CONFIG" 2>&1)" || rc=$?
    rm -f "$candidate" 2>/dev/null
    [ "$rc" -eq 0 ] || {
        parse_typed_error_envelope "$output" || {
            CHILD_ERROR_DOMAIN=CONFIG
            CHILD_ERROR_CODE=RUNTIME_COMMIT_FAILED
            CHILD_ERROR_STAGE=RUNTIME_COMMIT
            CHILD_ERROR_DETAIL="runtime.ini commit failed without a typed envelope"
        }
        return 1
    }
    return 0
}

# A failed commit is not automatically a clean refusal: the publication rename
# can succeed and a later step of the same commit still fail. Re-derive the
# published identity and answer from evidence instead of assuming either way.
# The buffered previous generation is the only copy rollback has, so it is
# restored around the probe rather than overwritten by it.
classify_published_runtime() {
    local saved_canonical="$RUNTIME_CANONICAL_TEXT" saved_next="$RUNTIME_NEXT_TEXT"
    local saved_lines="$RUNTIME_ACTIVE_PRESET_LINES"
    APPLY_PUBLISHED_GENERATION=unknown
    if read_runtime_generations "$RUNTIME_CONFIG" "$APPLY_REQUESTED_PRESET" &&
       runtime_canonical_digest "$RUNTIME_CANONICAL_TEXT"; then
        if [ "$RUNTIME_CANONICAL_DIGEST" = "$RUNTIME_PREVIOUS_DIGEST" ]; then
            APPLY_PUBLISHED_GENERATION=previous
        elif [ -n "$RUNTIME_NEXT_DIGEST" ] &&
             [ "$RUNTIME_CANONICAL_DIGEST" = "$RUNTIME_NEXT_DIGEST" ]; then
            APPLY_PUBLISHED_GENERATION=requested
        fi
    fi
    RUNTIME_CANONICAL_TEXT="$saved_canonical"
    RUNTIME_NEXT_TEXT="$saved_next"
    RUNTIME_ACTIVE_PRESET_LINES="$saved_lines"
    return 0
}

rollback_runtime_config() {
    [ "$APPLY_CONFIG_COMMITTED" = 1 ] || return 0
    [ -n "$RUNTIME_NEXT_DIGEST" ] && [ -n "$RUNTIME_CANONICAL_TEXT" ] || return 1
    commit_runtime_candidate "$RUNTIME_CANONICAL_TEXT" "$RUNTIME_NEXT_DIGEST" 2 || return 1
    APPLY_CONFIG_COMMITTED=0
    return 0
}

# The same compatibility qualification the app used to request through
# command-builder.sh --preflight-preset-machine, run in this process against a
# disposable artifact. It happens before runtime.ini is touched, so an
# incompatible preset is refused with the live selection untouched instead of
# being written, failed and rolled back.
validate_requested_preset() {
    local artifact rc=0
    PRESET_VALIDATION_CODE=OK
    ensure_state_tmp_dir || {
        PRESET_VALIDATION_CODE=PRESET_UNREADABLE
        return 1
    }
    artifact="$Z2_STATE_TMP/preset-apply.$$"
    state_file_target_is_safe "$artifact" || {
        PRESET_VALIDATION_CODE=PRESET_UNREADABLE
        return 1
    }
    rm -f "$artifact" 2>/dev/null
    if compile_preset_artifact "$PRESETS_DIR/$APPLY_REQUESTED_PRESET" \
        "$APPLY_REQUESTED_PRESET" "$artifact" &&
        run_compiled_artifact "$artifact" dry-run >/dev/null 2>&1; then
        rm -f "$artifact" 2>/dev/null
        return 0
    fi
    rc=1
    [ "$PRESET_VALIDATION_CODE" != OK ] || PRESET_VALIDATION_CODE=NFQWS_DRY_RUN_FAILED
    rm -f "$artifact" 2>/dev/null
    return "$rc"
}

# The app's "was the service running" question, answered from the committed
# lifecycle receipt exactly as zapret-status.sh derives Z2_PROCESS: the last
# transaction published a healthy generation and its exact process identity is
# still live. Read-only and constant in the size of the package and the process
# table; this transaction never re-audits the firewall to answer it.
service_process_is_running() {
    state_dir_is_secure || return 1
    OBSERVER_STATE_DIR_VERIFIED=1
    read_iptables_status >/dev/null 2>&1 || return 1
    [ "$STATUS_FILE_STATUS" = ok ] || return 1
    [ "$STATUS_FILE_OWNER_METADATA_VERIFIED" = 1 ] || return 1
    [ "$STATUS_FILE_RULESET_VERIFIED" = 1 ] || return 1
    [ "$STATUS_FILE_IPV4_ACTIVE" = 1 ] || return 1
    [ "$STATUS_FILE_RULES_TOTAL" = "$((STATUS_FILE_IPV4_RULES + STATUS_FILE_IPV6_RULES))" ] || return 1
    [ "$STATUS_FILE_RULES_TOTAL" = "$STATUS_FILE_RULES_EXPECTED" ] || return 1
    verify_status_snapshot_pid
}

# zapret-start.sh --replace is the replacement transaction, exactly as
# zapret-restart.sh invokes it. It inherits this transaction's lifecycle
# ownership through ZAPRET2_LIFECYCLE_TOKEN and may never release it, so its
# failure paths keep converging on the clean stopped state while this
# transaction stays responsible for the configuration it published.
run_replace_transaction() {
    local output rc=0
    trap '' HUP INT TERM
    output="$(ZAPRET2_EMIT_STATUS_V6=0 sh "$SCRIPT_DIR/zapret-start.sh" --replace 2>&1)" || rc=$?
    trap 'apply_interrupted HUP' HUP
    trap 'apply_interrupted INT' INT
    trap 'apply_interrupted TERM' TERM
    [ "$rc" -eq 0 ] && return 0
    parse_typed_error_envelope "$output" || {
        CHILD_ERROR_DOMAIN=LIFECYCLE
        CHILD_ERROR_CODE=LIFECYCLE_FAILED
        CHILD_ERROR_STAGE=APPLY_REPLACE
        CHILD_ERROR_DETAIL="the replacement transaction failed without a typed envelope"
    }
    return 1
}

# The identity reported is the one that refused, captured before the rollback
# runs its own commit and overwrites the shared envelope scratch fields.
report_rollback_after_commit() {
    local detail="$1" outcome="$2"
    local domain="$CHILD_ERROR_DOMAIN" code="$CHILD_ERROR_CODE" stage="$CHILD_ERROR_STAGE"
    if rollback_runtime_config; then
        apply_report_failure "$domain" "$code" "$stage" \
            "$detail; the previous selection was restored" "$outcome"
    fi
    apply_report_failure "$domain" "$code" "$stage" \
        "$detail; the previous selection could not be restored: ${CHILD_ERROR_DETAIL:-unknown}" \
        ROLLBACK_FAILED
}

main() {
    local requested="${1:-}"

    [ "$#" -eq 1 ] || {
        z2_error_set CONFIG INVALID_ARGUMENTS APPLY_REQUEST \
            "usage: zapret-apply-preset.sh PRESET_FILE_NAME"
        APPLY_OUTCOME=REJECTED
        APPLY_ISSUE=UNSAFE_PRESET_NAME
        emit_apply_machine
        exit 2
    }

    # The requested name is never echoed back before it passes the packaged
    # name policy: an unsafe request must not put attacker-chosen bytes into a
    # machine payload the app parses line by line.
    is_safe_preset_file_name "$requested" || {
        z2_error_set CONFIG UNSAFE_PRESET_NAME APPLY_REQUEST \
            "the requested preset name is not a safe packaged preset file name"
        APPLY_OUTCOME=REJECTED
        APPLY_ISSUE=UNSAFE_PRESET_NAME
        emit_apply_machine
        exit 1
    }
    APPLY_REQUESTED_PRESET="$requested"

    ensure_state_dir ||
        apply_report_failure STATE STATE_UNAVAILABLE APPLY_STATE \
            "insecure or unavailable zapret2 state directory: $STATE_DIR" IO_FAILED
    APPLY_NONCE="$(proc_starttime "$$")" ||
        apply_report_failure STATE STATE_UNAVAILABLE APPLY_STATE \
            "the transaction identity could not be established" IO_FAILED

    acquire_lifecycle_lock ||
        apply_report_failure LIFECYCLE LIFECYCLE_BUSY APPLY_LOCK \
            "zapret2 lifecycle is busy" BLOCKED
    APPLY_LOCK_TAKEN=1

    if ! audit_recovery_artifacts lifecycle; then
        apply_report_failure LIFECYCLE RECOVERY_BLOCKED APPLY_RECOVERY \
            "preset application blocked by recovery state: ${RECOVERY_ARTIFACT_DIAGNOSTIC:-unsafe recovery artifact}$(recovery_block_remedy)" \
            BLOCKED
    fi
    if ! uninstall_tombstone_allows_start; then
        apply_report_failure LIFECYCLE UNINSTALL_BLOCKED APPLY_UNINSTALL \
            "preset application blocked by uninstall serialization: $UNINSTALL_TOMBSTONE_ERROR" \
            BLOCKED
    fi
    if [ -e "$MODDIR/disable" ] || [ -L "$MODDIR/disable" ]; then
        apply_report_failure LIFECYCLE MODULE_DISABLED APPLY_PREFLIGHT \
            "preset application blocked because the module is disabled" BLOCKED
    fi
    if module_removal_pending; then
        apply_report_failure LIFECYCLE MODULE_REMOVAL_PENDING APPLY_PREFLIGHT \
            "preset application blocked because the root manager scheduled the module for removal" \
            BLOCKED
    fi

    trap 'apply_interrupted HUP' HUP
    trap 'apply_interrupted INT' INT
    trap 'apply_interrupted TERM' TERM
    prepare_lifecycle_log || LOG_READY=0

    if ! load_effective_core_config_readonly >/dev/null 2>&1; then
        runtime_config_error_code "$RUNTIME_CONFIG_ERROR"
        apply_report_failure CONFIG "${RUNTIME_CONFIG_ERROR_CODE:-CONFIG_INVALID}" \
            APPLY_CONFIG_READ \
            "${RUNTIME_CONFIG_ERROR:-runtime.ini validation failed}" IO_FAILED
    fi
    APPLY_PREVIOUS_PRESET="$ACTIVE_PRESET"

    read_runtime_generations "$RUNTIME_CONFIG" "$requested" ||
        apply_report_failure CONFIG UNSAFE_RUNTIME_FILE APPLY_CONFIG_READ \
            "runtime.ini could not be read as a safe root-owned regular file" IO_FAILED
    [ "$RUNTIME_ACTIVE_PRESET_LINES" -eq 1 ] ||
        apply_report_failure CONFIG CONFIG_INVALID APPLY_CONFIG_READ \
            "runtime.ini [core] does not declare exactly one active_preset" IO_FAILED
    runtime_canonical_digest "$RUNTIME_CANONICAL_TEXT" ||
        apply_report_failure CONFIG RUNTIME_READ_FAILED APPLY_CONFIG_READ \
            "runtime.ini content identity could not be computed" IO_FAILED
    RUNTIME_PREVIOUS_DIGEST="$RUNTIME_CANONICAL_DIGEST"
    runtime_canonical_digest "$RUNTIME_NEXT_TEXT" ||
        apply_report_failure CONFIG RUNTIME_READ_FAILED APPLY_CONFIG_READ \
            "the requested runtime.ini generation identity could not be computed" IO_FAILED
    RUNTIME_NEXT_DIGEST="$RUNTIME_CANONICAL_DIGEST"

    validate_requested_preset ||
        apply_report_failure CONFIG "$PRESET_VALIDATION_CODE" APPLY_VALIDATE \
            "the requested preset was refused by preset qualification: $PRESET_VALIDATION_CODE" \
            REJECTED "$PRESET_VALIDATION_CODE"

    # Measured before the write, exactly like the flow this replaces: a service
    # the user had stopped must not be started by a configuration change.
    if service_process_is_running; then APPLY_SERVICE_WAS_RUNNING=1; fi

    log_msg "Applying preset $requested (previous: ${APPLY_PREVIOUS_PRESET:-unknown}, running: $APPLY_SERVICE_WAS_RUNNING)"

    if commit_runtime_candidate "$RUNTIME_NEXT_TEXT" "$RUNTIME_PREVIOUS_DIGEST" 1; then
        APPLY_CONFIG_COMMITTED=1
    else
        classify_published_runtime
        case "$APPLY_PUBLISHED_GENERATION" in
            previous)
                apply_report_failure "$CHILD_ERROR_DOMAIN" "$CHILD_ERROR_CODE" \
                    "$CHILD_ERROR_STAGE" "$CHILD_ERROR_DETAIL" WRITE_FAILED
                ;;
            requested)
                APPLY_CONFIG_COMMITTED=1
                report_rollback_after_commit \
                    "the selection was published but its commit could not be completed: $CHILD_ERROR_DETAIL" \
                    WRITE_FAILED_ROLLED_BACK
                ;;
            *)
                # Neither the previous nor the requested generation is on disk.
                # Claiming the selection was left alone would be an assertion
                # nothing here measured, so the report keeps the conservative
                # side: something is published and this transaction cannot say
                # what it is.
                APPLY_CONFIG_COMMITTED=1
                apply_report_failure "$CHILD_ERROR_DOMAIN" "$CHILD_ERROR_CODE" \
                    "$CHILD_ERROR_STAGE" \
                    "$CHILD_ERROR_DETAIL; the published runtime generation is unrecognized" \
                    ROLLBACK_FAILED
                ;;
        esac
    fi

    if [ "$APPLY_SERVICE_WAS_RUNNING" = 0 ]; then
        trap - HUP INT TERM
        log_msg "Preset $requested saved; the service was not running so nothing was replaced"
        apply_report_success SAVED
    fi

    if ! run_replace_transaction; then
        report_rollback_after_commit "the replacement transaction failed: $CHILD_ERROR_DETAIL" \
            RESTART_FAILED_ROLLED_BACK
    fi

    trap - HUP INT TERM
    log_msg "Preset $requested applied and the replacement transaction committed"
    apply_report_success APPLIED
}

main "$@"
