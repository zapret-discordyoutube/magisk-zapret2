#!/system/bin/sh
# Idempotent zapret2 start/replace lifecycle.

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
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/command-builder.sh"

set -f
REPLACE=0
CONTROLLED_TEARDOWN_STARTED=0
FIREWALL_MUTATED=0
NEW_PID_PUBLISHED=0
LAUNCHED_PID=""
LAUNCHED_PID_START=""
LAUNCHED_ARGV_SHA256=""
LAUNCH_OWNS_PIDFILE=0
IPV4_BUILT=0
IPV6_BUILT=0
IPV6_TOUCHED=0
IPV4_RULES=0
IPV6_RULES=0
DIAGNOSTICS=""
FAST_REPLACE_BASELINE=0
FAST_REPLACE_READY=0
FAST_REPLACE_FIREWALL_FINGERPRINT=""
FAST_REPLACE_IPV6_ACTIVE=0
FAST_REPLACE_IPV4_CONNBYTES=0
FAST_REPLACE_IPV6_CONNBYTES=0
FAST_REPLACE_IPV4_MULTIPORT=1
FAST_REPLACE_IPV6_MULTIPORT=1

log_msg() {
    z2_log_stamp_read
    append_lifecycle_log "[INFO] $Z2_LOG_STAMP $1"
}

log_error() {
    z2_log_stamp_read
    append_lifecycle_log "[ERROR] $Z2_LOG_STAMP $1"
    if command -v log >/dev/null 2>&1; then log -p e -t Zapret2 "$1" 2>/dev/null; fi
}

log_debug() {
    if [ "${DEBUG:-0}" = 1 ]; then
        z2_log_stamp_read
        append_lifecycle_log "[DEBUG] $Z2_LOG_STAMP $1"
    fi
    return 0
}

log_section() { log_msg "==== $1 ===="; }

firewall_failure_code() {
    case "${Z2_FW_FAILURE_CLASS:-}" in
        BACKEND_UNAVAILABLE) printf '%s\n' FIREWALL_BACKEND_UNAVAILABLE ;;
        CLEANUP_FAILED) printf '%s\n' FIREWALL_CLEANUP_FAILED ;;
        LOCK_TIMEOUT) printf '%s\n' FIREWALL_LOCK_TIMEOUT ;;
        RULESET_REJECTED) printf '%s\n' FIREWALL_RULESET_UNSUPPORTED ;;
        PUBLICATION_FAILED) printf '%s\n' FIREWALL_PUBLISH_FAILED ;;
        POSTCONDITION_FAILED) printf '%s\n' POSTCONDITION_FAILED ;;
        # A published family nobody could inspect is not a family that failed
        # inspection. The two used to arrive under one code, and the reader of
        # a bug report had no way to tell a wrong ruleset from a verifier that
        # never ran.
        VERIFIER_FAILED) printf '%s\n' FIREWALL_VERIFY_UNAVAILABLE ;;
        *) printf '%s\n' FIREWALL_BUILD_FAILED ;;
    esac
}

start_error_exit() {
    local domain="$1" code="$2" stage="$3" message="$5"
    z2_error_set "$domain" "$code" "$stage" "$message" ||
        z2_error_set LIFECYCLE LIFECYCLE_FAILED START "$message"
    z2_error_emit_machine
    echo "ERROR: $message"
    exit 1
}

set_default_config() {
    set_core_config_defaults
    HOSTLIST_MODE="none"
    HOSTLIST_FILES="youtube.txt"
}

load_config() {
    set_default_config
    load_effective_core_config || return 1
    log_msg "$(runtime_config_status_message)"
    log_msg "$(core_config_source_message)"
    return 0
}

validate_port_list() {
    local list="$1" item first last old_ifs
    [ -n "$list" ] || return 0
    case "$list" in *[!0-9,:]*) return 1 ;; esac
    case "$list" in ,*|*,|*,,*) return 1 ;; esac
    old_ifs="$IFS"; IFS=,; set -- $list; IFS="$old_ifs"
    [ "$#" -gt 0 ] || return 1
    for item in "$@"; do
        case "$item" in
            *:*)
                first="${item%%:*}"; last="${item#*:}"
                case "$last" in *:*) return 1 ;; esac
                is_decimal "$first" && is_decimal "$last" || return 1
                [ "$first" -le 65535 ] 2>/dev/null || return 1
                [ "$last" -le 65535 ] 2>/dev/null || return 1
                [ "$first" -le "$last" ] 2>/dev/null || return 1
                ;;
            *)
                is_decimal "$item" || return 1
                [ "$item" -le 65535 ] 2>/dev/null || return 1
                ;;
        esac
    done
}

validate_mark() {
    local mark="$1" hex
    case "$mark" in
        0x*)
            hex="${mark#0x}"
            [ -n "$hex" ] || return 1
            case "$hex" in *[!0-9A-Fa-f]*) return 1 ;; esac
            ;;
        *) is_decimal "$mark" || return 1 ;;
    esac
}

validate_config() {
    normalize_qnum "$QNUM" || return 1
    QNUM="$QNUM_NORMALIZED"
    validate_mark "$DESYNC_MARK" || return 1
    case "$WIFI_ONLY" in 0|1) ;; *) return 1 ;; esac
    return 0
}

preflight_wifi_only() {
    case "$WIFI_ONLY" in
        0) return 0 ;;
        1)
            # There is no configured, verified Wi-Fi interface in the core
            # contract.  Queueing all interfaces would violate WIFI_ONLY.
            DIAGNOSTICS="${DIAGNOSTICS}WIFI_ONLY=1 requires verified interface scoping; startup refused; "
            return 1
            ;;
        *) return 1 ;;
    esac
}

preflight_files() {
    local path
    for path in "$ZAPRET_DIR/lua/zapret-lib.lua" "$ZAPRET_DIR/lua/zapret-antidpi.lua"; do
        [ -f "$path" ] && [ -r "$path" ] || return 1
    done
    return 0
}

