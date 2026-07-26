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

# The wrappers invoke this script by an absolute, already-canonical path, so
# resolving it costs two forks (dirname plus the cd/pwd subshell) to return the
# string we were handed. Take the cheap route when the path is already clean
# and keep the canonicalizing fallback for every other invocation.
case "$0" in
    /*//*|/*/./*|/*/../*|*/..|*/.) SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" ;;
    /*/*) SCRIPT_DIR="${0%/*}" ;;
    *) SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" ;;
esac
ZAPRET_DIR="${SCRIPT_DIR%/*}"
MODDIR="${ZAPRET_DIR%/*}"
ZAPRET2_LAZY_FIREWALL_RECONCILER=1
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/command-builder.sh"
. "$SCRIPT_DIR/daemon-replace-transaction.sh"

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
APPLY_SAVE_REQUEST=0
APPLY_SAVE_CANDIDATE=""
APPLY_SAVE_CANDIDATE_CONSUMED=0
APPLY_SAVE_EXPECTED_DIGEST=""
APPLY_SAVE_MODE=""
APPLY_SAVE_BACKUP=""
APPLY_SAVE_TARGET_EXISTED=0
APPLY_SAVE_SHOULD_APPLY=0
APPLY_SAVE_SELECTION_CHANGE=0
APPLY_PRESET_REPLACED=0
APPLY_ROLLBACK_ARGV=""
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

# Save-transaction residue never outlives the report: an unconsumed candidate
# is removed (its name was validated before it was recorded), and the rollback
# buffer goes with it. The replaced target itself is restored only by the
# explicit rollback paths, never here.
apply_save_cleanup() {
    if [ "$APPLY_SAVE_REQUEST" = 1 ] &&
       [ "$APPLY_SAVE_CANDIDATE_CONSUMED" = 0 ] &&
       [ -n "$APPLY_SAVE_CANDIDATE" ]; then
        rm -f "$PRESETS_DIR/$APPLY_SAVE_CANDIDATE" 2>/dev/null
    fi
    [ -z "$APPLY_SAVE_BACKUP" ] || rm -f "$APPLY_SAVE_BACKUP" 2>/dev/null
    [ -z "$APPLY_ROLLBACK_ARGV" ] || rm -f "$APPLY_ROLLBACK_ARGV" 2>/dev/null
}

# Pin a validated artifact for the generation that is currently running
# before the candidate takes over the transaction. A topology-changing
# transaction can then restore both kernel rules and the proven old daemon if
# a family commit or candidate launch fails. The active preset's cache slot
# IS the pin — compiled_cache_store spares it from sweeps and overwrites for
# the rest of the transaction; only a cold cache pays a compile.
prepare_running_rollback_artifact() {
    local canonical="$COMPILED_ARGV_FILE" rc=0
    [ "$APPLY_SERVICE_WAS_RUNNING" = 1 ] || return 0
    if compiled_cache_restore "$PRESETS_DIR/$ACTIVE_PRESET" "$ACTIVE_PRESET"; then
        Z2_DAEMON_REPLACE_ROLLBACK_ARTIFACT="$COMPILED_ARGV_FILE"
        COMPILED_ARGV_FILE="$canonical"
        COMPILED_METADATA_FOR=""
        return 0
    fi
    ensure_state_tmp_dir || return 1
    APPLY_ROLLBACK_ARGV="$Z2_STATE_TMP/compiled-rollback.$$"
    state_file_target_is_safe "$APPLY_ROLLBACK_ARGV" || return 1
    rm -f "$APPLY_ROLLBACK_ARGV" 2>/dev/null
    compile_transaction_artifact "$PRESETS_DIR/$ACTIVE_PRESET" \
        "$ACTIVE_PRESET" "$APPLY_ROLLBACK_ARGV" || rc=1
    COMPILED_ARGV_FILE="$canonical"
    COMPILED_METADATA_FOR=""
    [ "$rc" -eq 0 ] || return 1
    Z2_DAEMON_REPLACE_ROLLBACK_ARTIFACT="$APPLY_ROLLBACK_ARGV"
}

# Restores the save target to its pre-transaction content from the buffered
# backup (or to non-existence for a fresh file). Publication is atomic via a
# sibling temp file, mirroring how the candidate itself was published.
restore_saved_preset_target() {
    local target="$PRESETS_DIR/$APPLY_REQUESTED_PRESET" tmp
    [ "$APPLY_PRESET_REPLACED" = 1 ] || return 0
    if [ "$APPLY_SAVE_TARGET_EXISTED" = 1 ]; then
        [ -n "$APPLY_SAVE_BACKUP" ] && [ -f "$APPLY_SAVE_BACKUP" ] &&
            [ ! -L "$APPLY_SAVE_BACKUP" ] || return 1
        tmp="$target.tmp.$$"
        rm -f "$tmp" 2>/dev/null
        [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
        umask 077
        cat "$APPLY_SAVE_BACKUP" > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
        chmod 0644 "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
        mv -f "$tmp" "$target" || { rm -f "$tmp" 2>/dev/null; return 1; }
    else
        rm -f "$target" 2>/dev/null
        [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
    fi
    APPLY_PRESET_REPLACED=0
    return 0
}

apply_report_failure() {
    local domain="$1" code="$2" stage="$3" detail="$4" outcome="$5" issue="${6:-NONE}"
    APPLY_OUTCOME="$outcome"
    APPLY_ISSUE="$issue"
    # A failed transaction leaves the canonical slot as the refused candidate
    # on purpose: the still-running old generation replays from its cache
    # slot, so nothing here needs the canonical bytes restored.
    apply_save_cleanup
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
    apply_save_cleanup
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
    local signal="$1" restored=0
    trap '' HUP INT TERM
    if [ "$APPLY_CONFIG_COMMITTED" = 1 ] || [ "$APPLY_PRESET_REPLACED" = 1 ]; then
        restored=1
        restore_saved_preset_target || restored=0
        if [ "$APPLY_CONFIG_COMMITTED" = 1 ]; then
            rollback_runtime_config || restored=0
        fi
        if [ "$restored" = 1 ]; then
            apply_report_failure LIFECYCLE LIFECYCLE_FAILED APPLY_SIGNAL \
                "preset application interrupted by $signal; the previous state was restored" \
                RESTART_FAILED_ROLLED_BACK
        fi
        apply_report_failure LIFECYCLE LIFECYCLE_FAILED APPLY_SIGNAL \
            "preset application interrupted by $signal and the previous state could not be restored" \
            ROLLBACK_FAILED
    fi
    apply_report_failure LIFECYCLE LIFECYCLE_FAILED APPLY_SIGNAL \
        "preset application interrupted by $signal before any change" IO_FAILED
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
    cr="$Z2_CR"
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

# The lifecycle lock is the transaction boundary: this shell read, validated
# and canonicalized runtime.ini under the lock, and the candidate text is a
# projection of exactly those bytes, so publication does not re-prove what
# this process just established. The candidate is staged as a sibling and
# renamed into place atomically. runtime-config.sh stays the authority for
# init/repair and for callers outside a locked transaction (the app's own
# --commit-candidate edits keep their compare-and-swap there).
commit_runtime_candidate() {
    local content="$1" expected="$2" step="$3" candidate
    candidate="$RUNTIME_CONFIG.candidate.$$.$APPLY_NONCE$step"
    stage_runtime_candidate "$content" "$candidate" || {
        CHILD_ERROR_DOMAIN=CONFIG
        CHILD_ERROR_CODE=RUNTIME_COMMIT_FAILED
        CHILD_ERROR_STAGE=RUNTIME_COMMIT
        CHILD_ERROR_DETAIL="the runtime.ini candidate could not be staged"
        return 1
    }
    mv -f "$candidate" "$RUNTIME_CONFIG" || {
        rm -f "$candidate" 2>/dev/null
        CHILD_ERROR_DOMAIN=CONFIG
        CHILD_ERROR_CODE=RUNTIME_COMMIT_FAILED
        CHILD_ERROR_STAGE=RUNTIME_COMMIT
        CHILD_ERROR_DETAIL="the runtime.ini candidate could not be published"
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

# One validation compile shared by both transaction flavors. The artifact is
# bound to the preset content and the exact configuration surface the compiler
# consumes, never to the runtime.ini byte identity, so a selection change
# needs no staged runtime copy and a previously validated generation is
# replayed from the cache without recompiling or repeating the dry-run.
compile_transaction_artifact() {
    local preset_path="$1" logical_name="$2" artifact="$3"
    COMPILED_TRANSACTION_REPLAYED=0
    if compiled_cache_restore "$preset_path" "$logical_name"; then
        COMPILED_TRANSACTION_REPLAYED=1
        return 0
    fi
    compile_preset_artifact "$preset_path" "$logical_name" "$artifact" &&
        run_compiled_artifact "$artifact" dry-run >/dev/null 2>&1 || return 1
    compiled_cache_store "$artifact" "$COMPILED_SOURCE_SHA256" ||
        log_msg "Validated artifact cache slot could not be written; the next switch recompiles"
    return 0
}

# The same compatibility qualification the app used to request through
# command-builder.sh --preflight-preset-machine. It happens before runtime.ini
# is touched, so an incompatible preset is refused with the live selection
# untouched instead of being written, failed and rolled back.
#
# The artifact lands in the canonical slot, bound to the preset content and
# the compiler's configuration surface: the replacement finds the binding
# current and the validation receipt fresh, so the compile and the nfqws2
# dry-run are paid at most once per preset generation — a switch back to an
# already validated preset replays its cache slot. An abandoned artifact is
# harmless — its binding no longer matches, so the next start recompiles.
validate_requested_preset() {
    PRESET_VALIDATION_CODE=OK
    ensure_state_tmp_dir &&
        state_path_is_managed_file "$COMPILED_ARGV_FILE" || {
        PRESET_VALIDATION_CODE=PRESET_UNREADABLE
        return 1
    }
    if ! compile_transaction_artifact "$PRESETS_DIR/$APPLY_REQUESTED_PRESET" \
        "$APPLY_REQUESTED_PRESET" "$COMPILED_ARGV_FILE"; then
        [ "$PRESET_VALIDATION_CODE" != OK ] || PRESET_VALIDATION_CODE=NFQWS_DRY_RUN_FAILED
        return 1
    fi
    # The receipt is an optimization, never a gate: if it cannot be written,
    # the replacement simply re-runs its own dry-run as before. A cache
    # replay already carries its receipt.
    [ "$COMPILED_TRANSACTION_REPLAYED" = 1 ] ||
        write_compiled_validation_receipt "$COMPILED_ARGV_FILE" ||
        log_msg "Preset validation receipt could not be written; the replacement will revalidate"
    return 0
}

# Candidate names are the app's staging namespace: underscore-prefixed .txt
# files that the packaged-name policy refuses by construction, so a candidate
# can never be listed or selected as a real preset.
is_safe_candidate_preset_name() {
    local name="$1"
    [ -n "$name" ] && command_builder_safe_file_name_byte_length "$name" || return 1
    case "$name" in
        _*.txt) ;;
        *) return 1 ;;
    esac
    case "$name" in
        */*|*\\*|*"'"*|*'"'*) return 1 ;;
    esac
    case "$name" in *[[:cntrl:]]*) return 1 ;; esac
    [ "${name# }" = "$name" ] && [ "${name% }" = "$name" ]
}