prepare_options() {
    local capture="$Z2_STATE_TMP/nfqws2.error.capture.$$" rcfile="$Z2_STATE_TMP/nfqws2.error.rc.$$" dry_rc preset_file
    [ -f "$NFQWS2" ] && [ -x "$NFQWS2" ] || return 1
    ensure_state_tmp_dir || return 1
    is_safe_preset_file_name "$ACTIVE_PRESET" || return 1
    preset_file="$PRESETS_DIR/$ACTIVE_PRESET"
    state_path_is_managed_file "$COMPILED_ARGV_FILE" || return 1
    # ensure_compiled_artifact leaves the COMPILED_* metadata populated on
    # both the cache-hit and the freshly-compiled path.
    ensure_compiled_artifact "$preset_file" "$ACTIVE_PRESET" "$COMPILED_ARGV_FILE" || return 1
    [ "$COMPILED_METADATA_FOR" = "$COMPILED_ARGV_FILE" ] || return 1
    PORTS_TCP="$COMPILED_TCP_PORTS"
    PORTS_UDP="$COMPILED_UDP_PORTS"
    TCP_PKT_OUT="$COMPILED_TCP_PKT_OUT"
    TCP_PKT_IN="$COMPILED_TCP_PKT_IN"
    UDP_PKT_OUT="$COMPILED_UDP_PKT_OUT"
    UDP_PKT_IN="$COMPILED_UDP_PKT_IN"
    validate_port_list "$PORTS_TCP" || return 1
    validate_port_list "$PORTS_UDP" || return 1
    [ -n "$PORTS_TCP$PORTS_UDP" ] || return 1
    preflight_files || return 1
    prepare_private_runtime_file "$STARTUP_LOG" || return 1
    prepare_private_runtime_file "$ERROR_LOG" || return 1
    if compiled_validation_receipt_current "$COMPILED_ARGV_FILE"; then
        log_debug "Reusing generation-bound nfqws2 preflight receipt"
    else
        rm -f "$capture" "$rcfile" 2>/dev/null
        { [ ! -e "$capture" ] && [ ! -L "$capture" ] &&
          [ ! -e "$rcfile" ] && [ ! -L "$rcfile" ]; } || return 1
        umask 077
        { run_compiled_artifact "$COMPILED_ARGV_FILE" dry-run >/dev/null; printf '%s\n' "$?" > "$rcfile"; } 2>&1 |
            tail -c 32768 > "$capture"
        dry_rc=""
        IFS= read -r dry_rc < "$rcfile" 2>/dev/null || dry_rc=""
        rm -f "$rcfile" 2>/dev/null
        is_decimal "$dry_rc" || { rm -f "$capture"; return 1; }
        chmod 0600 "$capture" 2>/dev/null || { rm -f "$capture"; return 1; }
        mv -f "$capture" "$ERROR_LOG" || { rm -f "$capture"; return 1; }
        [ "$dry_rc" -eq 0 ] 2>/dev/null || return 1
        write_compiled_validation_receipt "$COMPILED_ARGV_FILE" || return 1
    fi
    # The Android app renders this mirror of the exact daemon command line on
    # its logs screen; no shell code reads it back.
    state_path_is_managed_file "$CMDLINE_FILE.tmp.$$" || return 1
    rm -f "$CMDLINE_FILE.tmp.$$" 2>/dev/null
    [ ! -e "$CMDLINE_FILE.tmp.$$" ] && [ ! -L "$CMDLINE_FILE.tmp.$$" ] || return 1
    {
        z2_emit_line "$NFQWS2
--daemon
--pidfile=$PIDFILE"
        awk 'found { print } $0 == "ARGS" { found=1 }' "$COMPILED_ARGV_FILE"
    } > "$CMDLINE_FILE.tmp.$$" || return 1
    chmod 0600 "$CMDLINE_FILE.tmp.$$" 2>/dev/null && mv -f "$CMDLINE_FILE.tmp.$$" "$CMDLINE_FILE" || {
        rm -f "$CMDLINE_FILE.tmp.$$"; return 1;
    }
    return 0
}

compiled_source_binding_current() {
    compiled_artifact_binding_current \
        "$COMPILED_ARGV_FILE" "$PRESETS_DIR/$ACTIVE_PRESET" "$ACTIVE_PRESET"
}

count_family_rules() {
    local tool="$1" count=0 n chain
    for chain in "$ZAPRET2_OUT" "$ZAPRET2_IN"; do
        n="$("$tool" -t mangle -S "$chain" 2>/dev/null | grep -c "^-A $chain " || true)"
        is_decimal "$n" || n=0
        count=$((count + n))
    done
    printf '%s\n' "$count"
}

normal_health_ok() {
    HEALTH_PID=""; HEALTH_PID_START=""; HEALTH_GENERATION=""; HEALTH_IPV6=0; HEALTH_RULES=0
    read_verified_pidfile || return 1
    [ "$OWNER_STATE_SCHEMA_VERSION" = "$OWNER_STATE_VERSION" ] || return 1
    read_install_generation_meta && [ "$OWNER_STATE_INSTALL_GENERATION" = "$INSTALL_META_GENERATION" ] &&
        [ "$OWNER_STATE_INSTALL_ARCHIVE_SHA256" = "$INSTALL_META_ARCHIVE_SHA256" ] || return 1
    [ "$OWNER_STATE_PHASE" = active ] || return 1
    [ "$OWNER_STATE_QNUM" = "$QNUM" ] || return 1
    command -v iptables >/dev/null 2>&1 || return 1
    owner_family_generation_healthy iptables ipv4 || return 1
    HEALTH_PID="$VERIFIED_PID"
    HEALTH_PID_START="$VERIFIED_PID_START"
    HEALTH_GENERATION="$OWNER_STATE_GENERATION"
    HEALTH_RULES="$OWNER_STATE_IPV4_RULES"
    if command -v ip6tables >/dev/null 2>&1; then
        if [ "$OWNER_STATE_IPV6_ACTIVE" = 1 ]; then
            owner_family_generation_healthy ip6tables ipv6 || return 1
            HEALTH_IPV6=1
            HEALTH_RULES=$((OWNER_STATE_IPV4_RULES + OWNER_STATE_IPV6_RULES))
        else
            owner_family_generation_healthy ip6tables ipv6 || return 1
        fi
    elif [ "${STATUS_FILE_IPV6_ACTIVE:-0}" = 1 ]; then
        return 1
    fi
    return 0
}

capture_fast_replace_baseline() {
    [ "$REPLACE" = 1 ] && [ "$OWNER_STATE_PHASE" = active ] || return 1
    FAST_REPLACE_FIREWALL_FINGERPRINT="$OWNER_STATE_FIREWALL_FINGERPRINT"
    FAST_REPLACE_IPV6_ACTIVE="$OWNER_STATE_IPV6_ACTIVE"
    FAST_REPLACE_IPV4_CONNBYTES="$OWNER_STATE_IPV4_CONNBYTES"
    FAST_REPLACE_IPV6_CONNBYTES="$OWNER_STATE_IPV6_CONNBYTES"
    # A fast replace reuses the topology the previous generation published, so
    # it inherits the extensions that generation actually got, not the ones the
    # module would like to have.
    FAST_REPLACE_IPV4_MULTIPORT="$OWNER_STATE_IPV4_MULTIPORT"
    FAST_REPLACE_IPV6_MULTIPORT="$OWNER_STATE_IPV6_MULTIPORT"
    FAST_REPLACE_BASELINE=1
}

prepare_fast_replace_candidate() {
    local desired_ipv6=0
    [ "$FAST_REPLACE_BASELINE" = 1 ] || return 1
    if z2_fw_tool_available ip6tables && z2_fw_restore_available ip6tables; then
        desired_ipv6=1
    fi
    [ "$desired_ipv6" = "$FAST_REPLACE_IPV6_ACTIVE" ] || return 1

    IPV4_NFQUEUE=1; IPV4_QUEUE_BYPASS=1; IPV4_MARK=1
    IPV4_CONNBYTES="$FAST_REPLACE_IPV4_CONNBYTES"
    IPV4_MULTIPORT="$FAST_REPLACE_IPV4_MULTIPORT"
    IPV6_ACTIVE="$FAST_REPLACE_IPV6_ACTIVE"; IPV6_BUILT="$FAST_REPLACE_IPV6_ACTIVE"
    IPV6_CONNBYTES="$FAST_REPLACE_IPV6_CONNBYTES"; IPV6_MARK=1
    IPV6_MULTIPORT="$FAST_REPLACE_IPV6_MULTIPORT"
    OWNER_WRITE_READY=0; OWNER_WRITE_QNUM=""; OWNER_WRITE_SOURCE_GENERATION=""
    prepare_new_firewall_identity || return 1
    prepare_owner_generation_spec 1 "$IPV6_ACTIVE" || return 1
    [ "$OWNER_WRITE_FIREWALL_FINGERPRINT" = "$FAST_REPLACE_FIREWALL_FINGERPRINT" ] ||
        return 1

    IPV4_RULES="$OWNER_WRITE_IPV4_RULES"; IPV4_BUILT=1; IPV4_ACTIVE=1
    IPV6_RULES="$OWNER_WRITE_IPV6_RULES"
    FALLBACK_MODE=0
    if [ "$IPV4_CONNBYTES" != 1 ] ||
       { [ "$IPV6_ACTIVE" = 1 ] && [ "$IPV6_CONNBYTES" != 1 ]; }; then
        FALLBACK_MODE=1
    fi
    FAST_REPLACE_READY=1
    return 0
}

fast_replace_health_ok() {
    HEALTH_PID=""; HEALTH_PID_START=""; HEALTH_GENERATION=""
    HEALTH_IPV6="$IPV6_ACTIVE"; HEALTH_RULES=$((IPV4_RULES + IPV6_RULES))
    [ "${PUBLISHED_PID:-}" = "$STARTED_PID" ] &&
        [ "${PUBLISHED_START:-}" = "$STARTED_PID_START" ] &&
        [ "${PUBLISHED_GENERATION:-}" = "$PENDING_OWNER_GENERATION" ] &&
        [ "${PUBLISHED_FIREWALL_FINGERPRINT:-}" = "$FAST_REPLACE_FIREWALL_FINGERPRINT" ] &&
        [ "${PUBLISHED_IPV4_RULES:-}" = "$IPV4_RULES" ] &&
        [ "${PUBLISHED_IPV6_RULES:-}" = "$IPV6_RULES" ] &&
        [ "${PUBLISHED_INSTALL_GENERATION:-}" = "$INSTALL_META_GENERATION" ] &&
        [ "${PUBLISHED_INSTALL_ARCHIVE_SHA256:-}" = "$INSTALL_META_ARCHIVE_SHA256" ] ||
        return 1
    HEALTH_PID="$PUBLISHED_PID"
    HEALTH_PID_START="$PUBLISHED_START"
    HEALTH_GENERATION="$PUBLISHED_GENERATION"
    return 0
}

write_ok_status() {
    local status_argv status_ipv4_rules status_ipv6_rules
    status_argv="${PUBLISHED_ARGV_SHA256:-$OWNER_STATE_ARGV_SHA256}"
    status_ipv4_rules="${PUBLISHED_IPV4_RULES:-$OWNER_STATE_IPV4_RULES}"
    status_ipv6_rules="${PUBLISHED_IPV6_RULES:-$OWNER_STATE_IPV6_RULES}"
    STATUS_RULES_OK="$1"; STATUS_RULES_FAIL=0; STATUS_RULES_TOTAL="$1"
    STATUS_ERRORS=""; STATUS_OWN_PID="$2"; STATUS_PID_VERIFIED=1; STATUS_QNUM="$QNUM"
    STATUS_OWN_PID_STARTTIME="$HEALTH_PID_START"
    STATUS_OWN_ARGV_SHA256="$status_argv"
    STATUS_OWNER_GENERATION="$HEALTH_GENERATION"
    STATUS_OWNER_METADATA_VERIFIED=1; STATUS_RULESET_VERIFIED=1; STATUS_RULES_EXPECTED="$1"
    STATUS_IPV4_ACTIVE=1; STATUS_IPV6_ACTIVE="$3"
    STATUS_IPV4_RULES="$status_ipv4_rules"; STATUS_IPV6_RULES="$status_ipv6_rules"
    STATUS_CHAINS=$((1 + IPV4_CONNBYTES + STATUS_IPV6_ACTIVE * (1 + IPV6_CONNBYTES)))
    # Tethering capture anchors every published chain a second time, into
    # FORWARD, so the anchor count is no longer the chain count.
    STATUS_ANCHORS=$((STATUS_CHAINS * (1 + ${TETHERING:-0})))
    STATUS_NFQUEUE_SUPPORTED=1; STATUS_QUEUE_BYPASS_SUPPORTED=1
    STATUS_CONNBYTES_SUPPORTED="${IPV4_CONNBYTES:-1}"
    STATUS_MULTIPORT_SUPPORTED="${IPV4_MULTIPORT:-1}"
    STATUS_MARK_SUPPORTED="${IPV4_MARK:-1}"
    STATUS_FALLBACK_MODE="${FALLBACK_MODE:-0}"
    STATUS_ERROR_STATUS=OK; STATUS_ERROR_DOMAIN=NONE; STATUS_ERROR_CODE=NONE
    STATUS_ERROR_STAGE=NONE; STATUS_ERROR_DETAIL=""
    STATUS_DIAGNOSTICS="$DIAGNOSTICS"
    write_iptables_status ok
}