# The compare-and-swap identity for preset content: CR stripped from each
# line, trailing blank lines dropped, single LF between surviving lines and
# none after the last — byte-identical to the app's canonicalProtectedText,
# which the app-side digest is computed over. A mid-line lone CR diverges
# between the two canonicalizations; the divergence fails the swap closed,
# which is the safe direction for content no supported writer produces.
preset_canonical_digest() {
    local path="$1" digest
    PRESET_CANONICAL_DIGEST=""
    command -v sha256sum >/dev/null 2>&1 || return 1
    [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || return 1
    digest="$(awk '
        { sub(/\r$/, ""); line[NR] = $0 }
        END {
            last = NR
            while (last > 0 && line[last] == "") last--
            for (i = 1; i <= last; i++) printf "%s%s", line[i], (i < last ? "\n" : "")
        }
    ' "$path" 2>/dev/null | sha256sum 2>/dev/null)" || return 1
    digest="${digest%% *}"
    is_lower_sha256 "$digest" || return 1
    PRESET_CANONICAL_DIGEST="$digest"
    return 0
}

# The app's "was the service running" question, answered from the committed
# lifecycle receipt exactly as zapret-status.sh derives Z2_PROCESS: the last
# transaction published a healthy generation and its exact process identity is
# still live. Read-only and constant in the size of the package and the process
# table; this transaction never re-audits the firewall to answer it.
service_process_is_running() {
    read_owner_state && owner_state_is_current_boot &&
        [ "$OWNER_STATE_PHASE" = active ] &&
        reverify_published_nfqws_pid "$OWNER_STATE_PID" "$OWNER_STATE_START" \
            "$OWNER_STATE_ARGV_SHA256" "$OWNER_STATE_QNUM"
}

# The save/apply transaction already owns the lock, candidate dry-run and
# generation receipts.  Replace the daemon in this process so none of those
# facts are re-proven by a second fully loaded lifecycle shell.
run_replace_transaction() {
    local rc
    trap '' HUP INT TERM
    replace_daemon_in_locked_transaction
    rc=$?
    # A changed port/capture topology stays in this lock-owning process. Load
    # the firewall layer only for that case, then atomically reconfigure the
    # stable private chains and replace the daemon as one transaction.
    if [ "$rc" -eq 2 ] &&
       [ "${Z2_DAEMON_REPLACE_TOPOLOGY_CHANGED:-0}" = 1 ] &&
       [ "${Z2_DAEMON_REPLACE_CONTROLLED:-0}" = 0 ]; then
        if . "$SCRIPT_DIR/topology-replace-transaction.sh"; then
            replace_topology_in_locked_transaction
            rc=$?
        else
            rc=1
            Z2_DAEMON_REPLACE_ERROR_DOMAIN=FIREWALL
            Z2_DAEMON_REPLACE_ERROR_CODE=FIREWALL_BACKEND_UNAVAILABLE
            Z2_DAEMON_REPLACE_ERROR_STAGE=START_FIREWALL_BACKEND
            Z2_DAEMON_REPLACE_ERROR_DETAIL="the topology replacement layer is unavailable"
        fi
    fi
    trap 'apply_interrupted HUP' HUP
    trap 'apply_interrupted INT' INT
    trap 'apply_interrupted TERM' TERM
    [ "$rc" -eq 0 ] && return 0
    if [ -z "$CHILD_ERROR_DOMAIN" ]; then
        CHILD_ERROR_DOMAIN="${Z2_DAEMON_REPLACE_ERROR_DOMAIN:-LIFECYCLE}"
        CHILD_ERROR_CODE="${Z2_DAEMON_REPLACE_ERROR_CODE:-LIFECYCLE_FAILED}"
        CHILD_ERROR_STAGE="${Z2_DAEMON_REPLACE_ERROR_STAGE:-APPLY_REPLACE}"
        CHILD_ERROR_DETAIL="${Z2_DAEMON_REPLACE_ERROR_DETAIL:-the replacement transaction failed without a typed result}"
    fi
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

# The save-transaction analog: the replaced target file is restored first,
# then the committed selection if there was one; whichever restoration fails
# escalates the report to ROLLBACK_FAILED.
report_save_rollback() {
    local domain="$1" code="$2" stage="$3" detail="$4" outcome="$5" restored=1
    restore_saved_preset_target || restored=0
    if [ "$APPLY_CONFIG_COMMITTED" = 1 ]; then
        rollback_runtime_config || restored=0
    fi
    if [ "$restored" = 1 ]; then
        apply_report_failure "$domain" "$code" "$stage" \
            "$detail; the previous preset content was restored" "$outcome"
    fi
    apply_report_failure "$domain" "$code" "$stage" \
        "$detail; the previous preset content could not be restored" ROLLBACK_FAILED
}

# The content-mutation flavor of this transaction: one entry point validates
# the staged candidate, swaps it in under a content compare-and-swap, commits
# the selection only when it actually changes, and replaces the daemon only
# when the saved preset governs a running service. It reports through the
# same typed envelope and never returns.
run_save_content_transaction() {
    local target="$PRESETS_DIR/$APPLY_REQUESTED_PRESET"
    local candidate="$PRESETS_DIR/$APPLY_SAVE_CANDIDATE"
    local disposable

    [ -f "$candidate" ] && [ ! -L "$candidate" ] &&
        path_uid_is_root "$candidate" && path_nlink_is_one "$candidate" ||
        apply_report_failure CONFIG PRESET_UNREADABLE APPLY_SAVE_CANDIDATE \
            "the staged preset candidate is not a safe root-owned regular file" \
            IO_FAILED

    if [ -e "$target" ] || [ -L "$target" ]; then
        [ -f "$target" ] && [ ! -L "$target" ] &&
            path_uid_is_root "$target" && path_nlink_is_one "$target" ||
            apply_report_failure CONFIG UNSAFE_PRESET_FILE APPLY_SAVE_TARGET \
                "the save target is not a safe root-owned regular file" \
                REJECTED PRESET_SYMLINK
        APPLY_SAVE_TARGET_EXISTED=1
    fi

    # Content compare-and-swap: the module proves the target still carries the
    # content generation the app edited, so a save can never silently clobber
    # an edit that landed from elsewhere after the editor snapshot.
    if [ "$APPLY_SAVE_EXPECTED_DIGEST" = missing ]; then
        [ "$APPLY_SAVE_TARGET_EXISTED" = 0 ] ||
            apply_report_failure CONFIG PRESET_SOURCE_CHANGED APPLY_SAVE_CAS \
                "the save target appeared after the edit began" SOURCE_CHANGED
    else
        [ "$APPLY_SAVE_TARGET_EXISTED" = 1 ] ||
            apply_report_failure CONFIG PRESET_SOURCE_CHANGED APPLY_SAVE_CAS \
                "the save target disappeared after the edit began" SOURCE_CHANGED
        preset_canonical_digest "$target" ||
            apply_report_failure STATE STATE_UNAVAILABLE APPLY_SAVE_CAS \
                "the save target content identity could not be computed" IO_FAILED
        [ "$PRESET_CANONICAL_DIGEST" = "$APPLY_SAVE_EXPECTED_DIGEST" ] ||
            apply_report_failure CONFIG PRESET_SOURCE_CHANGED APPLY_SAVE_CAS \
                "the save target changed after the edit began" SOURCE_CHANGED
    fi

    if [ "$APPLY_SAVE_MODE" = apply ]; then
        APPLY_SAVE_SHOULD_APPLY=1
        [ "$ACTIVE_PRESET" = "$APPLY_REQUESTED_PRESET" ] || APPLY_SAVE_SELECTION_CHANGE=1
    elif [ "$ACTIVE_PRESET" = "$APPLY_REQUESTED_PRESET" ]; then
        APPLY_SAVE_SHOULD_APPLY=1
    fi

    # Measured before any mutation, exactly like the selection transaction: a
    # service the user had stopped must not be started by a content change.
    if service_process_is_running; then APPLY_SERVICE_WAS_RUNNING=1; fi
    prepare_running_rollback_artifact ||
        apply_report_failure STATE STATE_UNAVAILABLE APPLY_ROLLBACK_PREPARE \
            "the running generation could not be preserved for transactional rollback" \
            IO_FAILED

    PRESET_VALIDATION_CODE=OK
    ensure_state_tmp_dir ||
        apply_report_failure STATE STATE_UNAVAILABLE APPLY_VALIDATE \
            "insecure or unavailable zapret2 scratch directory" IO_FAILED
    if [ "$APPLY_SAVE_SHOULD_APPLY" = 1 ]; then
        state_path_is_managed_file "$COMPILED_ARGV_FILE" ||
            apply_report_failure STATE STATE_UNAVAILABLE APPLY_VALIDATE \
                "the compiled artifact slot is unavailable" IO_FAILED
        if ! compile_transaction_artifact "$candidate" "$APPLY_REQUESTED_PRESET" \
            "$COMPILED_ARGV_FILE"; then
            [ "$PRESET_VALIDATION_CODE" != OK ] || PRESET_VALIDATION_CODE=NFQWS_DRY_RUN_FAILED
            apply_report_failure CONFIG "$PRESET_VALIDATION_CODE" APPLY_VALIDATE \
                "the saved preset content was refused by preset qualification: $PRESET_VALIDATION_CODE" \
                REJECTED "$PRESET_VALIDATION_CODE"
        fi
        [ "$COMPILED_TRANSACTION_REPLAYED" = 1 ] ||
            write_compiled_validation_receipt "$COMPILED_ARGV_FILE" ||
            log_msg "Preset validation receipt could not be written; the replacement will revalidate"
    else
        disposable="$Z2_STATE_TMP/preset-save.$$"
        state_file_target_is_safe "$disposable" ||
            apply_report_failure STATE STATE_UNAVAILABLE APPLY_VALIDATE \
                "the disposable validation artifact path is unsafe" IO_FAILED
        rm -f "$disposable" 2>/dev/null
        if ! compile_transaction_artifact "$candidate" "$APPLY_REQUESTED_PRESET" \
            "$disposable"; then
            rm -f "$disposable" 2>/dev/null
            [ "$PRESET_VALIDATION_CODE" != OK ] || PRESET_VALIDATION_CODE=NFQWS_DRY_RUN_FAILED
            apply_report_failure CONFIG "$PRESET_VALIDATION_CODE" APPLY_VALIDATE \
                "the saved preset content was refused by preset qualification: $PRESET_VALIDATION_CODE" \
                REJECTED "$PRESET_VALIDATION_CODE"
        fi
        rm -f "$disposable" 2>/dev/null
    fi

    log_msg "Saving preset content $APPLY_REQUESTED_PRESET (mode: $APPLY_SAVE_MODE, apply: $APPLY_SAVE_SHOULD_APPLY, selection change: $APPLY_SAVE_SELECTION_CHANGE, running: $APPLY_SERVICE_WAS_RUNNING)"

    # Buffer the previous content before the swap: the buffer is the only copy
    # every rollback below restores from.
    if [ "$APPLY_SAVE_TARGET_EXISTED" = 1 ]; then
        APPLY_SAVE_BACKUP="$Z2_STATE_TMP/preset-save-backup.$$"
        state_file_target_is_safe "$APPLY_SAVE_BACKUP" ||
            apply_report_failure STATE STATE_UNAVAILABLE APPLY_SAVE_BACKUP \
                "the rollback buffer path is unsafe" IO_FAILED
        rm -f "$APPLY_SAVE_BACKUP" 2>/dev/null
        umask 077
        cat "$target" > "$APPLY_SAVE_BACKUP" ||
            apply_report_failure STATE STATE_UNAVAILABLE APPLY_SAVE_BACKUP \
                "the previous preset content could not be buffered for rollback" IO_FAILED
    fi

    chmod 0644 "$candidate" 2>/dev/null &&
        mv -f "$candidate" "$target" || {
        apply_report_failure CONFIG PRESET_WRITE_FAILED APPLY_SAVE_PUBLISH \
            "the validated candidate could not be published to its target" IO_FAILED
    }
    APPLY_SAVE_CANDIDATE_CONSUMED=1
    APPLY_PRESET_REPLACED=1
    Z2_DAEMON_REPLACE_PREVALIDATED=1

    if [ "$APPLY_SAVE_SELECTION_CHANGE" = 1 ]; then
        if commit_runtime_candidate "$RUNTIME_NEXT_TEXT" "$RUNTIME_PREVIOUS_DIGEST" 1; then
            APPLY_CONFIG_COMMITTED=1
            # The compare-and-swap child owns durable runtime.ini publication,
            # but this lock-owning shell owns every later proof. Adopt the
            # exact field it just committed so the in-process replacement
            # validates the candidate generation rather than the pre-commit
            # selection still held in memory.
            ACTIVE_PRESET="$APPLY_REQUESTED_PRESET"
        else
            classify_published_runtime
            [ "$APPLY_PUBLISHED_GENERATION" = previous ] || APPLY_CONFIG_COMMITTED=1
            report_save_rollback "$CHILD_ERROR_DOMAIN" "$CHILD_ERROR_CODE" \
                "$CHILD_ERROR_STAGE" \
                "the selection commit failed: $CHILD_ERROR_DETAIL" \
                WRITE_FAILED_ROLLED_BACK
        fi
    fi

    if [ "$APPLY_SAVE_SHOULD_APPLY" = 1 ] && [ "$APPLY_SERVICE_WAS_RUNNING" = 1 ]; then
        if ! run_replace_transaction; then
            report_save_rollback "$CHILD_ERROR_DOMAIN" "$CHILD_ERROR_CODE" \
                "$CHILD_ERROR_STAGE" \
                "the replacement transaction failed: $CHILD_ERROR_DETAIL" \
                RESTART_FAILED_ROLLED_BACK
        fi
    fi

    trap - HUP INT TERM
    if [ "$APPLY_SAVE_SHOULD_APPLY" = 0 ] || [ "$APPLY_SERVICE_WAS_RUNNING" = 0 ]; then
        log_msg "Preset content $APPLY_REQUESTED_PRESET saved (no replacement was required)"
        apply_report_success SAVED
    fi
    if [ "$APPLY_SAVE_SELECTION_CHANGE" = 1 ]; then
        log_msg "Preset content $APPLY_REQUESTED_PRESET saved, selected and applied"
        apply_report_success SAVED_AND_APPLIED
    fi
    log_msg "Preset content $APPLY_REQUESTED_PRESET saved and applied"
    apply_report_success APPLIED
}

main() {
    local requested="${1:-}"

    if [ "$requested" = --save-content ]; then
        # --save-content CANDIDATE EXPECTED_DIGEST PRESET_FILE_NAME MODE
        # EXPECTED_DIGEST is the canonical content identity the app edited
        # (or the literal "missing" for a file that must not exist yet);
        # MODE is "apply" (make PRESET the selection) or "auto" (replace the
        # daemon only when PRESET already governs it).
        [ "$#" -eq 5 ] || {
            z2_error_set CONFIG INVALID_ARGUMENTS APPLY_SAVE_REQUEST \
                "usage: zapret-apply-preset.sh --save-content CANDIDATE EXPECTED_DIGEST PRESET_FILE_NAME MODE"
            APPLY_OUTCOME=IO_FAILED
            emit_apply_machine
            exit 2
        }
        is_safe_candidate_preset_name "$2" || {
            z2_error_set CONFIG INVALID_ARGUMENTS APPLY_SAVE_REQUEST \
                "the staged candidate name is not a safe staging file name"
            APPLY_OUTCOME=IO_FAILED
            emit_apply_machine
            exit 1
        }
        case "$3" in
            missing) ;;
            *)
                is_lower_sha256 "$3" || {
                    z2_error_set CONFIG INVALID_ARGUMENTS APPLY_SAVE_REQUEST \
                        "the expected content identity is neither a digest nor the missing sentinel"
                    APPLY_OUTCOME=IO_FAILED
                    emit_apply_machine
                    exit 1
                }
                ;;
        esac
        case "$5" in
            apply|auto) ;;
            *)
                z2_error_set CONFIG INVALID_ARGUMENTS APPLY_SAVE_REQUEST \
                    "the save mode is not a supported application mode"
                APPLY_OUTCOME=IO_FAILED
                emit_apply_machine
                exit 1
                ;;
        esac
        APPLY_SAVE_REQUEST=1
        APPLY_SAVE_CANDIDATE="$2"
        APPLY_SAVE_EXPECTED_DIGEST="$3"
        requested="$4"
        APPLY_SAVE_MODE="$5"
    elif [ "$#" -ne 1 ]; then
        z2_error_set CONFIG INVALID_ARGUMENTS APPLY_REQUEST \
            "usage: zapret-apply-preset.sh PRESET_FILE_NAME"
        APPLY_OUTCOME=REJECTED
        APPLY_ISSUE=UNSAFE_PRESET_NAME
        emit_apply_machine
        exit 2
    fi

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
    proc_starttime_read "$$" ||
        apply_report_failure STATE STATE_UNAVAILABLE APPLY_STATE \
            "the transaction identity could not be established" IO_FAILED
    APPLY_NONCE="$PROC_STARTTIME"

    acquire_lifecycle_lock ||
        apply_report_failure LIFECYCLE LIFECYCLE_BUSY APPLY_LOCK \
            "zapret2 lifecycle is busy" BLOCKED
    APPLY_LOCK_TAKEN=1

    # The request paths are known only to this endpoint, after common.sh has
    # acquired the lock and primed its fixed state set. Add them in one stat
    # call so validation, CAS and compilation consume the same metadata proof.
    set -- "$RUNTIME_CONFIG"
    [ ! -e "$PRESETS_DIR/$requested" ] && [ ! -L "$PRESETS_DIR/$requested" ] ||
        set -- "$@" "$PRESETS_DIR/$requested"
    if [ "$APPLY_SAVE_REQUEST" = 1 ]; then
        [ ! -e "$PRESETS_DIR/$APPLY_SAVE_CANDIDATE" ] &&
            [ ! -L "$PRESETS_DIR/$APPLY_SAVE_CANDIDATE" ] ||
            set -- "$@" "$PRESETS_DIR/$APPLY_SAVE_CANDIDATE"
    fi
    [ ! -e "$Z2_STATE_TMP" ] && [ ! -L "$Z2_STATE_TMP" ] ||
        set -- "$@" "$Z2_STATE_TMP"
    meta_cache_add "$@" ||
        apply_report_failure STATE STATE_UNAVAILABLE APPLY_STATE \
            "transaction metadata could not be captured" IO_FAILED

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
    if [ "$RUNTIME_NEXT_TEXT" = "$RUNTIME_CANONICAL_TEXT" ]; then
        RUNTIME_NEXT_DIGEST="$RUNTIME_PREVIOUS_DIGEST"
    else
        runtime_canonical_digest "$RUNTIME_NEXT_TEXT" ||
            apply_report_failure CONFIG RUNTIME_READ_FAILED APPLY_CONFIG_READ \
                "the requested runtime.ini generation identity could not be computed" IO_FAILED
        RUNTIME_NEXT_DIGEST="$RUNTIME_CANONICAL_DIGEST"
    fi

    if [ "$APPLY_SAVE_REQUEST" = 1 ]; then
        run_save_content_transaction
        apply_report_failure LIFECYCLE LIFECYCLE_FAILED APPLY_SAVE \
            "the save transaction ended without a report" IO_FAILED
    fi

    # Measure and preserve the old running generation before the compiler
    # replaces its canonical argv cache with the candidate generation.
    if service_process_is_running; then APPLY_SERVICE_WAS_RUNNING=1; fi
    prepare_running_rollback_artifact ||
        apply_report_failure STATE STATE_UNAVAILABLE APPLY_ROLLBACK_PREPARE \
            "the running generation could not be preserved for transactional rollback" \
            IO_FAILED

    validate_requested_preset ||
        apply_report_failure CONFIG "$PRESET_VALIDATION_CODE" APPLY_VALIDATE \
            "the requested preset was refused by preset qualification: $PRESET_VALIDATION_CODE" \
            REJECTED "$PRESET_VALIDATION_CODE"

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

    # runtime-config.sh is the durability boundary; the current shell remains
    # the transaction boundary. Keep its typed projection aligned with the
    # generation that was just committed before consuming the compiled
    # candidate and validation receipt in process.
    ACTIVE_PRESET="$requested"

    if [ "$APPLY_SERVICE_WAS_RUNNING" = 0 ]; then
        trap - HUP INT TERM
        log_msg "Preset $requested saved; the service was not running so nothing was replaced"
        apply_report_success SAVED
    fi

    Z2_DAEMON_REPLACE_PREVALIDATED=1
    if ! run_replace_transaction; then
        report_rollback_after_commit "the replacement transaction failed: $CHILD_ERROR_DETAIL" \
            RESTART_FAILED_ROLLED_BACK
    fi

    trap - HUP INT TERM
    log_msg "Preset $requested applied and the replacement transaction committed"
    apply_report_success APPLIED
}

main "$@"