rollback_start() {
    local rc=0
    ROLLBACK_ERRORS=""
    OWNER_STATE_AVAILABLE_FOR_ROLLBACK=0
    if read_owner_state >/dev/null 2>&1 && owner_state_is_current_boot; then
        OWNER_STATE_AVAILABLE_FOR_ROLLBACK=1
    fi
    # The shared resolver weighs this transaction's own facts first, so a
    # publication that committed without verifying still counts as touched.
    resolve_ipv6_ownership_expectation "$OWNER_STATE_AVAILABLE_FOR_ROLLBACK"
    if [ "$FIREWALL_MUTATED" = 1 ]; then
        cleanup_owned_firewall >/dev/null 2>&1 ||
            { rc=1; ROLLBACK_ERRORS="stable firewall namespace cleanup failed"; }
    fi
    if [ "$NEW_PID_PUBLISHED" = 1 ]; then
        stop_pidfile_process >/dev/null 2>&1 || { rc=1; ROLLBACK_ERRORS="${ROLLBACK_ERRORS}${ROLLBACK_ERRORS:+; }owned process cleanup failed"; }
    elif [ -n "$LAUNCHED_PID" ]; then
        stop_failed_fallback_launch "$LAUNCHED_PID" >/dev/null 2>&1 || { rc=1; ROLLBACK_ERRORS="${ROLLBACK_ERRORS}${ROLLBACK_ERRORS:+; }failed launch process remains ambiguous"; }
    fi
    firewall_is_clean_after_rollback || { rc=1; ROLLBACK_ERRORS="${ROLLBACK_ERRORS}${ROLLBACK_ERRORS:+; }owned firewall artifacts remain"; }
    scan_exact_owned_nfqws >/dev/null 2>&1
    [ -z "$OWNED_SCAN_PIDS" ] || { rc=1; ROLLBACK_ERRORS="${ROLLBACK_ERRORS}${ROLLBACK_ERRORS:+; }module-owned process remains: $OWNED_SCAN_PIDS"; }
    [ "$rc" -ne 0 ] || retire_owner_metadata >/dev/null 2>&1 || { rc=1; ROLLBACK_ERRORS="ownership metadata cleanup failed"; }
    return "$rc"
}

firewall_is_clean_after_rollback() {
    command -v iptables >/dev/null 2>&1 || return 1
    owned_family_absent iptables || return 1
    # An unqueryable IPv6 frontend is acceptable on two proofs this transaction
    # can hold: it never published IPv6 rules, or the teardown that just ran
    # captured the family's baseline and committed its removal. Re-asking the
    # kernel is not a third one — a frontend that goes busy between the
    # teardown and this check would otherwise discard the teardown's own
    # evidence and report a rollback that succeeded as leaving artifacts.
    if command -v ip6tables >/dev/null 2>&1; then
        owned_family_absent ip6tables ||
            { ! z2_fw_tool_available ip6tables &&
                { [ "${CLEANUP_IPV6_OWNERSHIP_EXPECTED:-1}" = 0 ] ||
                    [ "${FIREWALL_IPV6_TEARDOWN_PROVEN:-0}" = 1 ]; }; } ||
            return 1
    elif [ "${IPV6_PUBLICATION_RECORDED:-0}" = 1 ]; then
        # No frontend at all: the module could only have published there while
        # one existed, so absence of a record is the answer. Stop asks the
        # same question the same way.
        return 1
    fi
    return 0
}

# Answers "did this generation publish IPv6?" without disturbing the teardown
# decision a caller may already have resolved: the resolver publishes both
# answers into globals, and only one of them belongs to this question.
snapshot_ipv6_publication_recorded() {
    local saved_expected="${CLEANUP_IPV6_OWNERSHIP_EXPECTED:-1}"
    local saved_recorded="${IPV6_PUBLICATION_RECORDED:-0}" recorded
    local owner_available="${OWNER_STATE_AVAILABLE_FOR_ROLLBACK:-}"
    # Same inputs as the teardown decision, including the owner record: two
    # callers asking one question about one generation must not disagree. A
    # failure before teardown never set that answer, and the record it would
    # have read may still describe live rules, so read it here.
    if [ -z "$owner_available" ]; then
        owner_available=0
        if read_owner_state >/dev/null 2>&1 && owner_state_is_current_boot; then
            owner_available=1
        fi
    fi
    resolve_ipv6_ownership_expectation "$owner_available"
    recorded="$IPV6_PUBLICATION_RECORDED"
    CLEANUP_IPV6_OWNERSHIP_EXPECTED="$saved_expected"
    IPV6_PUBLICATION_RECORDED="$saved_recorded"
    [ "$recorded" = 1 ]
}

snapshot_owned_state() {
    SNAP_PID=""; SNAP_PID_START=""; SNAP_GENERATION=""; SNAP_PID_VERIFIED=0
    SNAP_IPV4=0; SNAP_IPV6=0; SNAP_RULES=0; SNAP_CHAINS=0; SNAP_ANCHORS=0
    if read_verified_pidfile; then
        SNAP_PID="$VERIFIED_PID"; SNAP_PID_START="$VERIFIED_PID_START"
        SNAP_GENERATION="$OWNER_STATE_GENERATION"; SNAP_PID_VERIFIED=1
    else
        scan_exact_owned_nfqws >/dev/null 2>&1
        SNAP_PID="$OWNED_SCAN_PIDS"
    fi
    if command -v iptables >/dev/null 2>&1 && owned_family_present iptables; then
        SNAP_IPV4=1
        SNAP_RULES=$((SNAP_RULES + $(count_family_rules iptables)))
        iptables -t mangle -S "$Z2_FW_OUT_CHAIN" >/dev/null 2>&1 &&
            SNAP_CHAINS=$((SNAP_CHAINS + 1))
        iptables -t mangle -S "$Z2_FW_IN_CHAIN" >/dev/null 2>&1 &&
            SNAP_CHAINS=$((SNAP_CHAINS + 1))
        iptables -t mangle -C OUTPUT -j "$Z2_FW_OUT_CHAIN" >/dev/null 2>&1 &&
            SNAP_ANCHORS=$((SNAP_ANCHORS + 1))
        iptables -t mangle -C INPUT -j "$Z2_FW_IN_CHAIN" >/dev/null 2>&1 &&
            SNAP_ANCHORS=$((SNAP_ANCHORS + 1))
        iptables -t mangle -C FORWARD -j "$Z2_FW_OUT_CHAIN" >/dev/null 2>&1 &&
            SNAP_ANCHORS=$((SNAP_ANCHORS + 1))
        iptables -t mangle -C FORWARD -j "$Z2_FW_IN_CHAIN" >/dev/null 2>&1 &&
            SNAP_ANCHORS=$((SNAP_ANCHORS + 1))
    fi
    if command -v ip6tables >/dev/null 2>&1 && owned_family_present ip6tables; then
        SNAP_IPV6=1
        SNAP_RULES=$((SNAP_RULES + $(count_family_rules ip6tables)))
        ip6tables -t mangle -S "$Z2_FW_OUT_CHAIN" >/dev/null 2>&1 &&
            SNAP_CHAINS=$((SNAP_CHAINS + 1))
        ip6tables -t mangle -S "$Z2_FW_IN_CHAIN" >/dev/null 2>&1 &&
            SNAP_CHAINS=$((SNAP_CHAINS + 1))
        ip6tables -t mangle -C OUTPUT -j "$Z2_FW_OUT_CHAIN" >/dev/null 2>&1 &&
            SNAP_ANCHORS=$((SNAP_ANCHORS + 1))
        ip6tables -t mangle -C INPUT -j "$Z2_FW_IN_CHAIN" >/dev/null 2>&1 &&
            SNAP_ANCHORS=$((SNAP_ANCHORS + 1))
        ip6tables -t mangle -C FORWARD -j "$Z2_FW_OUT_CHAIN" >/dev/null 2>&1 &&
            SNAP_ANCHORS=$((SNAP_ANCHORS + 1))
        ip6tables -t mangle -C FORWARD -j "$Z2_FW_IN_CHAIN" >/dev/null 2>&1 &&
            SNAP_ANCHORS=$((SNAP_ANCHORS + 1))
    elif { ! command -v ip6tables >/dev/null 2>&1 || ! z2_fw_tool_available ip6tables; } &&
         snapshot_ipv6_publication_recorded; then
        # An unqueryable frontend is not a disproof. Recording ipv6_active=0
        # here would publish "no IPv6 rules" as a fact, and a later stop reads
        # this snapshot to decide whether IPv6 needs teardown at all.
        SNAP_IPV6=1
        DIAGNOSTICS="${DIAGNOSTICS}IPv6 owned-state presence cannot be disproved because the ip6tables mangle table is unavailable; "
    fi
}

fail_start() {
    local message="$1" domain="${2:-LIFECYCLE}" code="${3:-LIFECYCLE_FAILED}"
    local stage="${4:-START}"
    z2_error_set "$domain" "$code" "$stage" "$message" ||
        z2_error_set LIFECYCLE LIFECYCLE_FAILED START "$message"
    trap '' HUP INT TERM
    log_error "$message"
    if [ "$CONTROLLED_TEARDOWN_STARTED" = 1 ] &&
       { [ "$FIREWALL_MUTATED" = 1 ] || [ "$NEW_PID_PUBLISHED" = 1 ] ||
         [ -n "$LAUNCHED_PID" ]; }; then
        rollback_start ||
            message="$message; rollback incomplete: $ROLLBACK_ERRORS"
    fi
    set_owner_phase error >/dev/null 2>&1 || true
    snapshot_owned_state
    restore_status_facts
    STATUS_RULES_OK=0; STATUS_RULES_FAIL=1; STATUS_RULES_TOTAL="$SNAP_RULES"
    STATUS_ERRORS="$message"; STATUS_OWN_PID="$SNAP_PID"; STATUS_OWN_ARGV_SHA256=""
    STATUS_PID_VERIFIED="$SNAP_PID_VERIFIED"; STATUS_QNUM="${QNUM:-${STATUS_QNUM:-}}"
    STATUS_OWN_PID_STARTTIME="$SNAP_PID_START"; STATUS_OWNER_GENERATION="$SNAP_GENERATION"
    STATUS_OWNER_METADATA_VERIFIED="$SNAP_PID_VERIFIED"; STATUS_RULESET_VERIFIED=0; STATUS_RULES_EXPECTED=0
    STATUS_IPV4_ACTIVE="$SNAP_IPV4"; STATUS_IPV6_ACTIVE="$SNAP_IPV6"; STATUS_CHAINS="$SNAP_CHAINS"; STATUS_ANCHORS="$SNAP_ANCHORS"
    STATUS_IPV4_RULES=0; STATUS_IPV6_RULES=0
    [ -n "${IPV4_NFQUEUE:-}" ] && STATUS_NFQUEUE_SUPPORTED="$IPV4_NFQUEUE"
    [ -n "${IPV4_QUEUE_BYPASS:-}" ] && STATUS_QUEUE_BYPASS_SUPPORTED="$IPV4_QUEUE_BYPASS"
    [ -n "${IPV4_CONNBYTES:-}" ] && STATUS_CONNBYTES_SUPPORTED="$IPV4_CONNBYTES"
    [ -n "${IPV4_MULTIPORT:-}" ] && STATUS_MULTIPORT_SUPPORTED="$IPV4_MULTIPORT"
    [ -n "${IPV4_MARK:-}" ] && STATUS_MARK_SUPPORTED="$IPV4_MARK"
    STATUS_FALLBACK_MODE="${FALLBACK_MODE:-0}"
    z2_error_set "$domain" "$code" "$stage" "$message" ||
        z2_error_set LIFECYCLE LIFECYCLE_FAILED START "$message"
    STATUS_ERROR_STATUS="$Z2_ERROR_STATUS"
    STATUS_ERROR_DOMAIN="$Z2_ERROR_DOMAIN"; STATUS_ERROR_CODE="$Z2_ERROR_CODE"
    STATUS_ERROR_STAGE="$Z2_ERROR_STAGE"; STATUS_ERROR_DETAIL="$Z2_ERROR_DETAIL"
    STATUS_DIAGNOSTICS="$DIAGNOSTICS"
    write_iptables_status error >/dev/null 2>&1 || true
    release_lifecycle_lock
    trap - HUP INT TERM
    z2_error_emit_machine
    echo "ERROR: $message"
    exit 1
}

handle_signal() {
    local signal="$1"
    fail_start "start interrupted by $signal" LIFECYCLE LIFECYCLE_FAILED START_SIGNAL 1
}

launch_nfqws2() {
    local candidate n=0 start
    LAUNCH_ERROR=""
    compiled_source_binding_current || {
        LAUNCH_ERROR="compiled preset source binding changed before launch"
        return 1
    }
    [ ! -e "$PIDFILE" ] && [ ! -L "$PIDFILE" ] || {
        LAUNCH_ERROR="PID file already exists before launch"
        return 1
    }
    # prepare_options already provisioned STARTUP_LOG/ERROR_LOG for this
    # transaction; re-preparing here would truncate the dry-run diagnostics.
    LAUNCH_OWNS_PIDFILE=1
    run_compiled_artifact "$COMPILED_ARGV_FILE" daemon || {
        LAUNCH_ERROR="nfqws2 rejected the compiled launch artifact"
        return 1
    }
    if proc_starttime_read "$LAUNCHED_PID" 2>/dev/null; then
        LAUNCHED_PID_START="$PROC_STARTTIME"
    else
        LAUNCHED_PID_START=""
    fi
    if [ -n "$LAUNCHED_PID_START" ]; then
        LAUNCHED_ARGV_SHA256="$(proc_cmdline_sha256 "$LAUNCHED_PID" 2>/dev/null)" || LAUNCHED_ARGV_SHA256=""
    fi
    # nfqws2 publishes its pidfile within milliseconds on a healthy start;
    # poll at 100 ms so a normal launch is not rounded up to whole seconds.
    while [ "$n" -lt 100 ]; do
        candidate="$LAUNCHED_PID"
        if read_live_pidfile; then candidate="$LIVE_PIDFILE_PID"; else candidate=""; fi
        if [ -n "$candidate" ]; then
            if proc_starttime_read "$candidate"; then start="$PROC_STARTTIME"; else start=""; fi
            if [ -n "$start" ]; then
                if ! publish_nfqws_owner "$candidate" "$start" "$QNUM" active; then
                    LAUNCH_ERROR="nfqws2 PID appeared but exact owner publication failed"
                    n=$((n + 1)); sleep 0.1
                    continue
                fi
                NEW_PID_PUBLISHED=1
                PROCESS_CLEANUP_PREFLIGHT_PROVEN=0
                STARTED_PID="$candidate"; STARTED_PID_START="$VERIFIED_STARTTIME"
                return 0
            fi
        fi
        n=$((n + 1)); sleep 0.1
    done
    [ -n "$LAUNCH_ERROR" ] || LAUNCH_ERROR="nfqws2 did not publish a live PID within 10 seconds"
    return 1
}

stop_failed_fallback_launch() {
    local pid="$1" start argv_sha256 live_start rc=0
    [ -n "$pid" ] || return 0
    start="${LAUNCHED_PID_START:-}"
    argv_sha256="${LAUNCHED_ARGV_SHA256:-}"
    if [ -n "$start" ] && verify_nfqws_pid "$pid" "$start" "$argv_sha256" "$QNUM"; then
        stop_verified_nfqws_pid "$pid" "$start" "$argv_sha256" "$QNUM" >/dev/null 2>&1 || rc=1
    elif kill -0 "$pid" 2>/dev/null; then
        if proc_starttime_read "$pid" 2>/dev/null; then live_start="$PROC_STARTTIME"; else live_start=""; fi
        if [ "$live_start" = "$start" ]; then rc=1; fi
    fi
    # A daemon may have forked before publishing a usable PID file.  Exact
    # argv0/executable scanning is the mandatory second rollback identity.
    stop_all_exact_owned_nfqws >/dev/null 2>&1 || rc=1
    if [ "$LAUNCH_OWNS_PIDFILE" = 1 ] && state_file_is_secure "$PIDFILE"; then
        rm -f "$PIDFILE" 2>/dev/null || rc=1
    fi
    return "$rc"
}

main() {
    REPAIR_RUNTIME_ONLY=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --replace) REPLACE=1 ;;
            --repair-runtime-only) REPAIR_RUNTIME_ONLY=1 ;;
            *) echo "ERROR: unknown argument: $1"; exit 2 ;;
        esac
        shift
    done
    ensure_state_dir ||
        start_error_exit STATE STATE_UNAVAILABLE START_STATE 0 \
            "insecure or unavailable zapret2 state directory: $STATE_DIR"
    acquire_lifecycle_lock ||
        start_error_exit LIFECYCLE LIFECYCLE_BUSY START_LOCK 1 "zapret2 lifecycle is busy"
    if [ -e "$MODDIR/disable" ] || [ -L "$MODDIR/disable" ]; then
        release_lifecycle_lock
        start_error_exit LIFECYCLE MODULE_DISABLED START_PREFLIGHT 0 \
            "start blocked because the module is disabled; re-enable it in the root manager first"
    fi
    if module_removal_pending; then
        release_lifecycle_lock
        start_error_exit LIFECYCLE MODULE_REMOVAL_PENDING START_PREFLIGHT 0 \
            "start blocked because the root manager scheduled the module for removal"
    fi
    # This audit retires proven cross-boot publications under the lock, which
    # is why boot no longer needs a separate recovery cycle before it. The
    # authority to discard an unsafe state generation wholesale stays with the
    # boot entry point alone: service.sh runs that pass and retries the start.
    if ! audit_recovery_artifacts lifecycle; then
        release_lifecycle_lock
        start_error_exit LIFECYCLE RECOVERY_BLOCKED START_RECOVERY 0 \
            "${RECOVERY_ARTIFACT_DIAGNOSTIC:-recovery artifacts block start}$(recovery_block_remedy)"
    fi
    if ! uninstall_tombstone_allows_start; then
        message="start blocked by uninstall serialization: $UNINSTALL_TOMBSTONE_ERROR"
        release_lifecycle_lock
        start_error_exit LIFECYCLE UNINSTALL_BLOCKED START_UNINSTALL 1 "$message"
    fi

    # Authenticate the installer-owned generation before status/log/config or
    # firewall mutation. A malformed or replaced generation can never start a
    # teardown transaction.
    if ! read_install_generation_meta; then
        release_lifecycle_lock
        start_error_exit STATE STATE_UNAVAILABLE START_GENERATION 0 \
            "install generation metadata is missing, unsafe, or malformed"
    fi
    if [ "$REPAIR_RUNTIME_ONLY" = 1 ]; then
        if load_effective_core_config; then
            message="$(runtime_config_status_message)"
            release_lifecycle_lock || { echo "ERROR: runtime repair completed but lifecycle lock release failed"; exit 1; }
            echo "$message"
            exit 0
        fi
        message="runtime.ini repair failed: ${RUNTIME_CONFIG_ERROR:-invalid configuration}"
        release_lifecycle_lock >/dev/null 2>&1 || true
        echo "ERROR: $message"
        exit 1
    fi
    trap 'handle_signal HUP' HUP
    trap 'handle_signal INT' INT
    trap 'handle_signal TERM' TERM

    write_runtime_owner_marker ||
        fail_start "cannot publish secure runtime ownership marker" STATE STATE_UNAVAILABLE START_OWNER 0

    if ! prepare_lifecycle_log; then
        LOG_READY=0
        DIAGNOSTICS="${DIAGNOSTICS}lifecycle log unavailable or unsafe; "
        if command -v log >/dev/null 2>&1; then log -p w -t Zapret2 "Lifecycle file logging disabled: unsafe or unavailable path" 2>/dev/null; fi
    fi
    restore_status_facts

    load_config ||
        fail_start "configuration load failed: ${RUNTIME_CONFIG_ERROR:-invalid configuration}" \
            CONFIG CONFIG_INVALID START_CONFIG 0
    validate_config ||
        fail_start "invalid core firewall configuration" CONFIG CONFIG_INVALID START_CONFIG 0
    preflight_wifi_only ||
        fail_start "WIFI_ONLY cannot be safely scoped to a verified Wi-Fi interface" \
            CONFIG PREFLIGHT_FAILED START_WIFI 0

    if normal_health_ok; then
        if [ "$REPLACE" = 0 ]; then
            DIAGNOSTICS="already healthy; no process or firewall churn"
            # This path publishes a status without building anything, so the
            # capability facts have to come from the generation that did.
            # Leaving them unset would republish the defaults and claim
            # connbytes support the running ruleset may not have.
            IPV4_CONNBYTES="$OWNER_STATE_IPV4_CONNBYTES"
            IPV4_MULTIPORT="$OWNER_STATE_IPV4_MULTIPORT"
            IPV4_MARK="$OWNER_STATE_IPV4_MARK"
            IPV6_CONNBYTES="$OWNER_STATE_IPV6_CONNBYTES"
            FALLBACK_MODE=0
            if [ "$IPV4_CONNBYTES" != 1 ] ||
               { [ "$HEALTH_IPV6" = 1 ] && [ "$IPV6_CONNBYTES" != 1 ]; }; then
                FALLBACK_MODE=1
            fi
            write_ok_status "$HEALTH_RULES" "$HEALTH_PID" "$HEALTH_IPV6" || fail_start "cannot write lifecycle status"
            receipt_lifecycle_state=idle; receipt_owner_kind=none
            if [ "$LOCK_HELD" = inherited ]; then
                receipt_lifecycle_state=owned; receipt_owner_kind=android-mutation
            fi
            release_lifecycle_lock || fail_start "cannot release lifecycle ownership"
            trap - HUP INT TERM
            emit_committed_status_v6 ok "$receipt_lifecycle_state" "$receipt_owner_kind" || true
            echo "Zapret2 is already running (PID: $HEALTH_PID)"
            exit 0
        fi
        capture_fast_replace_baseline || FAST_REPLACE_BASELINE=0
    fi

    log_section "Preset preflight"
    prepare_options ||
        fail_start "nfqws2 preflight/dry-run failed" CONFIG PREFLIGHT_FAILED START_NFQWS_PREFLIGHT 0

    if prepare_fast_replace_candidate; then
        log_section "Daemon-only replacement"
        preflight_owned_process_cleanup ||
            fail_start "cannot authenticate the previous nfqws2 process: $PROCESS_CLEANUP_PREFLIGHT_ERROR" \
                PROCESS PROCESS_STOP_FAILED START_CLEANUP 0
        CONTROLLED_TEARDOWN_STARTED=1
        stop_pidfile_process ||
            fail_start "cannot stop verified previous nfqws2 process" \
                PROCESS PROCESS_STOP_FAILED START_CLEANUP 0
        # The verified firewall generation is retained. If the replacement
        # cannot be committed, rollback owns its removal so the steady state is
        # unambiguously stopped rather than firewall-only.
        FIREWALL_MUTATED=1
        log_section "nfqws2 launch"
        launch_nfqws2 ||
            fail_start "nfqws2 launch failed: ${LAUNCH_ERROR:-verified owner was not published}" \
                PROCESS PROCESS_LAUNCH_FAILED START_LAUNCH 1
        fast_replace_health_ok ||
            fail_start "daemon-only replacement ownership verification failed" \
                LIFECYCLE POSTCONDITION_FAILED START_VERIFY 0
        [ "$HEALTH_PID" = "$STARTED_PID" ] && [ "$HEALTH_PID_START" = "$STARTED_PID_START" ] ||
            fail_start "daemon-only replacement PID identity changed"

        TOTAL_RULES=$((IPV4_RULES + IPV6_RULES))
        DIAGNOSTICS="${DIAGNOSTICS}verified firewall topology unchanged; retained existing ruleset; "
        write_ok_status "$TOTAL_RULES" "$STARTED_PID" "$IPV6_ACTIVE" ||
            fail_start "cannot atomically write lifecycle status"
        LAUNCHED_PID=""
        receipt_lifecycle_state=idle; receipt_owner_kind=none
        if [ "$LOCK_HELD" = inherited ]; then
            receipt_lifecycle_state=owned; receipt_owner_kind=android-mutation
        fi
        release_lifecycle_lock || fail_start "cannot release lifecycle ownership"
        FIREWALL_MUTATED=0
        trap - HUP INT TERM
        log_msg "Zapret2 daemon replaced with verified PID $STARTED_PID; firewall retained"
        emit_committed_status_v6 ok "$receipt_lifecycle_state" "$receipt_owner_kind" || true
        echo "Zapret2 restarted (PID: $STARTED_PID; firewall unchanged)"
        exit 0
    fi

    log_section "Firewall transaction"
    command -v z2_fw_reconcile_family >/dev/null 2>&1 ||
        fail_start "firewall reconciler is unavailable" \
            FIREWALL FIREWALL_BACKEND_UNAVAILABLE START_FIREWALL_BACKEND 0
    z2_fw_restore_available iptables ||
        fail_start "iptables-restore is required by the Android firewall backend" \
            FIREWALL FIREWALL_BACKEND_UNAVAILABLE START_FIREWALL_BACKEND 0
    audit_owned_firewall_for_cleanup ||
        fail_start "stable firewall namespace cleanup is unsafe: $FIREWALL_CLEANUP_PREFLIGHT_ERROR" \
            FIREWALL FIREWALL_CLEANUP_FAILED START_CLEANUP 0
    preflight_owned_process_cleanup ||
        fail_start "cannot authenticate the previous nfqws2 process: $PROCESS_CLEANUP_PREFLIGHT_ERROR" \
            PROCESS PROCESS_STOP_FAILED START_CLEANUP 0

    # From this point failures converge to the clean stopped state. Kernel
    # firewall state is derived entirely from the validated preset and is
    # never restored from a boot-local transaction journal.
    CONTROLLED_TEARDOWN_STARTED=1
    FIREWALL_MUTATED=1
    stop_pidfile_process ||
        fail_start "cannot stop verified previous nfqws2 process" \
            PROCESS PROCESS_STOP_FAILED START_CLEANUP 0
    OWNER_WRITE_READY=0; OWNER_WRITE_QNUM=""; OWNER_WRITE_SOURCE_GENERATION=""
    prepare_new_firewall_identity ||
        fail_start "cannot initialize stable firewall ownership" \
            FIREWALL PREFLIGHT_FAILED START_IDENTITY 0

    IPV4_NFQUEUE=1; IPV4_QUEUE_BYPASS=1; IPV4_MULTIPORT=1; IPV4_MARK=1
    if ! z2_fw_reconcile_family iptables audited; then
        fail_start "atomic IPv4 firewall publication failed: ${Z2_FW_ERROR_DETAIL:-unknown firewall backend failure}" \
            FIREWALL "$(firewall_failure_code)" START_FIREWALL_IPV4 1
    fi
    IPV4_CONNBYTES="$Z2_FW_CONNBYTES"
    # Published, not assumed. This field used to be a constant 1 while the
    # ruleset was authored with -m multiport unconditionally, so a kernel
    # without xt_multiport could not start at all and the record still claimed
    # the extension had been used.
    IPV4_MULTIPORT="$Z2_FW_MULTIPORT"
    IPV4_RULES="$Z2_FW_RULES"; IPV4_BUILT=1; IPV4_ACTIVE=1
    FALLBACK_MODE=0
    if [ "$IPV4_CONNBYTES" != 1 ]; then
        FALLBACK_MODE=1
        DIAGNOSTICS="${DIAGNOSTICS}IPv4 connbytes unavailable; using outgoing-only interception; "
    fi
    if [ "$IPV4_MULTIPORT" != 1 ]; then
        FALLBACK_MODE=1
        DIAGNOSTICS="${DIAGNOSTICS}IPv4 multiport unavailable; one rule per port interval; "
    fi

    IPV6_ACTIVE=0; IPV6_BUILT=0; IPV6_RULES=0
    IPV6_CONNBYTES=0; IPV6_MULTIPORT=1; IPV6_MARK=1
    if z2_fw_tool_available ip6tables && z2_fw_restore_available ip6tables; then
        # From here on this transaction may have written IPv6 objects, whether
        # or not it goes on to verify them. Rollback must not read a failed
        # publication as "IPv6 was never touched".
        IPV6_TOUCHED=1
        if z2_fw_reconcile_family ip6tables audited; then
            IPV6_CONNBYTES="$Z2_FW_CONNBYTES"
            IPV6_MULTIPORT="$Z2_FW_MULTIPORT"
            IPV6_RULES="$Z2_FW_RULES"; IPV6_BUILT=1; IPV6_ACTIVE=1
            if [ "$IPV6_MULTIPORT" != 1 ]; then
                FALLBACK_MODE=1
                DIAGNOSTICS="${DIAGNOSTICS}IPv6 multiport unavailable; one rule per port interval; "
            fi
            if [ "$IPV6_CONNBYTES" != 1 ]; then
                FALLBACK_MODE=1
                DIAGNOSTICS="${DIAGNOSTICS}IPv6 connbytes unavailable; using outgoing-only interception; "
            fi
        else
            z2_fw_cleanup_family ip6tables >/dev/null 2>&1 ||
                fail_start "failed IPv6 publication could not converge to absent state"
            DIAGNOSTICS="${DIAGNOSTICS}IPv6 firewall publication failed; IPv6 skipped; "
        fi
    else
        DIAGNOSTICS="${DIAGNOSTICS}IPv6 restore backend unavailable; IPv6 skipped; "
    fi

    # Queue bypass keeps traffic flowing between atomic firewall publication
    # and the verified listener becoming ready.
    log_section "nfqws2 launch"
    launch_nfqws2 ||
        fail_start "nfqws2 launch failed: ${LAUNCH_ERROR:-verified owner was not published}" \
            PROCESS PROCESS_LAUNCH_FAILED START_LAUNCH 1

    log_section "Commit receipt"
    if ! {
        [ "${PUBLISHED_PID:-}" = "$STARTED_PID" ] &&
            [ "${PUBLISHED_START:-}" = "$STARTED_PID_START" ] &&
            [ "${PUBLISHED_GENERATION:-}" = "$PENDING_OWNER_GENERATION" ] &&
            [ "${PUBLISHED_IPV4_RULES:-}" = "$IPV4_RULES" ] &&
            [ "${PUBLISHED_IPV6_RULES:-}" = "$IPV6_RULES" ] &&
            [ "${PUBLISHED_IPV6_ACTIVE:-}" = "$IPV6_ACTIVE" ]
    }; then
        fail_start "published process/firewall receipt is internally inconsistent" \
            LIFECYCLE POSTCONDITION_FAILED START_COMMIT 0
    fi
    HEALTH_PID="$PUBLISHED_PID"
    HEALTH_PID_START="$PUBLISHED_START"
    HEALTH_GENERATION="$PUBLISHED_GENERATION"
    HEALTH_IPV6="$PUBLISHED_IPV6_ACTIVE"
    HEALTH_RULES=$((PUBLISHED_IPV4_RULES + PUBLISHED_IPV6_RULES))

    TOTAL_RULES=$((IPV4_RULES + IPV6_RULES))
    write_ok_status "$TOTAL_RULES" "$STARTED_PID" "$IPV6_ACTIVE" || fail_start "cannot atomically write lifecycle status"
    LAUNCHED_PID=""
    receipt_lifecycle_state=idle; receipt_owner_kind=none
    if [ "$LOCK_HELD" = inherited ]; then
        receipt_lifecycle_state=owned; receipt_owner_kind=android-mutation
    fi
    release_lifecycle_lock || fail_start "cannot release lifecycle ownership"
    FIREWALL_MUTATED=0
    trap - HUP INT TERM
    log_msg "Zapret2 started with verified PID $STARTED_PID"
    emit_committed_status_v6 ok "$receipt_lifecycle_state" "$receipt_owner_kind" || true
    echo "Zapret2 started (PID: $STARTED_PID)"
    exit 0
}

main "$@"
