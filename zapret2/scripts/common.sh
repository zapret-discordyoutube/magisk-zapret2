#!/system/bin/sh
# Shared lifecycle, configuration and ownership helpers for zapret2.
#
# Durability boundary:
# Files under STATE_DIR describe boot-local processes, kernel firewall state,
# lifecycle ownership, and bounded recovery evidence. Atomic rename makes those
# publications indivisible to same-boot readers and preserves evidence when a
# shell process exits or is killed. They must not call the global sync command:
# a reboot removes the processes and netfilter state they describe, while
# sync() flushes unrelated dirty data from every mounted filesystem.
#
# Persistent package, runtime-configuration, rollback, and purge transactions
# own their durability barriers in their dedicated mutation scripts.

ZAPRET_DIR="${ZAPRET_DIR:-$(dirname "$SCRIPT_DIR")}"
MODDIR="${MODDIR:-$(dirname "$ZAPRET_DIR")}"
FIREWALL_RECONCILER="$SCRIPT_DIR/firewall-reconciler.sh"
[ ! -r "$FIREWALL_RECONCILER" ] || . "$FIREWALL_RECONCILER"

umask 077

# Stable adapter-owned error protocol shared by module scripts and the Android
# app. The app validates only these bounds and displays all identity fields
# opaquely, so adding a future domain, stage or code does not require an APK.
Z2_ERROR_SCHEMA_VERSION=1
Z2_ERROR_DETAIL_MAX_BYTES=512

z2_error_token_is_valid() {
    [ -n "$1" ] && [ "${#1}" -le 64 ] || return 1
    case "$1" in *[!A-Z0-9_]*) return 1 ;; esac
}

z2_error_detail_normalize() {
    printf '%s' "$1" | tr '\r\n\t' '   ' | cut -b "1-$Z2_ERROR_DETAIL_MAX_BYTES"
}

z2_error_detail_is_valid() {
    local LC_ALL=C
    [ "${#1}" -le "$Z2_ERROR_DETAIL_MAX_BYTES" ] 2>/dev/null || return 1
    case "$1" in *[[:cntrl:]]*) return 1 ;; esac
    return 0
}

z2_error_fields_are_valid() {
    local status="$1" domain="$2" stage="$3" code="$4" detail="$5"
    case "$status" in OK|ERROR) ;; *) return 1 ;; esac
    z2_error_token_is_valid "$domain" && z2_error_token_is_valid "$stage" &&
        z2_error_token_is_valid "$code" && z2_error_detail_is_valid "$detail" || return 1
    if [ "$status" = OK ]; then
        [ "$domain" = NONE ] && [ "$stage" = NONE ] && [ "$code" = NONE ] &&
            [ -z "$detail" ]
    else
        [ "$domain" != NONE ] && [ "$stage" != NONE ] && [ "$code" != NONE ] &&
            [ -n "$detail" ]
    fi
}

z2_error_set() {
    local detail
    detail="$(z2_error_detail_normalize "$4")"
    z2_error_fields_are_valid ERROR "$1" "$3" "$2" "$detail" || return 1
    Z2_ERROR_STATUS=ERROR
    Z2_ERROR_DOMAIN="$1"
    Z2_ERROR_CODE="$2"
    Z2_ERROR_STAGE="$3"
    Z2_ERROR_DETAIL="$detail"
}

z2_error_clear() {
    Z2_ERROR_STATUS=OK
    Z2_ERROR_DOMAIN=NONE
    Z2_ERROR_STAGE=NONE
    Z2_ERROR_CODE=NONE
    Z2_ERROR_DETAIL=""
}

z2_error_emit_machine() {
    z2_error_fields_are_valid "${Z2_ERROR_STATUS:-}" "${Z2_ERROR_DOMAIN:-}" \
        "${Z2_ERROR_STAGE:-}" "${Z2_ERROR_CODE:-}" "${Z2_ERROR_DETAIL:-}" || return 1
    printf 'Z2_ERROR_SCHEMA=%s\n' "$Z2_ERROR_SCHEMA_VERSION"
    printf 'Z2_ERROR_STATUS=%s\n' "$Z2_ERROR_STATUS"
    printf 'Z2_ERROR_DOMAIN=%s\n' "$Z2_ERROR_DOMAIN"
    printf 'Z2_ERROR_STAGE=%s\n' "$Z2_ERROR_STAGE"
    printf 'Z2_ERROR_CODE=%s\n' "$Z2_ERROR_CODE"
    printf 'Z2_ERROR_DETAIL=%s\n' "$Z2_ERROR_DETAIL"
}

z2_error_clear

# All live privileged state is kept below one fixed root-only directory.  The
# old /data/local/tmp names are migration inputs only and are never normal
# lifecycle write/delete targets.
STATE_DIR="${STATE_DIR:-/data/adb/zapret2-state}"
# PID-suffixed scratch files live in one disposable subdirectory so recovery
# logic never has to reason about their names: boot recovery and uninstall
# may sweep the whole directory, and crash residue can never fence anything.
Z2_STATE_TMP="$STATE_DIR/tmp"
PIDFILE="$STATE_DIR/nfqws2.pid"
OWNER_STATE="$STATE_DIR/owner.meta"
LOGFILE="$STATE_DIR/nfqws2.log"
LOGFILE_PREVIOUS="$STATE_DIR/nfqws2.log.1"
LOG_MAX_BYTES=1048576
CMDLINE_FILE="$STATE_DIR/nfqws2.cmdline"
COMPILED_ARGV_FILE="$STATE_DIR/nfqws2.argv"
COMPILED_VALIDATION_RECEIPT="$STATE_DIR/nfqws2.argv.validated"
STARTUP_LOG="$STATE_DIR/nfqws2.startup.log"
ERROR_LOG="$STATE_DIR/nfqws2.error"
DEBUG_LOG="$STATE_DIR/nfqws2-debug.log"
RUNTIME_OWNER_MARKER="$STATE_DIR/runtime.owner"
STATUS_SNAPSHOT="$STATE_DIR/status.snapshot"
RUNTIME_METADATA_MAX_BYTES=262144
OWNER_STATE_MAX_BYTES=65536

RUNTIME_CONFIG="$ZAPRET_DIR/runtime.ini"

NFQWS2="$ZAPRET_DIR/nfqws2"
LISTS_DIR="$ZAPRET_DIR/lists"
PRESETS_DIR="$ZAPRET_DIR/presets"
STRATEGY_CATALOGS_DIR="$ZAPRET_DIR/strategy-catalogs"

ZAPRET2_OUT="ZAPRET2_OUT"
ZAPRET2_IN="ZAPRET2_IN"
ZAPRET2_PROBE="ZAPRET2_PROBE"
IPTABLES_STATUS="$STATUS_SNAPSHOT"
LIFECYCLE_LOCK="$STATE_DIR/lifecycle.lock"
LIFECYCLE_LOCK_OWNER="$LIFECYCLE_LOCK/owner"
LIFECYCLE_LOCK_REAPER="$STATE_DIR/lifecycle.lock.reaper"
LIFECYCLE_LOCK_REAPER_RECOVERY="$STATE_DIR/lifecycle.lock.reaper.recovery"
LIFECYCLE_LOCK_REAPER_RECOVERY_QUARANTINE="$STATE_DIR/lifecycle.lock.reaper.recovery.quarantine"
LIFECYCLE_LOCK_QUARANTINE="$STATE_DIR/lifecycle.lock.quarantine"
LIFECYCLE_LOCK_WAIT_SECONDS="${LIFECYCLE_LOCK_WAIT_SECONDS:-60}"
UNINSTALL_TOMBSTONE="$STATE_DIR/uninstall.tombstone"
UNINSTALL_TOMBSTONE_VERSION=1
PURGE_REQUEST="$STATE_DIR/purge.request"
FULL_ROLLBACK_TRANSACTION="$STATE_DIR/full-rollback.transaction"
FULL_ROLLBACK_META="$STATE_DIR/full-rollback.meta"
FULL_ROLLBACK_HOSTS_BACKUP="$STATE_DIR/hosts.rollback.backup"
FULL_ROLLBACK_VERSION=1
INSTALL_GENERATION_META="$ZAPRET_DIR/install-generation.meta"
INSTALL_GENERATION_VERSION=1
LEGACY_MIGRATION_MARKER="$STATE_DIR/legacy-direct-rules.migrated"
OWNER_STATE_VERSION=8
OWNER_STATE_V8_FIELD_SEQUENCE="version|pid|starttime|argv_sha256|qnum|exe|generation|boot_id|phase|install_generation|install_archive_sha256|firewall_tag|out_chain|in_chain|ports_tcp|ports_udp|stun_ports|tcp_pkt_out|tcp_pkt_in|udp_pkt_out|udp_pkt_in|desync_mark|ipv4_active|ipv6_active|ipv4_connbytes|ipv4_multiport|ipv4_mark|ipv6_connbytes|ipv6_multiport|ipv6_mark|ipv4_rules|ipv6_rules|ipv4_spec|ipv6_spec|firewall_fingerprint"
OBSOLETE_FIREWALL_WAL="$STATE_DIR/firewall-teardown.wal"

export STATE_DIR Z2_STATE_TMP PIDFILE OWNER_STATE LOGFILE LOGFILE_PREVIOUS CMDLINE_FILE COMPILED_ARGV_FILE
export COMPILED_VALIDATION_RECEIPT
export STARTUP_LOG ERROR_LOG DEBUG_LOG RUNTIME_OWNER_MARKER STATUS_SNAPSHOT
export LIFECYCLE_LOCK LIFECYCLE_LOCK_OWNER LIFECYCLE_LOCK_REAPER
export LIFECYCLE_LOCK_REAPER_RECOVERY LIFECYCLE_LOCK_REAPER_RECOVERY_QUARANTINE
export LIFECYCLE_LOCK_QUARANTINE UNINSTALL_TOMBSTONE
export PURGE_REQUEST
export FULL_ROLLBACK_TRANSACTION FULL_ROLLBACK_META FULL_ROLLBACK_HOSTS_BACKUP
export INSTALL_GENERATION_META LEGACY_MIGRATION_MARKER

CORE_CONFIG_SOURCE="defaults"
CORE_CONFIG_SOURCE_PATH="built-in defaults"
RUNTIME_CONFIG_STATUS="unknown"
RUNTIME_CONFIG_REASON=""
RUNTIME_CONFIG_ERROR=""
RUNTIME_CORE_REPAIR_MODE="defaults"
RUNTIME_CORE_REQUIRED_KEYS="schema_version config_format runtime_source autostart wifi_only debug qnum desync_mark active_preset nfqws_uid log_mode"

is_decimal() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_canonical_positive_decimal() {
    case "$1" in ""|0*|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

is_canonical_nonnegative_i64() {
    local value="$1" digits first rest
    case "$value" in 0) return 0 ;; ""|0*|*[!0-9]*) return 1 ;; esac
    digits=${#value}
    [ "$digits" -lt 19 ] 2>/dev/null && return 0
    [ "$digits" -eq 19 ] 2>/dev/null || return 1
    first=${value%"${value#?}"}
    rest=${value#?}
    [ "$first" -lt 9 ] 2>/dev/null && return 0
    [ "$first" -eq 9 ] 2>/dev/null && [ "$rest" -le 223372036854775807 ] 2>/dev/null
}

is_canonical_nfqws_id() {
    local value="$1" digits
    case "$value" in 0) return 0 ;; ""|0*|*[!0-9]*) return 1 ;; esac
    digits=${#value}
    [ "$digits" -lt 10 ] 2>/dev/null && return 0
    [ "$digits" -eq 10 ] 2>/dev/null && [ "$value" -le 2147483647 ] 2>/dev/null
}

path_uid_is_root() {
    local path="$1" uid listing
    if command -v stat >/dev/null 2>&1; then
        uid="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
        [ "$uid" = 0 ]
        return
    fi
    listing="$(ls -ldn "$path" 2>/dev/null)" || return 1
    set -- $listing
    [ "$#" -ge 4 ] && [ "$3" = 0 ]
}

state_dir_is_secure() {
    local metadata listing
    [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || return 1
    if command -v stat >/dev/null 2>&1; then
        metadata="$(stat -c '%u:%a' "$STATE_DIR" 2>/dev/null)" || return 1
        [ "$metadata" = 0:700 ]
        return
    fi
    path_uid_is_root "$STATE_DIR" || return 1
    listing="$(ls -ldn "$STATE_DIR" 2>/dev/null)" || return 1
    set -- $listing
    case "${1:-}" in drwx------*) return 0 ;; *) return 1 ;; esac
}

ensure_state_dir() {
    umask 077
    if [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
        [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || return 1
        path_uid_is_root "$STATE_DIR" || return 1
    else
        mkdir "$STATE_DIR" 2>/dev/null || return 1
    fi
    chmod 0700 "$STATE_DIR" 2>/dev/null || return 1
    state_dir_is_secure
}

state_path_is_managed_file() {
    local suffix
    case "$1" in
        "$STATE_DIR"/*)
            suffix="${1#"$STATE_DIR"/}"
            [ -n "$suffix" ] || return 1
            case "$suffix" in
                tmp/*)
                    suffix="${suffix#tmp/}"
                    [ -n "$suffix" ] || return 1
                    case "$suffix" in */*) return 1 ;; esac
                    return 0
                    ;;
                */*) return 1 ;;
            esac
            return 0
            ;;
        *) return 1 ;;
    esac
}

ensure_state_tmp_dir() {
    umask 077
    if [ ! -e "$Z2_STATE_TMP" ] && [ ! -L "$Z2_STATE_TMP" ]; then
        mkdir "$Z2_STATE_TMP" 2>/dev/null
    fi
    # Validate unconditionally: a losing mkdir race must never be accepted on
    # the strength of [ -d ] alone, which follows a symlink planted between
    # the existence test and the mkdir. chmod and stat follow symlinks too, so
    # re-assert the identity afterwards rather than trusting the pre-check.
    [ -d "$Z2_STATE_TMP" ] && [ ! -L "$Z2_STATE_TMP" ] || return 1
    chmod 0700 "$Z2_STATE_TMP" 2>/dev/null || return 1
    [ -d "$Z2_STATE_TMP" ] && [ ! -L "$Z2_STATE_TMP" ] || return 1
    path_uid_is_root "$Z2_STATE_TMP" || return 1
}

state_file_is_secure() {
    state_dir_is_secure || return 1
    state_path_is_managed_file "$1" || return 1
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    path_uid_is_root "$1"
}

observer_state_file_is_secure() {
    [ "${OBSERVER_STATE_DIR_VERIFIED:-0}" = 1 ] || return 1
    state_path_is_managed_file "$1" || return 1
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    path_uid_is_root "$1"
}

state_file_target_is_safe() {
    state_dir_is_secure || return 1
    state_path_is_managed_file "$1" || return 1
    [ ! -e "$1" ] && [ ! -L "$1" ] && return 0
    state_file_is_secure "$1"
}

if ! is_decimal "$LIFECYCLE_LOCK_WAIT_SECONDS" || [ "$LIFECYCLE_LOCK_WAIT_SECONDS" -lt 1 ] 2>/dev/null; then
    LIFECYCLE_LOCK_WAIT_SECONDS=60
fi

is_safe_token() {
    case "$1" in
        ""|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_lower_sha256() {
    [ "${#1}" -eq 64 ] 2>/dev/null || return 1
    case "$1" in *[!0-9a-f]*) return 1 ;; *) return 0 ;; esac
}

path_mode_is_0600() {
    local path="$1" mode listing
    if command -v stat >/dev/null 2>&1; then
        mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
        [ "$mode" = 600 ]
        return
    fi
    listing="$(ls -ldn "$path" 2>/dev/null)" || return 1
    set -- $listing
    case "${1:-}" in -rw-------*) return 0 ;; *) return 1 ;; esac
}

path_nlink_is_one() {
    local path="$1" links listing
    if command -v stat >/dev/null 2>&1; then
        links="$(stat -c '%h' "$path" 2>/dev/null)" || return 1
        [ "$links" = 1 ]
        return
    fi
    listing="$(ls -ldn "$path" 2>/dev/null)" || return 1
    set -- $listing
    [ "$#" -ge 2 ] && [ "$2" = 1 ]
}

INSTALL_META_GENERATION=""
INSTALL_META_ARCHIVE_SHA256=""
INSTALL_META_CACHED_PATH=""
read_install_generation_meta() {
    local path="${1:-$INSTALL_GENERATION_META}" key value version="" module="" generation="" archive="" seen="" size
    # The installer writes this record once and nothing rewrites it while the
    # module runs, so the parse is cached. The path checks are cheap and are
    # repeated on every call: callers use this as a postcondition, and a
    # postcondition that skips verification is not one.
    if [ -n "$INSTALL_META_CACHED_PATH" ] && [ "$INSTALL_META_CACHED_PATH" = "$path" ]; then
        [ -f "$path" ] && [ ! -L "$path" ] && path_uid_is_root "$path" &&
            path_mode_is_0600 "$path" && path_nlink_is_one "$path" || return 1
        return 0
    fi
    INSTALL_META_GENERATION=""; INSTALL_META_ARCHIVE_SHA256=""; INSTALL_META_CACHED_PATH=""
    [ -f "$path" ] && [ ! -L "$path" ] && path_uid_is_root "$path" &&
        path_mode_is_0600 "$path" && path_nlink_is_one "$path" || return 1
    size="$(wc -c < "$path" 2>/dev/null)" || return 1
    is_decimal "$size" && [ "$size" -gt 0 ] 2>/dev/null && [ "$size" -le 1024 ] 2>/dev/null || return 1
    while :; do
        key=""; value=""
        IFS='=' read -r key value || [ -n "$key$value" ] || break
        case "$key" in
            version) case "$seen" in *v*) return 1;; esac; version="$value"; seen="${seen}v" ;;
            module_dir) case "$seen" in *m*) return 1;; esac; module="$value"; seen="${seen}m" ;;
            generation) case "$seen" in *g*) return 1;; esac; generation="$value"; seen="${seen}g" ;;
            archive_sha256) case "$seen" in *a*) return 1;; esac; archive="$value"; seen="${seen}a" ;;
            *) return 1 ;;
        esac
    done < "$path"
    [ "${#seen}" -eq 4 ] 2>/dev/null && [ "$version" = "$INSTALL_GENERATION_VERSION" ] && [ "$module" = "$MODDIR" ] || return 1
    is_safe_token "$generation" && [ "${#generation}" -le 128 ] 2>/dev/null || return 1
    is_lower_sha256 "$archive" || return 1
    INSTALL_META_GENERATION="$generation"; INSTALL_META_ARCHIVE_SHA256="$archive"
    INSTALL_META_CACHED_PATH="$path"
}

RECOVERY_ARTIFACT_DIAGNOSTIC=""
RECOVERY_ARTIFACT_CLASS="clean"
RECOVERY_ARTIFACT_FIRST=""

CURRENT_BOOT_ID=""
STALE_OWNER_DIAGNOSTIC=""
STALE_OWNER_PUBLICATION_RETIRED=0
BOOT_RECOVERY_DIAGNOSTIC=""
BOOT_INCOMPATIBLE_STATE_RETIRED=0

is_valid_boot_id() {
    local value="$1"
    [ "${#value}" -eq 36 ] 2>/dev/null || return 1
    case "$value" in
        ????????-????-????-????-????????????) ;;
        *) return 1 ;;
    esac
    case "$value" in *[!0-9a-f-]*) return 1;; esac
}

read_current_boot_id() {
    local value
    IFS= read -r value < /proc/sys/kernel/random/boot_id 2>/dev/null || return 1
    is_valid_boot_id "$value" || return 1
    CURRENT_BOOT_ID="$value"
}

stale_owner_clean_ownership_proof() {
    local tool family_state canonical_nfqws effective_nfqws candidate checked=""
    effective_nfqws="${AUDIT_NFQWS2_OVERRIDE:-$NFQWS2}"
    scan_exact_owned_nfqws_for_path "$effective_nfqws" >/dev/null 2>&1 || return 1
    [ -z "$OWNED_SCAN_PIDS" ] || return 1
    canonical_nfqws="$MODDIR/zapret2/nfqws2"
    checked="|$effective_nfqws|"
    for candidate in "$canonical_nfqws" "$NFQWS2"; do
        case "$checked" in *"|$candidate|"*) continue;; esac
        scan_exact_owned_nfqws_for_path "$candidate" >/dev/null 2>&1 || return 1
        [ -z "$OWNED_SCAN_PIDS" ] || return 1
        checked="${checked}${candidate}|"
    done
    for tool in $STALE_OWNER_REQUIRED_TOOLS; do command -v "$tool" >/dev/null 2>&1 || return 1; done
    for tool in iptables ip6tables; do
        command -v "$tool" >/dev/null 2>&1 || continue
        owned_family_present "$tool" >/dev/null 2>&1
        family_state=$?
        case "$family_state" in 1) ;; *) return 1;; esac
    done
    return 0
}

caller_holds_exact_lifecycle_lock() {
    case "$LOCK_HELD" in 1|inherited) ;; *) return 1;; esac
    lock_owner_alive || return 1
    [ "$LOCK_FILE_PID" = "$LOCK_OWNER_PID" ] && [ "$LOCK_FILE_START" = "$LOCK_OWNER_START" ] &&
        [ "$LOCK_FILE_TOKEN" = "$LOCK_OWNER_TOKEN" ]
}

recover_stale_owner_publication() {
    local current_boot pidfile_pid
    STALE_OWNER_PUBLICATION_RETIRED=0
    { [ -e "$OWNER_STATE" ] || [ -L "$OWNER_STATE" ] || [ -e "$PIDFILE" ] || [ -L "$PIDFILE" ]; } || return 0
    # The owner record is the authenticated commit marker.  A bare pidfile can
    # never prove that a PID belongs to this installation.
    [ -e "$OWNER_STATE" ] && [ ! -L "$OWNER_STATE" ] && read_owner_state || {
        STALE_OWNER_DIAGNOSTIC="unauthenticated owner publication remains"
        return 1
    }
    if [ -e "$PIDFILE" ] || [ -L "$PIDFILE" ]; then
        [ ! -L "$PIDFILE" ] && state_file_is_secure "$PIDFILE" || {
            STALE_OWNER_DIAGNOSTIC="unsafe pidfile accompanies owner publication"
            return 1
        }
        IFS= read -r pidfile_pid < "$PIDFILE" 2>/dev/null || return 1
        is_decimal "$pidfile_pid" && [ "$pidfile_pid" = "$OWNER_STATE_PID" ] || {
            STALE_OWNER_DIAGNOSTIC="pidfile and owner publication disagree"
            return 1
        }
    fi
    read_current_boot_id || { STALE_OWNER_DIAGNOSTIC="current boot identity is unavailable"; return 1; }
    current_boot="$CURRENT_BOOT_ID"
    if [ "$OWNER_STATE_BOOT_ID" = "$current_boot" ]; then
        verify_nfqws_pid "$OWNER_STATE_PID" "$OWNER_STATE_START" "$OWNER_STATE_ARGV_SHA256" "$OWNER_STATE_QNUM" && return 0
        STALE_OWNER_DIAGNOSTIC="same-boot owner/PID ambiguity remains"
        return 1
    fi
    STALE_OWNER_REQUIRED_TOOLS=iptables
    [ "$OWNER_STATE_IPV6_ACTIVE" = 1 ] &&
        STALE_OWNER_REQUIRED_TOOLS="$STALE_OWNER_REQUIRED_TOOLS ip6tables"
    stale_owner_clean_ownership_proof || {
        STALE_OWNER_DIAGNOSTIC="cross-boot owner recovery lacks a clean process/firewall snapshot"
        return 1
    }
    # Audits before lock acquisition may classify this state, but only the
    # exact lifecycle-lock owner may retire published metadata.
    caller_holds_exact_lifecycle_lock || return 0
    if [ "${BOOT_STALE_RUNTIME_RECOVERY:-0}" = 1 ] &&
       { [ -e "$STATUS_SNAPSHOT" ] || [ -L "$STATUS_SNAPSHOT" ]; }; then
        state_file_is_secure "$STATUS_SNAPSHOT" &&
            path_mode_is_0600 "$STATUS_SNAPSHOT" && path_nlink_is_one "$STATUS_SNAPSHOT" || {
                STALE_OWNER_DIAGNOSTIC="stale status snapshot is unsafe"
                return 1
            }
    fi
    if [ -e "$PIDFILE" ]; then rm -f "$PIDFILE" || return 1; fi
    if [ "${BOOT_STALE_RUNTIME_RECOVERY:-0}" = 1 ] && [ -e "$STATUS_SNAPSHOT" ]; then
        rm -f "$STATUS_SNAPSHOT" || return 1
    fi
    rm -f "$OWNER_STATE" || return 1
    STALE_OWNER_PUBLICATION_RETIRED=1
    return 0
}

# Formats produced by older module generations have no live writers anymore:
# build/probe track journals, the firewall teardown WAL, and the legacy
# direct-rule migration marker with its snapshot artifacts. Reboot is the
# migration barrier — current code never coexists with a runtime that still
# writes them — so the only correct handling is deletion, and only the exact
# lifecycle-lock owner may do it.
retire_obsolete_state_artifacts() {
    local path restore_noglob=0
    caller_holds_exact_lifecycle_lock || return 0
    case "$-" in *f*) restore_noglob=1; set +f;; esac
    set -- "$OBSOLETE_FIREWALL_WAL" "$LEGACY_MIGRATION_MARKER" \
        "$STATE_DIR"/build-track.* "$STATE_DIR"/probe-track.* \
        "$STATE_DIR"/legacy-rollback.*
    [ "$restore_noglob" = 1 ] && set -f
    for path in "$@"; do
        { [ -e "$path" ] || [ -L "$path" ]; } || continue
        rm -f "$path" 2>/dev/null || return 1
    done
    if [ "${BOOT_STALE_RUNTIME_RECOVERY:-0}" = 1 ] &&
       { [ -e "$Z2_STATE_TMP" ] || [ -L "$Z2_STATE_TMP" ]; }; then
        rm -rf "$Z2_STATE_TMP" 2>/dev/null || return 1
    fi
    # Staging residue in the state root is swept by creator liveness on every
    # pass, including boot: the wholesale scratch removal above covers only
    # the scratch directory.
    retire_dead_scratch_files
}

# Scratch names all end in the PID of the process that created them, and the
# writers refuse a path that already exists — so residue from a killed
# operation would fence the next firewall transaction forever. Removing only
# entries whose creator is gone keeps a concurrent preset preview, which holds
# no lifecycle lock, safe.
retire_dead_scratch_files() {
    local path base owner restore_noglob=0
    case "$-" in *f*) restore_noglob=1; set +f;; esac
    # Atomic publications stage through "<target>.tmp.<pid>" in the state root,
    # so a process killed between the redirect and the rename leaves residue
    # there too — and an unknown child fences uninstall.
    if [ -d "$Z2_STATE_TMP" ] && [ ! -L "$Z2_STATE_TMP" ]; then
        set -- "$Z2_STATE_TMP"/* "$STATE_DIR"/*.tmp.*
    else
        set -- "$STATE_DIR"/*.tmp.*
    fi
    [ "$restore_noglob" = 1 ] && set -f
    for path in "$@"; do
        { [ -e "$path" ] || [ -L "$path" ]; } || continue
        base="${path##*/}"
        case "$base" in
            # Staging names are "<target>.tmp.<pid>" and may carry a token or
            # nonce after the PID, so the creator is the component that
            # follows ".tmp." — not the last one.
            *.tmp.*) owner="${base##*.tmp.}"; owner="${owner%%.*}" ;;
            # Scratch names end in the creator PID, optionally with ".error".
            *) owner="${base%.error}"; owner="${owner##*.}" ;;
        esac
        is_decimal "$owner" && [ "$owner" -gt 0 ] 2>/dev/null || continue
        [ ! -d "/proc/$owner" ] || continue
        rm -rf "$path" 2>/dev/null || return 1
    done
    return 0
}

enumerate_recovery_artifacts() {
    local artifact restore_noglob=0 rc=0
    case "$-" in *f*) restore_noglob=1; set +f;; esac
    for artifact in \
        "$UNINSTALL_TOMBSTONE" "$UNINSTALL_TOMBSTONE".tmp "$UNINSTALL_TOMBSTONE".tmp.* "$STATE_DIR"/.uninstall.tombstone.* \
        "$LIFECYCLE_LOCK_REAPER" "$LIFECYCLE_LOCK_REAPER".* \
        "$LIFECYCLE_LOCK_REAPER_RECOVERY" "$LIFECYCLE_LOCK_REAPER_RECOVERY".* \
        "$LIFECYCLE_LOCK_QUARANTINE" "$LIFECYCLE_LOCK_QUARANTINE".* \
        "$STATE_DIR"/lifecycle.lock.candidate.* "$STATE_DIR"/.lifecycle.lock.* \
        "$FULL_ROLLBACK_TRANSACTION" "$FULL_ROLLBACK_TRANSACTION".tmp "$FULL_ROLLBACK_TRANSACTION".tmp.* \
        "$STATE_DIR"/.full-rollback.transaction.* \
        "$FULL_ROLLBACK_META" "$FULL_ROLLBACK_META".tmp "$FULL_ROLLBACK_META".tmp.* \
        "$STATE_DIR"/.full-rollback.meta.* \
        "$FULL_ROLLBACK_HOSTS_BACKUP" "$FULL_ROLLBACK_HOSTS_BACKUP".tmp "$FULL_ROLLBACK_HOSTS_BACKUP".tmp.* \
        "$STATE_DIR"/.hosts.rollback.backup.*; do
        if [ -e "$artifact" ] || [ -L "$artifact" ]; then printf '%s\n' "$artifact" || { rc=1; break; }; fi
    done
    [ "$restore_noglob" = 1 ] && set -f
    return "$rc"
}

# Only an "unsafe" generation is retired by the boot pass. Rollback evidence is
# durable on purpose and survives every reboot, so telling the user to reboot
# would send them in circles.
recovery_block_remedy() {
    case "${RECOVERY_ARTIFACT_CLASS:-}" in
        unsafe) printf '%s' "; reboot to let boot recovery retire it" ;;
        rollback-partial) printf '%s' "; finish the interrupted full rollback, then reboot" ;;
        rollback-complete) printf '%s' "; a completed full rollback is pending — remove the module in your root manager first, then reinstall it" ;;
        *) ;;
    esac
}

audit_recovery_artifacts() {
    local scope="$1" AUDIT_NFQWS2_OVERRIDE="${2:-}" artifact
    local rollback_seen=0 unsafe_seen=0 rollback_meta=0 rollback_tx=0 rollback_extra=0
    RECOVERY_ARTIFACT_DIAGNOSTIC=""
    RECOVERY_ARTIFACT_CLASS=clean
    RECOVERY_ARTIFACT_FIRST=""
    case "$scope" in
        lifecycle|full-rollback|install|uninstall) ;;
        *) RECOVERY_ARTIFACT_DIAGNOSTIC="unknown recovery audit scope"; return 1 ;;
    esac
    retire_obsolete_state_artifacts || {
        RECOVERY_ARTIFACT_CLASS=unsafe
        RECOVERY_ARTIFACT_DIAGNOSTIC="obsolete state artifacts could not be retired"
        return 1
    }
    if ! recover_stale_owner_publication; then
        RECOVERY_ARTIFACT_CLASS=unsafe
        RECOVERY_ARTIFACT_DIAGNOSTIC="$STALE_OWNER_DIAGNOSTIC"
        return 1
    fi
    for artifact in $(enumerate_recovery_artifacts); do
        [ "$scope" = lifecycle ] && [ "$artifact" = "$UNINSTALL_TOMBSTONE" ] && continue
        [ "$scope" = uninstall ] && [ "$artifact" = "$UNINSTALL_TOMBSTONE" ] && continue
        if [ "$scope" = install ] && [ "$artifact" = "$UNINSTALL_TOMBSTONE" ]; then
            if state_file_is_secure "$UNINSTALL_TOMBSTONE" &&
               read_uninstall_tombstone &&
               [ "$UNINSTALL_FILE_MODULE" = "$MODDIR" ] &&
               ! uninstall_tombstone_owner_alive; then
                continue
            fi
            [ -n "$RECOVERY_ARTIFACT_FIRST" ] || RECOVERY_ARTIFACT_FIRST="$artifact"
            unsafe_seen=1
            continue
        fi
        [ -n "$RECOVERY_ARTIFACT_FIRST" ] || RECOVERY_ARTIFACT_FIRST="$artifact"
        if [ -L "$artifact" ] || ! path_uid_is_root "$artifact"; then
            unsafe_seen=1
            continue
        fi
        case "$artifact" in
            "$FULL_ROLLBACK_META")
                [ -f "$artifact" ] || unsafe_seen=1
                rollback_seen=1
                rollback_meta=1
                ;;
            "$FULL_ROLLBACK_TRANSACTION")
                [ -f "$artifact" ] || unsafe_seen=1
                rollback_seen=1
                rollback_tx=1
                ;;
            "$FULL_ROLLBACK_HOSTS_BACKUP")
                [ -f "$artifact" ] || unsafe_seen=1
                rollback_seen=1
                ;;
            "$FULL_ROLLBACK_HOSTS_BACKUP".tmp.*)
                rollback_seen=1
                if [ "$scope" = full-rollback ] && read_transaction >/dev/null 2>&1 &&
                   case "${artifact##*/}" in
                       "${FULL_ROLLBACK_HOSTS_BACKUP##*/}.tmp.${RB_TOKEN:-}."*) true ;;
                       *) false ;;
                   esac &&
                   state_file_is_secure "$artifact" && path_mode_is_0600 "$artifact"; then
                    :
                else
                    rollback_extra=1
                fi
                ;;
            "$FULL_ROLLBACK_META"*|"$FULL_ROLLBACK_TRANSACTION"*|"$FULL_ROLLBACK_HOSTS_BACKUP"*|"$STATE_DIR"/.full-rollback.*|"$STATE_DIR"/.hosts.rollback.*)
                rollback_seen=1
                rollback_extra=1
                ;;
            *) unsafe_seen=1 ;;
        esac
    done
    if [ "$unsafe_seen" = 1 ]; then
        RECOVERY_ARTIFACT_CLASS=unsafe
    elif [ "$rollback_seen" = 1 ]; then
        if [ "$rollback_meta" = 1 ] && [ "$rollback_tx" = 0 ] && [ "$rollback_extra" = 0 ]; then
            RECOVERY_ARTIFACT_CLASS=rollback-complete
        else
            RECOVERY_ARTIFACT_CLASS=rollback-partial
        fi
    else
        RECOVERY_ARTIFACT_CLASS=clean
    fi
    if [ "$RECOVERY_ARTIFACT_CLASS" = rollback-partial ] &&
       [ "$scope" = full-rollback ] && [ "$rollback_extra" = 0 ]; then
        return 0
    fi
    case "$RECOVERY_ARTIFACT_CLASS:$scope" in
        clean:*) return 0 ;;
        rollback-complete:lifecycle)
            [ -e "$UNINSTALL_TOMBSTONE" ] && [ ! -L "$UNINSTALL_TOMBSTONE" ] &&
                state_file_is_secure "$UNINSTALL_TOMBSTONE" &&
                uninstall_tombstone_allows_stop || {
                RECOVERY_ARTIFACT_DIAGNOSTIC="completed rollback lifecycle access requires the exact live uninstall owner"
                return 1
            }
            return 0
            ;;
        rollback-complete:full-rollback|rollback-complete:install|rollback-complete:uninstall)
            return 0
            ;;
        *)
            RECOVERY_ARTIFACT_DIAGNOSTIC="$RECOVERY_ARTIFACT_CLASS recovery state requires its exact owner: ${RECOVERY_ARTIFACT_FIRST:-unknown}"
            return 1
            ;;
    esac
}


# The root-manager boot entry point is the only boundary allowed to discard an
# incompatible state generation without parsing it.  The lifecycle lock proves
# that no current-boot mutation owns the directory, while a kernel reboot has
# already destroyed every process and netfilter object described by the old
# files.  Keep the exact held lock until normal release, but retire every other
# project-owned entry so unsupported schemas can never fence a fresh package.
discard_incompatible_boot_state() {
    local lock_name remaining
    [ "${BOOT_STALE_RUNTIME_RECOVERY:-0}" = 1 ] || return 1
    caller_holds_exact_lifecycle_lock || return 1
    state_dir_is_secure || return 1
    lock_name="${LIFECYCLE_LOCK##*/}"
    case "$lock_name" in ""|*/*) return 1 ;; esac
    find "$STATE_DIR" -mindepth 1 -maxdepth 1 ! -name "$lock_name" \
        -exec rm -rf {} + 2>/dev/null || return 1
    remaining="$(find "$STATE_DIR" -mindepth 1 -maxdepth 1 ! -name "$lock_name" \
        -print -quit 2>/dev/null)" || return 1
    [ -z "$remaining" ] || return 1
    BOOT_INCOMPATIBLE_STATE_RETIRED=1
    return 0
}

# Boot may need to retire state from the previous kernel even when the module
# is disabled or runtime autostart is off. Recognized current-schema state uses
# the strict recovery audit. State classified as unsafe is outside the current
# generation contract and is discarded wholesale by the boot-only boundary.
recover_boot_stale_runtime_state() {
    local rc=0 diagnostic=""
    BOOT_RECOVERY_DIAGNOSTIC=""
    BOOT_INCOMPATIBLE_STATE_RETIRED=0
    if [ ! -e "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ]; then
        return 0
    fi
    state_dir_is_secure || {
        BOOT_RECOVERY_DIAGNOSTIC="state directory is unsafe"
        return 1
    }
    [ "${LOCK_HELD:-0}" = 0 ] || {
        BOOT_RECOVERY_DIAGNOSTIC="unexpected inherited lifecycle lock"
        return 1
    }
    acquire_lifecycle_lock || {
        BOOT_RECOVERY_DIAGNOSTIC="lifecycle lock is busy or unsafe"
        return 1
    }
    BOOT_STALE_RUNTIME_RECOVERY=1
    if ! audit_recovery_artifacts lifecycle; then
        if [ "$RECOVERY_ARTIFACT_CLASS" = unsafe ] &&
           discard_incompatible_boot_state; then
            diagnostic=""
        else
            rc=1
            diagnostic="${RECOVERY_ARTIFACT_DIAGNOSTIC:-unsafe recovery state}"
        fi
    fi
    BOOT_STALE_RUNTIME_RECOVERY=0
    if ! release_lifecycle_lock; then
        rc=1
        [ -n "$diagnostic" ] || diagnostic="lifecycle lock release failed"
    fi
    if [ "$rc" -ne 0 ]; then
        BOOT_RECOVERY_DIAGNOSTIC="$diagnostic"
        return 1
    fi
    return 0
}

canonical_mark() {
    local value
    MARK_CANONICAL=""
    value="$(printf '0x%x' "$1" 2>/dev/null)" || return 1
    # Netfilter marks are unsigned 32-bit values. printf also accepts wider and
    # negative shell integers, so reject every canonical result above 8 hex
    # digits instead of letting Android and the runtime disagree later.
    case "$value" in
        0x[0-9a-f]|0x[0-9a-f][0-9a-f]|0x[0-9a-f][0-9a-f][0-9a-f]|0x[0-9a-f][0-9a-f][0-9a-f][0-9a-f]|0x[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]|0x[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]|0x[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]|0x[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
            MARK_CANONICAL="$value"
            ;;
        *) return 1 ;;
    esac
}

prepare_private_runtime_file() {
    local path="$1"
    ensure_state_dir || return 1
    state_file_target_is_safe "$path" || return 1
    umask 077
    : > "$path" || return 1
    chmod 0600 "$path" 2>/dev/null || return 1
    state_file_is_secure "$path"
}

write_private_runtime_line() {
    local path="$1" value="$2" tmp="$1.tmp.$$" size
    ensure_state_dir || return 1
    state_file_target_is_safe "$path" || return 1
    state_path_is_managed_file "$tmp" || return 1
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
    size="${#value}"
    [ "$size" -le "$RUNTIME_METADATA_MAX_BYTES" ] 2>/dev/null || return 1
    umask 077
    printf '%s\n' "$value" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

write_runtime_owner_marker() {
    local tmp="$RUNTIME_OWNER_MARKER.tmp.$$"
    ensure_state_dir || return 1
    state_file_target_is_safe "$RUNTIME_OWNER_MARKER" || return 1
    state_path_is_managed_file "$tmp" || return 1
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
    umask 077
    {
        echo "version=1"
        echo "module_dir=$MODDIR"
        echo "nfqws=$NFQWS2"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$RUNTIME_OWNER_MARKER" || { rm -f "$tmp"; return 1; }
}

read_runtime_owner_marker() {
    local key value version="" module="" nfqws=""
    state_file_is_secure "$RUNTIME_OWNER_MARKER" || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            version) version="$value" ;;
            module_dir) module="$value" ;;
            nfqws) nfqws="$value" ;;
        esac
    done < "$RUNTIME_OWNER_MARKER"
    [ "$version" = 1 ] && [ "$module" = "$MODDIR" ] && [ "$nfqws" = "$NFQWS2" ]
}

new_lifecycle_token() {
    local token=""
    if [ -r /proc/sys/kernel/random/uuid ]; then
        IFS= read -r token < /proc/sys/kernel/random/uuid 2>/dev/null || token=""
    fi
    if ! is_safe_token "$token"; then
        token="z2-$(date +%s 2>/dev/null)-$$-$(proc_starttime "$$" 2>/dev/null || echo 0)"
    fi
    printf '%s\n' "$token"
}

normalize_qnum() {
    local raw="$1" normalized
    QNUM_NORMALIZED=""
    is_decimal "$raw" || return 1
    normalized="$raw"
    while [ "${normalized#0}" != "$normalized" ]; do
        normalized="${normalized#0}"
    done
    [ -n "$normalized" ] || normalized=0
    [ "${#normalized}" -le 5 ] || return 1
    [ "$normalized" -ge 1 ] 2>/dev/null || return 1
    [ "$normalized" -le 65535 ] 2>/dev/null || return 1
    QNUM_NORMALIZED="$normalized"
    return 0
}

runtime_config_exists() {
    local size
    [ -f "$RUNTIME_CONFIG" ] && [ ! -L "$RUNTIME_CONFIG" ] && [ -r "$RUNTIME_CONFIG" ] &&
        path_uid_is_root "$RUNTIME_CONFIG" && path_nlink_is_one "$RUNTIME_CONFIG" &&
        runtime_config_mode_is_safe "$RUNTIME_CONFIG" || return 1
    size="$(wc -c < "$RUNTIME_CONFIG" 2>/dev/null)" || return 1
    is_decimal "$size" && [ "$size" -gt 0 ] 2>/dev/null &&
        [ "$size" -le "$RUNTIME_METADATA_MAX_BYTES" ] 2>/dev/null
}

runtime_config_mode_is_safe() {
    local path="$1" mode listing
    if command -v stat >/dev/null 2>&1; then
        mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
        case "$mode" in 600|644) return 0;; *) return 1;; esac
    fi
    listing="$(ls -ln "$path" 2>/dev/null)" || return 1
    set -- $listing
    case "${1:-}" in -rw-------*|-rw-r--r--*) return 0;; *) return 1;; esac
}

runtime_config_state_reason() {
    if [ -L "$RUNTIME_CONFIG" ]; then echo "unsafe-symlink"
    elif [ -e "$RUNTIME_CONFIG" ]; then echo "unreadable-or-unsafe"
    else echo "missing"
    fi
}

ensure_runtime_core_config() {
    RUNTIME_CONFIG_STATUS="unknown"
    RUNTIME_CONFIG_REASON=""
    RUNTIME_CONFIG_ERROR=""
    RUNTIME_CORE_REPAIR_MODE="defaults"
    if runtime_config_exists; then
        set_core_config_defaults
        if apply_runtime_core_overrides; then
            RUNTIME_CONFIG_STATUS="loaded"
            return 0
        fi
        RUNTIME_CONFIG_REASON="invalid-or-partial"
        set_core_config_defaults
    else
        RUNTIME_CONFIG_REASON="$(runtime_config_state_reason)"
        # Never replace an existing symlink, directory, device, or unreadable
        # file. Only a missing path or a readable regular runtime can heal.
        if [ -e "$RUNTIME_CONFIG" ] || [ -L "$RUNTIME_CONFIG" ]; then
            RUNTIME_CONFIG_STATUS="unavailable"
            [ -n "$RUNTIME_CONFIG_ERROR" ] || RUNTIME_CONFIG_ERROR="unsafe runtime.ini target"
            return 1
        fi
        set_core_config_defaults
    fi
    if regenerate_runtime_core_config; then
        RUNTIME_CONFIG_STATUS="regenerated"
        set_core_config_defaults
        apply_runtime_core_overrides || {
            RUNTIME_CONFIG_STATUS="unavailable"
            [ -n "$RUNTIME_CONFIG_ERROR" ] || RUNTIME_CONFIG_ERROR="regenerated runtime.ini failed validation"
            return 1
        }
        return 0
    fi
    [ -n "$RUNTIME_CONFIG_ERROR" ] || RUNTIME_CONFIG_ERROR="runtime.ini regeneration failed"
    RUNTIME_CONFIG_STATUS="unavailable"
    return 1
}

regenerate_runtime_core_config() {
    local runtime_tool="$SCRIPT_DIR/runtime-config.sh"
    [ -f "$runtime_tool" ] && [ ! -L "$runtime_tool" ] || return 1
    if runtime_config_exists; then
        sh "$runtime_tool" --repair "$RUNTIME_CONFIG" >/dev/null 2>&1 || return 1
    else
        sh "$runtime_tool" "$RUNTIME_CONFIG" >/dev/null 2>&1 || return 1
    fi
    runtime_config_exists
}

runtime_config_status_message() {
    case "$RUNTIME_CONFIG_STATUS" in
        loaded) echo "runtime.ini is present and authoritative: $RUNTIME_CONFIG" ;;
        regenerated) echo "runtime.ini was regenerated because it was $RUNTIME_CONFIG_REASON: $RUNTIME_CONFIG" ;;
        unavailable) echo "runtime.ini is unavailable ($RUNTIME_CONFIG_REASON): ${RUNTIME_CONFIG_ERROR:-validation failed}" ;;
        *) echo "Runtime config status: $RUNTIME_CONFIG_STATUS" ;;
    esac
}

core_config_source_message() { echo "Core config source: $CORE_CONFIG_SOURCE_PATH"; }

# Configuration parsing runs on the boot path and may inspect thousands of
# catalog lines.  Keep trimming in the current shell: spawning sed for every
# scalar makes validation take minutes on process-heavy Android devices.
trim_config_value_in_place() {
    CONFIG_VALUE_TRIMMED="$1"
    CONFIG_VALUE_TRIMMED="${CONFIG_VALUE_TRIMMED#"${CONFIG_VALUE_TRIMMED%%[![:space:]]*}"}"
    CONFIG_VALUE_TRIMMED="${CONFIG_VALUE_TRIMMED%"${CONFIG_VALUE_TRIMMED##*[![:space:]]}"}"
}

# Decode one INI/bootstrap scalar without eval, command substitution or escape
# expansion. Matching outer quotes are removed; unmatched quotes are rejected.
decode_config_value() {
    local value first last
    CONFIG_VALUE_DECODED=""
    case "$1" in *'
'*) return 1 ;; esac
    trim_config_value_in_place "$1"
    value="$CONFIG_VALUE_TRIMMED"
    [ -n "$value" ] || { CONFIG_VALUE_DECODED=""; return 0; }
    first="${value%"${value#?}"}"
    last="${value#"${value%?}"}"
    case "$first" in
        \"|\')
            [ "${#value}" -ge 2 ] || return 1
            [ "$last" = "$first" ] || return 1
            value="${value#?}"
            value="${value%?}"
            ;;
        *) case "$last" in \"|\') return 1 ;; esac ;;
    esac
    # The character class covers embedded CR/LF and every other control byte
    # without a command substitution for each parsed scalar.
    case "$value" in *[[:cntrl:]]*) return 1 ;; esac
    CONFIG_VALUE_DECODED="$value"
}

apply_core_config_key() {
    local key="$1" value="$2"
    case "$key" in
        autostart|AUTOSTART) case "$value" in 0|1) AUTOSTART="$value" ;; *) return 1;; esac ;;
        wifi_only|WIFI_ONLY) case "$value" in 0|1) WIFI_ONLY="$value" ;; *) return 1;; esac ;;
        debug|DEBUG) case "$value" in 0|1) DEBUG="$value" ;; *) return 1;; esac ;;
        qnum|QNUM) normalize_qnum "$value" || return 1; QNUM="$QNUM_NORMALIZED" ;;
        desync_mark|DESYNC_MARK) canonical_mark "$value" || return 1; DESYNC_MARK="$MARK_CANONICAL" ;;
        active_preset|ACTIVE_PRESET)
            is_safe_runtime_file_name "$value" || return 1
            case "$value" in _*|*.txt) ;; *) return 1 ;; esac
            case "$value" in _*) return 1 ;; esac
            ACTIVE_PRESET="$value"
            ;;
        nfqws_uid|NFQWS_UID)
            case "$value" in
                *:*)
                    case "${value#*:}" in *:*) return 1;; esac
                    is_canonical_nfqws_id "${value%%:*}" &&
                        is_canonical_nfqws_id "${value#*:}" || return 1
                    NFQWS_UID="$value"
                    ;;
                *) return 1 ;;
            esac
            ;;
        log_mode|LOG_MODE) case "$value" in android|file|syslog|none) LOG_MODE="$value" ;; *) return 1;; esac ;;
        *) return 1 ;;
    esac
}

is_safe_file_name_byte_length() {
    local value="$1"
    local LC_ALL=C
    [ "${#value}" -le 255 ] 2>/dev/null
}

is_safe_runtime_file_name() {
    local value="$1"
    [ -n "$value" ] && is_safe_file_name_byte_length "$value" || return 1
    trim_config_value_in_place "$value"
    [ "$value" = "$CONFIG_VALUE_TRIMMED" ] || return 1
    [ "$value" != . ] && [ "$value" != .. ] || return 1
    case "$value" in */*|*\\*|*\"*|*\'*) return 1;; esac
    case "$value" in *[[:cntrl:]]*) return 1 ;; esac
    return 0
}

set_core_config_defaults() {
    RUNTIME_SOURCE="builtin-defaults"
    AUTOSTART=1
    WIFI_ONLY=0
    DEBUG=0
    QNUM=200
    DESYNC_MARK=0x40000000
    ACTIVE_PRESET="Default v1 (game filter).txt"
    NFQWS_UID="0:0"
    LOG_MODE="none"
}

# WIFI_ONLY=1 was accepted by older releases even though the current firewall
# contract has no verified interface selector. Migrate it to the safe mode.
normalize_unsupported_wifi_only() {
    WIFI_ONLY_LEGACY_NORMALIZED=0
    case "${WIFI_ONLY:-}" in
        0) return 0 ;;
        1)
            WIFI_ONLY=0
            WIFI_ONLY_LEGACY_NORMALIZED=1
            return 0
            ;;
        *) return 1 ;;
    esac
}

apply_runtime_core_overrides() {
    runtime_config_exists || return 1
    local current_section="" line="" cr key value core_sections=0 seen_keys="|" required missing=""
    RUNTIME_CORE_REPAIR_MODE="defaults"
    cr="$(printf '\r')"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%"$cr"}"
        trim_config_value_in_place "$line"
        line="$CONFIG_VALUE_TRIMMED"
        case "$line" in
            ""|"#"*|";"*) continue ;;
            "["*"]")
                current_section="${line#[}"
                current_section="${current_section%]}"
                if [ "$current_section" = core ]; then
                    core_sections=$((core_sections + 1))
                    [ "$core_sections" -eq 1 ] || {
                        RUNTIME_CONFIG_ERROR="runtime.ini contains duplicate [core] sections"
                        return 1
                    }
                fi
                continue
                ;;
        esac
        [ "$current_section" = core ] || continue
        case "$line" in
            *=*)
                trim_config_value_in_place "${line%%=*}"
                key="$CONFIG_VALUE_TRIMMED"
                case "$key" in ""|*[!a-z0-9_-]*)
                    RUNTIME_CONFIG_ERROR="invalid runtime.ini [core] key: $key"
                    return 1
                    ;;
                esac
                value="${line#*=}"
                decode_config_value "$value" || {
                    RUNTIME_CONFIG_ERROR="invalid quoted value for [core] $key"
                    return 1
                }
                value="$CONFIG_VALUE_DECODED"
                ;;
            *)
                RUNTIME_CONFIG_ERROR="malformed runtime.ini [core] line"
                return 1
                ;;
        esac
        case "$seen_keys" in *"|$key|"*)
            RUNTIME_CONFIG_ERROR="duplicate runtime.ini [core] key: $key"
            return 1
            ;;
        esac
        seen_keys="${seen_keys}${key}|"
        case "$key" in
            schema_version)
                [ "$value" = 1 ] || { RUNTIME_CONFIG_ERROR="unsupported runtime.ini schema_version"; return 1; }
                ;;
            config_format)
                [ "$value" = runtime-v1 ] || { RUNTIME_CONFIG_ERROR="unsupported runtime.ini config_format"; return 1; }
                ;;
            runtime_source)
                case "$value" in ""|*[!A-Za-z0-9._-]*) RUNTIME_CONFIG_ERROR="invalid runtime.ini runtime_source"; return 1;; esac
                RUNTIME_SOURCE="$value"
                ;;
            autostart|wifi_only|debug|qnum|desync_mark|active_preset|nfqws_uid|log_mode)
                apply_core_config_key "$key" "$value" || {
                    if [ "$key" = qnum ]; then
                        RUNTIME_CONFIG_ERROR="qnum=$value, expected 1..65535"
                    else
                        RUNTIME_CONFIG_ERROR="$key=$value is invalid"
                    fi
                    return 1
                }
                ;;
            *)
                RUNTIME_CONFIG_ERROR="unsupported runtime.ini [core] key: $key"
                return 1
                ;;
        esac
    done < "$RUNTIME_CONFIG"

    [ "$core_sections" -eq 1 ] || {
        RUNTIME_CONFIG_ERROR="runtime.ini has no [core] section"
        return 1
    }
    for required in $RUNTIME_CORE_REQUIRED_KEYS; do
        case "$seen_keys" in *"|$required|"*) ;; *) missing="${missing}${missing:+,}$required" ;; esac
    done
    if [ -n "$missing" ]; then
        RUNTIME_CONFIG_ERROR="runtime.ini [core] is partial; missing: $missing"
        return 1
    fi

    if ! normalize_qnum "$QNUM"; then
        RUNTIME_CONFIG_ERROR="invalid [core] qnum '$QNUM' (expected decimal 1..65535)"
        return 1
    fi
    QNUM="$QNUM_NORMALIZED"
    return 0
}

runtime_config_error_code() {
    case "$1" in
        "unsupported runtime.ini schema_version") RUNTIME_CONFIG_ERROR_CODE=UNSUPPORTED_SCHEMA ;;
        "unsupported runtime.ini config_format") RUNTIME_CONFIG_ERROR_CODE=UNSUPPORTED_FORMAT ;;
        "runtime.ini contains duplicate [core] sections") RUNTIME_CONFIG_ERROR_CODE=DUPLICATE_CORE ;;
        "invalid runtime.ini [core] key:"*) RUNTIME_CONFIG_ERROR_CODE=INVALID_CORE_KEY ;;
        "invalid quoted value for [core]"*) RUNTIME_CONFIG_ERROR_CODE=INVALID_QUOTED_VALUE ;;
        "malformed runtime.ini [core] line") RUNTIME_CONFIG_ERROR_CODE=MALFORMED_CORE_LINE ;;
        "duplicate runtime.ini [core] key:"*) RUNTIME_CONFIG_ERROR_CODE=DUPLICATE_CORE_KEY ;;
        "invalid runtime.ini runtime_source") RUNTIME_CONFIG_ERROR_CODE=INVALID_RUNTIME_SOURCE ;;
        "unsupported runtime.ini [core] key:"*) RUNTIME_CONFIG_ERROR_CODE=UNKNOWN_CORE_KEY ;;
        "runtime.ini has no [core] section") RUNTIME_CONFIG_ERROR_CODE=MISSING_CORE ;;
        "runtime.ini [core] is partial;"*) RUNTIME_CONFIG_ERROR_CODE=INCOMPLETE_CORE ;;
        "invalid [core] qnum"*|"invalid [core] value for qnum"|qnum=*", expected 1..65535")
            RUNTIME_CONFIG_ERROR_CODE=INVALID_QNUM
            ;;
        "invalid [core] value for"*|*" is invalid")
            RUNTIME_CONFIG_ERROR_CODE=INVALID_CORE_VALUE
            ;;
        "runtime.ini is required for read-only status")
            RUNTIME_CONFIG_ERROR_CODE=RUNTIME_MISSING
            ;;
        *) RUNTIME_CONFIG_ERROR_CODE=CONFIG_INVALID ;;
    esac
}

load_effective_core_config() {
    set_core_config_defaults
    CORE_CONFIG_SOURCE="defaults"
    CORE_CONFIG_SOURCE_PATH="built-in defaults"
    if ensure_runtime_core_config; then
        CORE_CONFIG_SOURCE="runtime.ini"
        CORE_CONFIG_SOURCE_PATH="$RUNTIME_CONFIG"
        normalize_unsupported_wifi_only || return 1
        return 0
    fi
    return 1
}

# Status and diagnostics never create or migrate configuration and never read
# bootstrap inputs. A missing, partial, or invalid runtime is reported as such.
load_effective_core_config_readonly() {
    set_core_config_defaults
    CORE_CONFIG_SOURCE="defaults"
    CORE_CONFIG_SOURCE_PATH="built-in defaults"
    RUNTIME_CONFIG_ERROR=""
    if runtime_config_exists; then
        RUNTIME_CONFIG_REASON=""
        CORE_CONFIG_SOURCE="runtime.ini"
        CORE_CONFIG_SOURCE_PATH="$RUNTIME_CONFIG"
        if ! apply_runtime_core_overrides; then
            RUNTIME_CONFIG_STATUS="unavailable"
            RUNTIME_CONFIG_REASON="invalid-or-partial"
            return 1
        fi
        RUNTIME_CONFIG_STATUS="loaded"
        normalize_unsupported_wifi_only || return 1
        return 0
    fi

    RUNTIME_CONFIG_STATUS="unavailable"
    RUNTIME_CONFIG_REASON="$(runtime_config_state_reason)"
    RUNTIME_CONFIG_ERROR="runtime.ini is required for read-only status"
    return 1
}

proc_starttime() {
    local pid="$1" stat tail
    is_decimal "$pid" || return 1
    [ "$pid" -gt 0 ] 2>/dev/null || return 1
    [ -r "/proc/$pid/stat" ] || return 1
    IFS= read -r stat < "/proc/$pid/stat" || return 1
    tail="${stat##*) }"
    set -- $tail
    [ "$#" -ge 20 ] || return 1
    shift 19
    printf '%s\n' "$1"
}

LOCK_HELD=0
LOCK_OWNER_PID=""
LOCK_OWNER_START=""
LOCK_OWNER_TOKEN=""
LIFECYCLE_ACQUIRE_CANDIDATE=""
LIFECYCLE_ACQUIRE_TOKEN=""

read_lock_owner() {
    LOCK_FILE_PID=""; LOCK_FILE_START=""; LOCK_FILE_TOKEN=""
    LOCK_FILE_KIND=""; LOCK_FILE_BOOT=""; LOCK_FILE_MODULE=""
    state_dir_is_secure || return 1
    [ -d "$LIFECYCLE_LOCK" ] && [ ! -L "$LIFECYCLE_LOCK" ] || return 1
    [ -f "$LIFECYCLE_LOCK_OWNER" ] && [ ! -L "$LIFECYCLE_LOCK_OWNER" ] || return 1
    path_uid_is_root "$LIFECYCLE_LOCK_OWNER" && path_mode_is_0600 "$LIFECYCLE_LOCK_OWNER" &&
        path_nlink_is_one "$LIFECYCLE_LOCK_OWNER" || return 1
    local key value sequence="" version="" kind="" boot="" module=""
    while IFS='=' read -r key value; do
        sequence="${sequence}${sequence:+|}$key"
        case "$key" in
            pid) LOCK_FILE_PID="$value" ;;
            starttime) LOCK_FILE_START="$value" ;;
            token) LOCK_FILE_TOKEN="$value" ;;
            version) version="$value" ;;
            kind) kind="$value" ;;
            boot_id) boot="$value" ;;
            module_dir) module="$value" ;;
            *) return 1 ;;
        esac
    done < "$LIFECYCLE_LOCK_OWNER"
    is_decimal "$LOCK_FILE_PID" && [ "$LOCK_FILE_PID" -gt 0 ] 2>/dev/null &&
        is_decimal "$LOCK_FILE_START" && [ "$LOCK_FILE_START" -gt 0 ] 2>/dev/null &&
        is_safe_token "$LOCK_FILE_TOKEN" || return 1
    case "$sequence" in
        pid\|starttime\|token)
            [ -z "$version$kind$boot$module" ] || return 1
            LOCK_FILE_KIND=shell
            ;;
        version\|kind\|pid\|starttime\|boot_id\|token\|module_dir)
            [ "$version" = 1 ] && [ "$kind" = android-mutation ] &&
                is_valid_boot_id "$boot" && [ "$module" = "$MODDIR" ] || return 1
            LOCK_FILE_KIND=android-mutation
            LOCK_FILE_BOOT="$boot"
            LOCK_FILE_MODULE="$module"
            ;;
        *) return 1 ;;
    esac
    return 0
}

lock_owner_alive() {
    local actual
    read_lock_owner || return 1
    if [ "$LOCK_FILE_KIND" = android-mutation ]; then
        # Boot identity is part of the Android lease.  A proven mismatch is
        # stale even if the numeric PID was reused; an unavailable boot query
        # is unknown and therefore blocks cleanup rather than weakening it.
        read_current_boot_id || return 0
        [ "$LOCK_FILE_BOOT" = "$CURRENT_BOOT_ID" ] || return 1
    fi
    actual="$(proc_starttime "$LOCK_FILE_PID")" || return 1
    [ "$actual" = "$LOCK_FILE_START" ]
}

# Read-only, constant-cost lifecycle classification. Unlike lock_owner_alive,
# this preserves the distinction between a live owner, a proven stale owner,
# and ownership that cannot be authenticated safely.
classify_lifecycle_lock() {
    local actual
    LIFECYCLE_OBSERVED_STATE=idle
    LIFECYCLE_OBSERVED_KIND=none

    if [ ! -e "$LIFECYCLE_LOCK" ] && [ ! -L "$LIFECYCLE_LOCK" ]; then
        if [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
            state_dir_is_secure || {
                LIFECYCLE_OBSERVED_STATE=ambiguous
                LIFECYCLE_OBSERVED_KIND=unknown
            }
        fi
        return 0
    fi
    read_lock_owner || {
        LIFECYCLE_OBSERVED_STATE=ambiguous
        LIFECYCLE_OBSERVED_KIND=unknown
        return 0
    }
    LIFECYCLE_OBSERVED_KIND="$LOCK_FILE_KIND"
    if [ "$LOCK_FILE_KIND" = android-mutation ]; then
        read_current_boot_id || {
            LIFECYCLE_OBSERVED_STATE=ambiguous
            return 0
        }
        if [ "$LOCK_FILE_BOOT" != "$CURRENT_BOOT_ID" ]; then
            LIFECYCLE_OBSERVED_STATE=stale
            return 0
        fi
    fi
    actual="$(proc_starttime "$LOCK_FILE_PID" 2>/dev/null)" || {
        LIFECYCLE_OBSERVED_STATE=stale
        return 0
    }
    if [ "$actual" = "$LOCK_FILE_START" ]; then
        LIFECYCLE_OBSERVED_STATE=active
    else
        LIFECYCLE_OBSERVED_STATE=stale
    fi
    return 0
}

# Caller-relative identity check for a previously classified live Android lease.
# This is authentication only: observers never acquire, recover, or release the lock.
lifecycle_lock_is_owned_by_caller() {
    [ "$LIFECYCLE_OBSERVED_STATE" = active ] &&
        [ "$LOCK_FILE_KIND" = android-mutation ] &&
        [ -n "${ZAPRET2_LIFECYCLE_TOKEN:-}" ] &&
        [ "${ZAPRET2_LIFECYCLE_TOKEN:-}" = "$LOCK_FILE_TOKEN" ] &&
        [ "${ZAPRET2_LIFECYCLE_OWNER_PID:-}" = "$LOCK_FILE_PID" ] &&
        [ "${ZAPRET2_LIFECYCLE_OWNER_START:-}" = "$LOCK_FILE_START" ]
}

read_lifecycle_gate() {
    local key value
    GATE_FILE_PID=""; GATE_FILE_START=""; GATE_FILE_TOKEN=""
    state_file_is_secure "$LIFECYCLE_LOCK_REAPER" || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            pid) GATE_FILE_PID="$value" ;;
            starttime) GATE_FILE_START="$value" ;;
            token) GATE_FILE_TOKEN="$value" ;;
        esac
    done < "$LIFECYCLE_LOCK_REAPER"
    is_decimal "$GATE_FILE_PID" && is_decimal "$GATE_FILE_START" && is_safe_token "$GATE_FILE_TOKEN"
}

lifecycle_gate_alive() {
    local actual
    read_lifecycle_gate || return 1
    actual="$(proc_starttime "$GATE_FILE_PID")" || return 1
    [ "$actual" = "$GATE_FILE_START" ]
}

release_lifecycle_gate() {
    local token="$1"
    read_lifecycle_gate || return 1
    [ "$GATE_FILE_PID" = "$$" ] && [ "$GATE_FILE_TOKEN" = "$token" ] || return 1
    rm -f "$LIFECYCLE_LOCK_REAPER" 2>/dev/null
}

read_lifecycle_recovery_gate() {
    local key value
    RECOVERY_FILE_PID=""; RECOVERY_FILE_START=""; RECOVERY_FILE_TOKEN=""
    state_file_is_secure "$LIFECYCLE_LOCK_REAPER_RECOVERY" || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            pid) RECOVERY_FILE_PID="$value" ;;
            starttime) RECOVERY_FILE_START="$value" ;;
            token) RECOVERY_FILE_TOKEN="$value" ;;
        esac
    done < "$LIFECYCLE_LOCK_REAPER_RECOVERY"
    is_decimal "$RECOVERY_FILE_PID" && is_decimal "$RECOVERY_FILE_START" && is_safe_token "$RECOVERY_FILE_TOKEN"
}

lifecycle_recovery_gate_alive() {
    local actual
    read_lifecycle_recovery_gate || return 1
    actual="$(proc_starttime "$RECOVERY_FILE_PID")" || return 1
    [ "$actual" = "$RECOVERY_FILE_START" ]
}

release_lifecycle_recovery_gate() {
    local token="$1"
    read_lifecycle_recovery_gate || return 1
    [ "$RECOVERY_FILE_PID" = "$$" ] && [ "$RECOVERY_FILE_TOKEN" = "$token" ] || return 1
    rm -f "$LIFECYCLE_LOCK_REAPER_RECOVERY" 2>/dev/null
}

claim_lifecycle_recovery_gate() {
    local self_start="$1" token="$2" tmp="$LIFECYCLE_LOCK_REAPER_RECOVERY.tmp.$$.$token"
    local stale_pid stale_start stale_token quarantine
    umask 077
    printf 'pid=%s\nstarttime=%s\ntoken=%s\n' "$$" "$self_start" "$token" > "$tmp" || return 1
    chmod 0600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    if ln "$tmp" "$LIFECYCLE_LOCK_REAPER_RECOVERY" 2>/dev/null; then
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    read_lifecycle_recovery_gate || return 1
    lifecycle_recovery_gate_alive && return 1
    stale_pid="$RECOVERY_FILE_PID"; stale_start="$RECOVERY_FILE_START"; stale_token="$RECOVERY_FILE_TOKEN"
    sleep 1
    if ! read_lifecycle_recovery_gate || lifecycle_recovery_gate_alive ||
       [ "$RECOVERY_FILE_PID" != "$stale_pid" ] || [ "$RECOVERY_FILE_START" != "$stale_start" ] ||
       [ "$RECOVERY_FILE_TOKEN" != "$stale_token" ]; then
        return 1
    fi
    quarantine="$LIFECYCLE_LOCK_REAPER_RECOVERY_QUARANTINE.$$.$token"
    [ ! -e "$quarantine" ] || return 1
    mv "$LIFECYCLE_LOCK_REAPER_RECOVERY" "$quarantine" 2>/dev/null || return 1
    rm -f "$quarantine" 2>/dev/null || return 1
    return 1
}

claim_lifecycle_gate() {
    local self_start="$1" token="$2" tmp="$LIFECYCLE_LOCK_REAPER.tmp.$$.$token"
    local stale_pid stale_start stale_token
    while :; do
        if [ ! -e "$LIFECYCLE_LOCK_REAPER_RECOVERY" ]; then
            umask 077
            printf 'pid=%s\nstarttime=%s\ntoken=%s\n' "$$" "$self_start" "$token" > "$tmp" || return 1
            chmod 0600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
            if ln "$tmp" "$LIFECYCLE_LOCK_REAPER" 2>/dev/null; then
                rm -f "$tmp"
                if [ -e "$LIFECYCLE_LOCK_REAPER_RECOVERY" ]; then
                    release_lifecycle_gate "$token" >/dev/null 2>&1 || true
                    sleep 1
                    continue
                fi
                return 0
            fi
            rm -f "$tmp"
        fi
        lifecycle_gate_alive && return 1
        if claim_lifecycle_recovery_gate "$self_start" "$token"; then
            if read_lifecycle_gate; then
                stale_pid="$GATE_FILE_PID"; stale_start="$GATE_FILE_START"; stale_token="$GATE_FILE_TOKEN"
                sleep 1
                if read_lifecycle_gate && ! lifecycle_gate_alive &&
                   [ "$GATE_FILE_PID" = "$stale_pid" ] && [ "$GATE_FILE_START" = "$stale_start" ] &&
                   [ "$GATE_FILE_TOKEN" = "$stale_token" ]; then
                    rm -f "$LIFECYCLE_LOCK_REAPER" 2>/dev/null
                fi
            else
                # Atomic hard-link publication cannot expose a partial gate.
                # A stable malformed regular gate is therefore abandoned.
                sleep 1
                if [ -f "$LIFECYCLE_LOCK_REAPER" ] && [ ! -L "$LIFECYCLE_LOCK_REAPER" ] &&
                   ! read_lifecycle_gate; then
                    rm -f "$LIFECYCLE_LOCK_REAPER" 2>/dev/null
                fi
            fi
            release_lifecycle_recovery_gate "$token" >/dev/null 2>&1 || true
            continue
        fi
        return 1
    done
}

acquire_lifecycle_lock() {
    local attempts=0 self_start token owner_pid owner_start quarantine candidate
    local stale_kind stale_pid stale_start stale_token stale_boot stale_module
    ensure_state_dir || return 1
    self_start="$(proc_starttime "$$")" || return 1
    token="${ZAPRET2_LIFECYCLE_TOKEN:-}"
    owner_pid="${ZAPRET2_LIFECYCLE_OWNER_PID:-}"
    owner_start="${ZAPRET2_LIFECYCLE_OWNER_START:-}"

    # A child launched by either recognized lock holder can safely inherit the
    # exact live lock. Android preset mutations deliberately invoke lifecycle
    # replacement under their cross-process lease, so rejecting that known
    # owner would deadlock the child behind its own parent transaction. The
    # child may never remove the lock: the original holder owns cleanup.
    if is_safe_token "$token" && is_decimal "$owner_pid" && is_decimal "$owner_start" &&
       lock_owner_alive &&
       { [ "$LOCK_FILE_KIND" = shell ] || [ "$LOCK_FILE_KIND" = android-mutation ]; } &&
       [ "$LOCK_FILE_TOKEN" = "$token" ] &&
       [ "$LOCK_FILE_PID" = "$owner_pid" ] &&
       [ "$LOCK_FILE_START" = "$owner_start" ]; then
        LOCK_HELD=inherited
        LOCK_OWNER_PID="$owner_pid"
        LOCK_OWNER_START="$owner_start"
        LOCK_OWNER_TOKEN="$token"
        return 0
    fi

    token="$(new_lifecycle_token)" || return 1
    is_safe_token "$token" || return 1
    candidate="$LIFECYCLE_LOCK.candidate.$$.$token"
    LIFECYCLE_ACQUIRE_TOKEN="$token"
    LIFECYCLE_ACQUIRE_CANDIDATE="$candidate"
    [ ! -e "$candidate" ] || return 1
    mkdir "$candidate" 2>/dev/null || return 1
    umask 077
    if ! printf 'pid=%s\nstarttime=%s\ntoken=%s\n' "$$" "$self_start" "$token" > "$candidate/owner" ||
       ! chmod 0600 "$candidate/owner" 2>/dev/null; then
        rm -rf "$candidate" 2>/dev/null
        LIFECYCLE_ACQUIRE_CANDIDATE=""; LIFECYCLE_ACQUIRE_TOKEN=""
        return 1
    fi
    while [ "$attempts" -lt "$LIFECYCLE_LOCK_WAIT_SECONDS" ]; do
        if ! claim_lifecycle_gate "$self_start" "$token"; then
            attempts=$((attempts + 1)); sleep 1; continue
        fi
        if [ ! -e "$LIFECYCLE_LOCK" ] && [ ! -L "$LIFECYCLE_LOCK" ]; then
            if mv "$candidate" "$LIFECYCLE_LOCK" 2>/dev/null; then
                release_lifecycle_gate "$token" >/dev/null 2>&1 || true
                candidate=""
                LIFECYCLE_ACQUIRE_CANDIDATE=""; LIFECYCLE_ACQUIRE_TOKEN=""
                LOCK_HELD=1
                LOCK_OWNER_PID="$$"
                LOCK_OWNER_START="$self_start"
                LOCK_OWNER_TOKEN="$token"
                export ZAPRET2_LIFECYCLE_TOKEN="$token"
                export ZAPRET2_LIFECYCLE_OWNER_PID="$$"
                export ZAPRET2_LIFECYCLE_OWNER_START="$self_start"
                return 0
            fi
            release_lifecycle_gate "$token" >/dev/null 2>&1 || true
        elif ! read_lock_owner; then
            # Only an exact recognized owner schema may ever be reaped.  A
            # malformed, foreign, or future record remains a hard fail-closed
            # barrier for manual inspection.
            release_lifecycle_gate "$token" >/dev/null 2>&1 || true
        elif lock_owner_alive; then
            release_lifecycle_gate "$token" >/dev/null 2>&1 || true
        else
            # The gate excludes publishers and other reapers.  A second stable
            # exact stale-owner observation makes quarantine safe.
            stale_kind="$LOCK_FILE_KIND"; stale_pid="$LOCK_FILE_PID"; stale_start="$LOCK_FILE_START"
            stale_token="$LOCK_FILE_TOKEN"; stale_boot="$LOCK_FILE_BOOT"; stale_module="$LOCK_FILE_MODULE"
            sleep 1
            if read_lock_owner && ! lock_owner_alive &&
               [ "$LOCK_FILE_KIND" = "$stale_kind" ] && [ "$LOCK_FILE_PID" = "$stale_pid" ] &&
               [ "$LOCK_FILE_START" = "$stale_start" ] && [ "$LOCK_FILE_TOKEN" = "$stale_token" ] &&
               [ "$LOCK_FILE_BOOT" = "$stale_boot" ] && [ "$LOCK_FILE_MODULE" = "$stale_module" ]; then
                quarantine="$LIFECYCLE_LOCK_QUARANTINE.$$.$token"
                if [ ! -e "$quarantine" ] && mv "$LIFECYCLE_LOCK" "$quarantine" 2>/dev/null; then
                    release_lifecycle_gate "$token" >/dev/null 2>&1 || true
                    rm -rf "$quarantine" 2>/dev/null || true
                    attempts=$((attempts + 1))
                    continue
                fi
            fi
            release_lifecycle_gate "$token" >/dev/null 2>&1 || true
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    [ -z "$candidate" ] || rm -rf "$candidate" 2>/dev/null
    LIFECYCLE_ACQUIRE_CANDIDATE=""; LIFECYCLE_ACQUIRE_TOKEN=""
    return 1
}

# A caller with an early signal trap can use this while acquire_lifecycle_lock
# is waiting. Only the exact candidate/gates published by this PID and token
# are retired; an inherited or foreign lifecycle owner is never released.
abort_lifecycle_lock_acquire() {
    local candidate="$LIFECYCLE_ACQUIRE_CANDIDATE" token="$LIFECYCLE_ACQUIRE_TOKEN" owner
    if [ "$LOCK_HELD" = 1 ]; then
        release_lifecycle_lock >/dev/null 2>&1 || return 1
        LIFECYCLE_ACQUIRE_CANDIDATE=""; LIFECYCLE_ACQUIRE_TOKEN=""
        return 0
    fi
    if is_safe_token "$token"; then
        release_lifecycle_gate "$token" >/dev/null 2>&1 || true
        release_lifecycle_recovery_gate "$token" >/dev/null 2>&1 || true
    fi
    case "$candidate" in "$LIFECYCLE_LOCK.candidate.$$.$token") ;; *) return 1 ;; esac
    if [ -d "$candidate" ] && [ ! -L "$candidate" ]; then
        owner="$candidate/owner"
        if [ -f "$owner" ] && [ ! -L "$owner" ] && path_uid_is_root "$owner"; then
            rm -f "$owner" 2>/dev/null || return 1
        fi
        rmdir "$candidate" 2>/dev/null || return 1
    elif [ -e "$candidate" ] || [ -L "$candidate" ]; then
        return 1
    fi
    LIFECYCLE_ACQUIRE_CANDIDATE=""; LIFECYCLE_ACQUIRE_TOKEN=""
    return 0
}

release_lifecycle_lock() {
    local self_start token quarantine
    [ "$LOCK_HELD" = 1 ] || { LOCK_HELD=0; return 0; }
    self_start="$(proc_starttime "$$")" || return 1
    token="$LOCK_OWNER_TOKEN"
    claim_lifecycle_gate "$self_start" "$token" || return 1
    if read_lock_owner &&
       [ "$LOCK_FILE_PID" = "$LOCK_OWNER_PID" ] &&
       [ "$LOCK_FILE_START" = "$LOCK_OWNER_START" ] &&
       [ "$LOCK_FILE_TOKEN" = "$LOCK_OWNER_TOKEN" ]; then
        quarantine="$LIFECYCLE_LOCK_QUARANTINE.release.$$.$token"
        if [ ! -e "$quarantine" ] && mv "$LIFECYCLE_LOCK" "$quarantine" 2>/dev/null; then
            release_lifecycle_gate "$token" >/dev/null 2>&1 || true
            rm -rf "$quarantine" 2>/dev/null || true
            LOCK_HELD=0
            return 0
        fi
    fi
    release_lifecycle_gate "$token" >/dev/null 2>&1 || true
    # Preserve ownership state on failure so the caller's EXIT trap can retry
    # exact cleanup. Forgetting a still-published owner turns a recoverable
    # release error into a persistent lifecycle barrier.
    return 1
}

module_removal_pending() {
    [ -e "$MODDIR/remove" ] || [ -L "$MODDIR/remove" ]
}

read_uninstall_tombstone() {
    local key value version="" seen_version=0 seen_pid=0 seen_start=0
    local seen_token=0 seen_module=0
    UNINSTALL_FILE_PID=""; UNINSTALL_FILE_START=""
    UNINSTALL_FILE_TOKEN=""; UNINSTALL_FILE_MODULE=""
    state_file_is_secure "$UNINSTALL_TOMBSTONE" && [ -r "$UNINSTALL_TOMBSTONE" ] || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            version)
                [ "$seen_version" = 0 ] || return 1
                version="$value"; seen_version=1
                ;;
            pid)
                [ "$seen_pid" = 0 ] || return 1
                UNINSTALL_FILE_PID="$value"; seen_pid=1
                ;;
            starttime)
                [ "$seen_start" = 0 ] || return 1
                UNINSTALL_FILE_START="$value"; seen_start=1
                ;;
            token)
                [ "$seen_token" = 0 ] || return 1
                UNINSTALL_FILE_TOKEN="$value"; seen_token=1
                ;;
            module_dir)
                [ "$seen_module" = 0 ] || return 1
                UNINSTALL_FILE_MODULE="$value"; seen_module=1
                ;;
            *) return 1 ;;
        esac
    done < "$UNINSTALL_TOMBSTONE"
    [ "$seen_version:$seen_pid:$seen_start:$seen_token:$seen_module" = 1:1:1:1:1 ] || return 1
    [ "$version" = "$UNINSTALL_TOMBSTONE_VERSION" ] || return 1
    is_decimal "$UNINSTALL_FILE_PID" && [ "$UNINSTALL_FILE_PID" -gt 0 ] 2>/dev/null || return 1
    is_decimal "$UNINSTALL_FILE_START" || return 1
    is_safe_token "$UNINSTALL_FILE_TOKEN" || return 1
    [ "$UNINSTALL_FILE_MODULE" = "$MODDIR" ]
}

uninstall_tombstone_owner_alive() {
    local actual
    actual="$(proc_starttime "$UNINSTALL_FILE_PID")" || return 1
    [ "$actual" = "$UNINSTALL_FILE_START" ]
}

uninstall_environment_authorized() {
    is_safe_token "${ZAPRET2_UNINSTALL_TOKEN:-}" &&
        [ "${ZAPRET2_UNINSTALL_TOKEN:-}" = "$UNINSTALL_FILE_TOKEN" ] &&
        is_decimal "${ZAPRET2_UNINSTALL_OWNER_PID:-}" &&
        [ "${ZAPRET2_UNINSTALL_OWNER_PID:-}" = "$UNINSTALL_FILE_PID" ] &&
        is_decimal "${ZAPRET2_UNINSTALL_OWNER_START:-}" &&
        [ "${ZAPRET2_UNINSTALL_OWNER_START:-}" = "$UNINSTALL_FILE_START" ] &&
        lock_owner_alive &&
        [ "$LOCK_FILE_PID" = "$UNINSTALL_FILE_PID" ] &&
        [ "$LOCK_FILE_START" = "$UNINSTALL_FILE_START" ]
}

uninstall_tombstone_allows_start() {
    UNINSTALL_TOMBSTONE_ERROR=""; UNINSTALL_TOMBSTONE_DIAGNOSTIC=""
    if module_removal_pending; then
        UNINSTALL_TOMBSTONE_ERROR="Root-manager module removal marker is present: $MODDIR/remove"
        return 1
    fi
    { [ -e "$UNINSTALL_TOMBSTONE" ] || [ -L "$UNINSTALL_TOMBSTONE" ]; } || return 0
    UNINSTALL_TOMBSTONE_ERROR="uninstall tombstone blocks start/restart: $UNINSTALL_TOMBSTONE"
    return 1
}

uninstall_tombstone_allows_stop() {
    UNINSTALL_TOMBSTONE_ERROR=""; UNINSTALL_TOMBSTONE_DIAGNOSTIC=""
    { [ -e "$UNINSTALL_TOMBSTONE" ] || [ -L "$UNINSTALL_TOMBSTONE" ]; } || return 0
    read_uninstall_tombstone || {
        UNINSTALL_TOMBSTONE_ERROR="uninstall tombstone is malformed or unsafe"
        return 1
    }
    uninstall_tombstone_owner_alive || {
        UNINSTALL_TOMBSTONE_ERROR="uninstall tombstone owner is not alive"
        return 1
    }
    uninstall_environment_authorized || {
        UNINSTALL_TOMBSTONE_ERROR="stop caller lacks exact live uninstall ownership"
        return 1
    }
    UNINSTALL_TOMBSTONE_DIAGNOSTIC="stop authorized by exact live uninstall owner"
    return 0
}

pid_cmdline_has_arg() {
    local pid="$1" wanted="$2"
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\000' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fqx -- "$wanted"
}

proc_cmdline_sha256() {
    local pid="$1" value
    is_decimal "$pid" || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    value="$(sha256sum "/proc/$pid/cmdline" 2>/dev/null)" || return 1
    value="${value%% *}"
    is_lower_sha256 "$value" || return 1
    printf '%s\n' "$value"
}

proc_argv0() {
    local pid="$1" value
    is_decimal "$pid" || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    value="$(tr '\000' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n '1p')" || return 1
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

# Fast, fork-free prefilter for the recovery scan. Shell variables cannot retain
# NUL separators while reading cmdline, so an exact argv0 is
# guaranteed to retain this prefix. Prefix collisions are harmless: the
# candidate still goes through verify_nfqws_pid's full argv0/start/exe proof.
proc_cmdline_may_match_nfqws() {
    local pid="$1" runtime_nfqws2="${AUDIT_NFQWS2_OVERRIDE:-$NFQWS2}" cmdline=""
    is_decimal "$pid" || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    IFS= read -r cmdline < "/proc/$pid/cmdline" 2>/dev/null || [ -n "$cmdline" ] || return 1
    case "$cmdline" in "$runtime_nfqws2"*) return 0 ;; *) return 1 ;; esac
}

OWNER_STATE_PID=""
OWNER_STATE_START=""
OWNER_STATE_ARGV_SHA256=""
OWNER_STATE_QNUM=""
OWNER_STATE_EXE=""
OWNER_STATE_GENERATION=""
OWNER_STATE_PHASE=""
OWNER_STATE_SCHEMA_VERSION=""
OWNER_STATE_INSTALL_GENERATION=""
OWNER_STATE_INSTALL_ARCHIVE_SHA256=""
OWNER_STATE_PORTS_TCP=""; OWNER_STATE_PORTS_UDP=""; OWNER_STATE_STUN_PORTS=""
OWNER_STATE_TCP_PKT_OUT=""; OWNER_STATE_TCP_PKT_IN=""
OWNER_STATE_UDP_PKT_OUT=""; OWNER_STATE_UDP_PKT_IN=""; OWNER_STATE_DESYNC_MARK=""
OWNER_STATE_IPV4_ACTIVE=0; OWNER_STATE_IPV6_ACTIVE=0
OWNER_STATE_IPV4_CONNBYTES=0; OWNER_STATE_IPV4_MULTIPORT=0; OWNER_STATE_IPV4_MARK=0
OWNER_STATE_IPV6_CONNBYTES=0; OWNER_STATE_IPV6_MULTIPORT=0; OWNER_STATE_IPV6_MARK=0
OWNER_STATE_IPV4_RULES=0; OWNER_STATE_IPV6_RULES=0
OWNER_STATE_IPV4_SPEC=""; OWNER_STATE_IPV6_SPEC=""; OWNER_STATE_FIREWALL_FINGERPRINT=""
OWNER_WRITE_READY=0

normalize_owner_port_list() {
    local list="$1" item first last old_ifs result="" normalized
    OWNER_PORT_LIST_NORMALIZED=""
    [ -n "$list" ] || return 1
    case "$list" in *[!0-9,:]*|,*|*,|*,,*) return 1;; esac
    old_ifs="$IFS"; IFS=,; set -- $list; IFS="$old_ifs"; [ "$#" -gt 0 ] || return 1
    for item in "$@"; do
        case "$item" in
            *:*) first="${item%%:*}"; last="${item#*:}"; case "$last" in *:*) return 1;; esac
                is_decimal "$first" && is_decimal "$last" || return 1
                first="$(printf '%s' "$first" | sed 's/^0*//')"; last="$(printf '%s' "$last" | sed 's/^0*//')"; [ -n "$first" ] || first=0; [ -n "$last" ] || last=0
                [ "$first" -le 65535 ] 2>/dev/null && [ "$last" -le 65535 ] 2>/dev/null && [ "$first" -le "$last" ] 2>/dev/null || return 1
                normalized="$first:$last" ;;
            *) is_decimal "$item" || return 1; normalized="$(printf '%s' "$item" | sed 's/^0*//')"; [ -n "$normalized" ] || normalized=0
                [ "$normalized" -le 65535 ] 2>/dev/null || return 1 ;;
        esac
        result="${result}${result:+,}$normalized"
    done
    OWNER_PORT_LIST_NORMALIZED="$result"
}

normalize_owner_optional_port_list() {
    OWNER_PORT_LIST_NORMALIZED=""
    [ -z "$1" ] && return 0
    normalize_owner_port_list "$1"
}

owner_port_rule_count() {
    local old_ifs count
    [ -n "$1" ] || { printf '0\n'; return 0; }
    old_ifs="$IFS"; IFS=,; set -- $1; IFS="$old_ifs"; count=$#
    [ "$count" -gt 0 ] || return 1; printf '%s\n' "$count"
}

is_safe_firewall_identity() {
    local tag="$1" out="$2" inchain="$3"
    if [ "$tag" = stable0001 ]; then
        [ "$out" = ZAPRET2_OUT ] && [ "$inchain" = ZAPRET2_IN ]
        return
    fi
    case "$tag" in ""|*[!A-Za-z0-9]*) return 1;; esac
    [ "${#tag}" -eq 10 ] 2>/dev/null || return 1
    [ "$out" = "Z2O_$tag" ] && [ "$inchain" = "Z2I_$tag" ] && [ "${#out}" -le 28 ] 2>/dev/null
}

prepare_new_firewall_identity() {
    local token
    token="${ZAPRET2_LIFECYCLE_TOKEN:-}"
    if [ -n "$token" ]; then
        is_safe_token "$token" || return 1
    else
        token="$(new_lifecycle_token)" || return 1
    fi
    FIREWALL_TAG=stable0001
    ZAPRET2_OUT=ZAPRET2_OUT
    ZAPRET2_IN=ZAPRET2_IN
    PENDING_OWNER_GENERATION="$token"
    is_safe_firewall_identity "$FIREWALL_TAG" "$ZAPRET2_OUT" "$ZAPRET2_IN"
}

owner_build_family_spec() {
    printf 'family:%s;active:%s;tag:%s;outchain:%s;inchain:%s;qnum:%s;tcp:%s;udp:%s;stun:%s;tcp_out:%s;tcp_in:%s;udp_out:%s;udp_in:%s;mark:%s;connbytes:%s;multiport:%s;markcap:%s;rules:%s\n' \
        "$1" "$2" "$OWNER_WRITE_FIREWALL_TAG" "$OWNER_WRITE_OUT_CHAIN" "$OWNER_WRITE_IN_CHAIN" \
        "$OWNER_WRITE_QNUM" "$OWNER_WRITE_PORTS_TCP" "$OWNER_WRITE_PORTS_UDP" "$OWNER_WRITE_STUN_PORTS" \
        "$OWNER_WRITE_TCP_PKT_OUT" "$OWNER_WRITE_TCP_PKT_IN" \
        "$OWNER_WRITE_UDP_PKT_OUT" "$OWNER_WRITE_UDP_PKT_IN" \
        "$OWNER_WRITE_DESYNC_MARK" "$3" "$4" "$5" "$6"
}

owner_spec_fingerprint() {
    local value
    command -v sha256sum >/dev/null 2>&1 || return 1
    value="$(printf '%s\n%s\n' "$1" "$2" | sha256sum 2>/dev/null | awk '{print $1}')" || return 1
    is_lower_sha256 "$value" || return 1; printf '%s\n' "$value"
}

prepare_owner_generation_spec() {
    local ipv4_active="${1:-1}" ipv6_active="${2:-0}" tcp_count udp_count per_direction
    read_install_generation_meta || return 1
    is_safe_firewall_identity "${FIREWALL_TAG:-}" "${ZAPRET2_OUT:-}" "${ZAPRET2_IN:-}" || prepare_new_firewall_identity || return 1
    OWNER_WRITE_FIREWALL_TAG="$FIREWALL_TAG"; OWNER_WRITE_OUT_CHAIN="$ZAPRET2_OUT"; OWNER_WRITE_IN_CHAIN="$ZAPRET2_IN"
    normalize_qnum "${QNUM:-}" || return 1; OWNER_WRITE_QNUM="$QNUM_NORMALIZED"
    normalize_owner_optional_port_list "${PORTS_TCP:-}" || return 1; OWNER_WRITE_PORTS_TCP="$OWNER_PORT_LIST_NORMALIZED"
    normalize_owner_optional_port_list "${PORTS_UDP:-}" || return 1; OWNER_WRITE_PORTS_UDP="$OWNER_PORT_LIST_NORMALIZED"
    [ -n "$OWNER_WRITE_PORTS_TCP$OWNER_WRITE_PORTS_UDP" ] || return 1
    # Voice ports are already folded into the compiled UDP union.
    OWNER_WRITE_STUN_PORTS=0
    is_canonical_positive_decimal "${TCP_PKT_OUT:-}" || return 1; OWNER_WRITE_TCP_PKT_OUT="$TCP_PKT_OUT"
    is_canonical_positive_decimal "${TCP_PKT_IN:-}" || return 1; OWNER_WRITE_TCP_PKT_IN="$TCP_PKT_IN"
    is_canonical_positive_decimal "${UDP_PKT_OUT:-}" || return 1; OWNER_WRITE_UDP_PKT_OUT="$UDP_PKT_OUT"
    is_canonical_positive_decimal "${UDP_PKT_IN:-}" || return 1; OWNER_WRITE_UDP_PKT_IN="$UDP_PKT_IN"
    canonical_mark "${DESYNC_MARK:-}" || return 1; OWNER_WRITE_DESYNC_MARK="$MARK_CANONICAL"
    case "$ipv4_active:$ipv6_active" in 1:0|1:1) ;; *) return 1;; esac
    OWNER_WRITE_IPV4_ACTIVE="$ipv4_active"; OWNER_WRITE_IPV6_ACTIVE="$ipv6_active"
    OWNER_WRITE_IPV4_CONNBYTES="${IPV4_CONNBYTES:-1}"; OWNER_WRITE_IPV4_MULTIPORT="${IPV4_MULTIPORT:-1}"; OWNER_WRITE_IPV4_MARK="${IPV4_MARK:-1}"
    OWNER_WRITE_IPV6_CONNBYTES="${IPV6_CONNBYTES:-1}"; OWNER_WRITE_IPV6_MULTIPORT="${IPV6_MULTIPORT:-1}"; OWNER_WRITE_IPV6_MARK="${IPV6_MARK:-1}"
    case "$OWNER_WRITE_IPV4_CONNBYTES:$OWNER_WRITE_IPV4_MULTIPORT:$OWNER_WRITE_IPV4_MARK:$OWNER_WRITE_IPV6_CONNBYTES:$OWNER_WRITE_IPV6_MULTIPORT:$OWNER_WRITE_IPV6_MARK" in *[!01:]*) return 1;; esac
    tcp_count="$(owner_port_rule_count "$OWNER_WRITE_PORTS_TCP")" || return 1
    udp_count="$(owner_port_rule_count "$OWNER_WRITE_PORTS_UDP")" || return 1
    if [ "$OWNER_WRITE_IPV4_MULTIPORT" = 1 ]; then
        per_direction=0; [ -z "$OWNER_WRITE_PORTS_TCP" ] || per_direction=$((per_direction + 1)); [ -z "$OWNER_WRITE_PORTS_UDP" ] || per_direction=$((per_direction + 1))
    else per_direction=$((tcp_count + udp_count)); fi
    OWNER_WRITE_IPV4_RULES=$((per_direction * (1 + OWNER_WRITE_IPV4_CONNBYTES) * ipv4_active))
    if [ "$OWNER_WRITE_IPV6_MULTIPORT" = 1 ]; then
        per_direction=0; [ -z "$OWNER_WRITE_PORTS_TCP" ] || per_direction=$((per_direction + 1)); [ -z "$OWNER_WRITE_PORTS_UDP" ] || per_direction=$((per_direction + 1))
    else per_direction=$((tcp_count + udp_count)); fi
    OWNER_WRITE_IPV6_RULES=$((per_direction * (1 + OWNER_WRITE_IPV6_CONNBYTES) * ipv6_active))
    OWNER_WRITE_IPV4_SPEC="$(owner_build_family_spec ipv4 "$ipv4_active" "$OWNER_WRITE_IPV4_CONNBYTES" "$OWNER_WRITE_IPV4_MULTIPORT" "$OWNER_WRITE_IPV4_MARK" "$OWNER_WRITE_IPV4_RULES")"
    OWNER_WRITE_IPV6_SPEC="$(owner_build_family_spec ipv6 "$ipv6_active" "$OWNER_WRITE_IPV6_CONNBYTES" "$OWNER_WRITE_IPV6_MULTIPORT" "$OWNER_WRITE_IPV6_MARK" "$OWNER_WRITE_IPV6_RULES")"
    OWNER_WRITE_FIREWALL_FINGERPRINT="$(owner_spec_fingerprint "$OWNER_WRITE_IPV4_SPEC" "$OWNER_WRITE_IPV6_SPEC")" || return 1
    OWNER_WRITE_INSTALL_GENERATION="$INSTALL_META_GENERATION"; OWNER_WRITE_INSTALL_ARCHIVE_SHA256="$INSTALL_META_ARCHIVE_SHA256"; OWNER_WRITE_SOURCE_GENERATION=""; OWNER_WRITE_READY=1
}

owner_state_is_current_boot() {
    [ "$OWNER_STATE_SCHEMA_VERSION" = "$OWNER_STATE_VERSION" ] || return 1
    is_valid_boot_id "$OWNER_STATE_BOOT_ID" || return 1
    read_current_boot_id || return 1
    [ "$OWNER_STATE_BOOT_ID" = "$CURRENT_BOOT_ID" ]
}

read_owner_state() {
    local expected_nfqws2="${AUDIT_NFQWS2_OVERRIDE:-$NFQWS2}"
    OWNER_STATE_PID=""; OWNER_STATE_START=""; OWNER_STATE_ARGV_SHA256=""
    OWNER_STATE_QNUM=""; OWNER_STATE_EXE=""; OWNER_STATE_GENERATION=""; OWNER_STATE_BOOT_ID=""; OWNER_STATE_PHASE=""; OWNER_STATE_SCHEMA_VERSION=""
    OWNER_STATE_INSTALL_GENERATION=""; OWNER_STATE_INSTALL_ARCHIVE_SHA256=""
    OWNER_STATE_PORTS_TCP=""; OWNER_STATE_PORTS_UDP=""; OWNER_STATE_STUN_PORTS=""
    OWNER_STATE_TCP_PKT_OUT=""; OWNER_STATE_TCP_PKT_IN=""; OWNER_STATE_UDP_PKT_OUT=""; OWNER_STATE_UDP_PKT_IN=""; OWNER_STATE_DESYNC_MARK=""
    OWNER_STATE_IPV4_ACTIVE=""; OWNER_STATE_IPV6_ACTIVE=""; OWNER_STATE_IPV4_CONNBYTES=""; OWNER_STATE_IPV4_MULTIPORT=""; OWNER_STATE_IPV4_MARK=""
    OWNER_STATE_IPV6_CONNBYTES=""; OWNER_STATE_IPV6_MULTIPORT=""; OWNER_STATE_IPV6_MARK=""; OWNER_STATE_IPV4_RULES=""; OWNER_STATE_IPV6_RULES=""
    OWNER_STATE_IPV4_SPEC=""; OWNER_STATE_IPV6_SPEC=""; OWNER_STATE_FIREWALL_FINGERPRINT=""
    OWNER_STATE_FIREWALL_TAG=""; OWNER_STATE_OUT_CHAIN=""; OWNER_STATE_IN_CHAIN=""
    state_file_is_secure "$OWNER_STATE" && [ -r "$OWNER_STATE" ] || return 1
    local key value version="" tcp_count udp_count stun_count expected seen_keys="|" field_sequence="" size
    size="$(wc -c < "$OWNER_STATE" 2>/dev/null)" || return 1
    is_decimal "$size" && [ "$size" -gt 0 ] 2>/dev/null &&
        [ "$size" -le "$OWNER_STATE_MAX_BYTES" ] 2>/dev/null || return 1
    while IFS='=' read -r key value; do
        case "$seen_keys" in *"|$key|"*) return 1;; esac
        seen_keys="${seen_keys}${key}|"
        field_sequence="${field_sequence}${field_sequence:+|}$key"
        case "$key" in
            version) version="$value" ;;
            pid) OWNER_STATE_PID="$value" ;;
            starttime) OWNER_STATE_START="$value" ;;
            argv_sha256) OWNER_STATE_ARGV_SHA256="$value" ;;
            qnum) OWNER_STATE_QNUM="$value" ;;
            exe) OWNER_STATE_EXE="$value" ;;
            generation) OWNER_STATE_GENERATION="$value" ;;
            boot_id) OWNER_STATE_BOOT_ID="$value" ;;
            phase) OWNER_STATE_PHASE="$value" ;;
            install_generation) OWNER_STATE_INSTALL_GENERATION="$value" ;;
            install_archive_sha256) OWNER_STATE_INSTALL_ARCHIVE_SHA256="$value" ;;
            firewall_tag) OWNER_STATE_FIREWALL_TAG="$value" ;;
            out_chain) OWNER_STATE_OUT_CHAIN="$value" ;;
            in_chain) OWNER_STATE_IN_CHAIN="$value" ;;
            ports_tcp) OWNER_STATE_PORTS_TCP="$value" ;;
            ports_udp) OWNER_STATE_PORTS_UDP="$value" ;;
            stun_ports) OWNER_STATE_STUN_PORTS="$value" ;;
            tcp_pkt_out) OWNER_STATE_TCP_PKT_OUT="$value" ;;
            tcp_pkt_in) OWNER_STATE_TCP_PKT_IN="$value" ;;
            udp_pkt_out) OWNER_STATE_UDP_PKT_OUT="$value" ;;
            udp_pkt_in) OWNER_STATE_UDP_PKT_IN="$value" ;;
            desync_mark) OWNER_STATE_DESYNC_MARK="$value" ;;
            ipv4_active) OWNER_STATE_IPV4_ACTIVE="$value" ;;
            ipv6_active) OWNER_STATE_IPV6_ACTIVE="$value" ;;
            ipv4_connbytes) OWNER_STATE_IPV4_CONNBYTES="$value" ;;
            ipv4_multiport) OWNER_STATE_IPV4_MULTIPORT="$value" ;;
            ipv4_mark) OWNER_STATE_IPV4_MARK="$value" ;;
            ipv6_connbytes) OWNER_STATE_IPV6_CONNBYTES="$value" ;;
            ipv6_multiport) OWNER_STATE_IPV6_MULTIPORT="$value" ;;
            ipv6_mark) OWNER_STATE_IPV6_MARK="$value" ;;
            ipv4_rules) OWNER_STATE_IPV4_RULES="$value" ;;
            ipv6_rules) OWNER_STATE_IPV6_RULES="$value" ;;
            ipv4_spec) OWNER_STATE_IPV4_SPEC="$value" ;;
            ipv6_spec) OWNER_STATE_IPV6_SPEC="$value" ;;
            firewall_fingerprint) OWNER_STATE_FIREWALL_FINGERPRINT="$value" ;;
            *) return 1 ;;
        esac
    done < "$OWNER_STATE"
    [ "$version" = "$OWNER_STATE_VERSION" ] &&
        [ "$field_sequence" = "$OWNER_STATE_V8_FIELD_SEQUENCE" ] || return 1
    OWNER_STATE_SCHEMA_VERSION="$OWNER_STATE_VERSION"
    is_canonical_positive_decimal "$OWNER_STATE_PID" &&
        is_canonical_nonnegative_i64 "$OWNER_STATE_START" || return 1
    normalize_qnum "$OWNER_STATE_QNUM" || return 1
    OWNER_STATE_QNUM="$QNUM_NORMALIZED"
    [ "$OWNER_STATE_EXE" = "$expected_nfqws2" ] || return 1
    is_lower_sha256 "$OWNER_STATE_ARGV_SHA256" || return 1
    is_safe_token "$OWNER_STATE_GENERATION" || return 1
    is_valid_boot_id "$OWNER_STATE_BOOT_ID" || return 1
    case "$OWNER_STATE_PHASE" in launched|active|stopping|error) ;; *) return 1 ;; esac
    is_safe_token "$OWNER_STATE_INSTALL_GENERATION" && [ "${#OWNER_STATE_INSTALL_GENERATION}" -le 128 ] 2>/dev/null || return 1
    is_lower_sha256 "$OWNER_STATE_INSTALL_ARCHIVE_SHA256" || return 1
    is_safe_firewall_identity "$OWNER_STATE_FIREWALL_TAG" "$OWNER_STATE_OUT_CHAIN" "$OWNER_STATE_IN_CHAIN" || return 1
    OWNER_WRITE_FIREWALL_TAG="$OWNER_STATE_FIREWALL_TAG"; OWNER_WRITE_OUT_CHAIN="$OWNER_STATE_OUT_CHAIN"; OWNER_WRITE_IN_CHAIN="$OWNER_STATE_IN_CHAIN"
    normalize_owner_optional_port_list "$OWNER_STATE_PORTS_TCP" || return 1; [ "$OWNER_PORT_LIST_NORMALIZED" = "$OWNER_STATE_PORTS_TCP" ] || return 1
    normalize_owner_optional_port_list "$OWNER_STATE_PORTS_UDP" || return 1; [ "$OWNER_PORT_LIST_NORMALIZED" = "$OWNER_STATE_PORTS_UDP" ] || return 1
    [ -n "$OWNER_STATE_PORTS_TCP$OWNER_STATE_PORTS_UDP" ] || return 1
    [ "$OWNER_STATE_STUN_PORTS" = 0 ] || return 1
    is_canonical_positive_decimal "$OWNER_STATE_TCP_PKT_OUT" && [ "${#OWNER_STATE_TCP_PKT_OUT}" -le 9 ] 2>/dev/null || return 1
    is_canonical_positive_decimal "$OWNER_STATE_TCP_PKT_IN" && [ "${#OWNER_STATE_TCP_PKT_IN}" -le 9 ] 2>/dev/null || return 1
    is_canonical_positive_decimal "$OWNER_STATE_UDP_PKT_OUT" && [ "${#OWNER_STATE_UDP_PKT_OUT}" -le 9 ] 2>/dev/null || return 1
    is_canonical_positive_decimal "$OWNER_STATE_UDP_PKT_IN" && [ "${#OWNER_STATE_UDP_PKT_IN}" -le 9 ] 2>/dev/null || return 1
    canonical_mark "$OWNER_STATE_DESYNC_MARK" || return 1; [ "$MARK_CANONICAL" = "$OWNER_STATE_DESYNC_MARK" ] || return 1
    case "$OWNER_STATE_IPV4_ACTIVE:$OWNER_STATE_IPV6_ACTIVE:$OWNER_STATE_IPV4_CONNBYTES:$OWNER_STATE_IPV4_MULTIPORT:$OWNER_STATE_IPV4_MARK:$OWNER_STATE_IPV6_CONNBYTES:$OWNER_STATE_IPV6_MULTIPORT:$OWNER_STATE_IPV6_MARK" in *[!01:]*) return 1;; esac
    [ "$OWNER_STATE_IPV4_ACTIVE" = 1 ] || return 1
    is_canonical_nonnegative_i64 "$OWNER_STATE_IPV4_RULES" &&
        is_canonical_nonnegative_i64 "$OWNER_STATE_IPV6_RULES" || return 1
    tcp_count="$(owner_port_rule_count "$OWNER_STATE_PORTS_TCP")" || return 1
    udp_count="$(owner_port_rule_count "$OWNER_STATE_PORTS_UDP")" || return 1
    if [ "$OWNER_STATE_IPV4_MULTIPORT" = 1 ]; then
        expected=0; [ -z "$OWNER_STATE_PORTS_TCP" ] || expected=$((expected + 1)); [ -z "$OWNER_STATE_PORTS_UDP" ] || expected=$((expected + 1))
    else expected=$((tcp_count + udp_count)); fi
    expected=$((expected * (1 + OWNER_STATE_IPV4_CONNBYTES)))
    [ "$OWNER_STATE_IPV4_RULES" = $((expected * OWNER_STATE_IPV4_ACTIVE)) ] || return 1
    if [ "$OWNER_STATE_IPV6_MULTIPORT" = 1 ]; then
        expected=0; [ -z "$OWNER_STATE_PORTS_TCP" ] || expected=$((expected + 1)); [ -z "$OWNER_STATE_PORTS_UDP" ] || expected=$((expected + 1))
    else expected=$((tcp_count + udp_count)); fi
    expected=$((expected * (1 + OWNER_STATE_IPV6_CONNBYTES)))
    [ "$OWNER_STATE_IPV6_RULES" = $((expected * OWNER_STATE_IPV6_ACTIVE)) ] || return 1
    # A cold lifecycle process has no prior OWNER_WRITE_* generation.  Build
    # the authenticated v8 specs solely from the just-validated owner fields;
    # otherwise a valid record is accidentally accepted only in the writer's
    # original shell where these globals happen to remain populated.
    OWNER_WRITE_QNUM="$OWNER_STATE_QNUM"
    OWNER_WRITE_PORTS_TCP="$OWNER_STATE_PORTS_TCP"; OWNER_WRITE_PORTS_UDP="$OWNER_STATE_PORTS_UDP"; OWNER_WRITE_STUN_PORTS="$OWNER_STATE_STUN_PORTS"
    OWNER_WRITE_TCP_PKT_OUT="$OWNER_STATE_TCP_PKT_OUT"; OWNER_WRITE_TCP_PKT_IN="$OWNER_STATE_TCP_PKT_IN"
    OWNER_WRITE_UDP_PKT_OUT="$OWNER_STATE_UDP_PKT_OUT"; OWNER_WRITE_UDP_PKT_IN="$OWNER_STATE_UDP_PKT_IN"
    OWNER_WRITE_DESYNC_MARK="$OWNER_STATE_DESYNC_MARK"
    [ "$(owner_build_family_spec ipv4 "$OWNER_STATE_IPV4_ACTIVE" "$OWNER_STATE_IPV4_CONNBYTES" "$OWNER_STATE_IPV4_MULTIPORT" "$OWNER_STATE_IPV4_MARK" "$OWNER_STATE_IPV4_RULES")" = "$OWNER_STATE_IPV4_SPEC" ] || return 1
    [ "$(owner_build_family_spec ipv6 "$OWNER_STATE_IPV6_ACTIVE" "$OWNER_STATE_IPV6_CONNBYTES" "$OWNER_STATE_IPV6_MULTIPORT" "$OWNER_STATE_IPV6_MARK" "$OWNER_STATE_IPV6_RULES")" = "$OWNER_STATE_IPV6_SPEC" ] || return 1
    [ "$(owner_spec_fingerprint "$OWNER_STATE_IPV4_SPEC" "$OWNER_STATE_IPV6_SPEC")" = "$OWNER_STATE_FIREWALL_FINGERPRINT" ] || return 1
    FIREWALL_TAG="$OWNER_STATE_FIREWALL_TAG"; ZAPRET2_OUT="$OWNER_STATE_OUT_CHAIN"; ZAPRET2_IN="$OWNER_STATE_IN_CHAIN"
    return 0
}

write_numeric_pidfile() {
    local pid="$1"
    is_decimal "$pid" && [ "$pid" -gt 0 ] 2>/dev/null || return 1
    write_private_runtime_line "$PIDFILE" "$pid"
}

write_owner_state() {
    local pid="$1" start="$2" argv_sha256="$3" qnum="$4" generation="$5" phase="$6"
    local tmp="$OWNER_STATE.tmp.$$" boot_id size
    read_current_boot_id || return 1
    boot_id="$CURRENT_BOOT_ID"
    is_canonical_positive_decimal "$pid" && is_canonical_nonnegative_i64 "$start" || return 1
    normalize_qnum "$qnum" || return 1
    qnum="$QNUM_NORMALIZED"
    is_lower_sha256 "$argv_sha256" || return 1
    is_safe_token "$generation" || return 1
    case "$phase" in launched|active|stopping|error) ;; *) return 1 ;; esac
    if [ "${OWNER_WRITE_READY:-0}" != 1 ] || { [ -n "${OWNER_WRITE_SOURCE_GENERATION:-}" ] && [ "$OWNER_WRITE_SOURCE_GENERATION" != "$generation" ]; }; then
        prepare_owner_generation_spec 1 "${IPV6_BUILT:-${IPV6_ACTIVE:-0}}" || return 1
    fi
    [ "$qnum" = "$OWNER_WRITE_QNUM" ] || return 1
    ensure_state_dir || return 1
    state_file_target_is_safe "$OWNER_STATE" || return 1
    state_path_is_managed_file "$tmp" || return 1
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
    umask 077
    {
        printf 'version=%s\n' "$OWNER_STATE_VERSION"
        printf 'pid=%s\nstarttime=%s\nargv_sha256=%s\n' "$pid" "$start" "$argv_sha256"
        printf 'qnum=%s\nexe=%s\ngeneration=%s\nboot_id=%s\nphase=%s\n' "$qnum" "$NFQWS2" "$generation" "$boot_id" "$phase"
        printf 'install_generation=%s\ninstall_archive_sha256=%s\n' "$OWNER_WRITE_INSTALL_GENERATION" "$OWNER_WRITE_INSTALL_ARCHIVE_SHA256"
        printf 'firewall_tag=%s\nout_chain=%s\nin_chain=%s\n' "$OWNER_WRITE_FIREWALL_TAG" "$OWNER_WRITE_OUT_CHAIN" "$OWNER_WRITE_IN_CHAIN"
        printf 'ports_tcp=%s\nports_udp=%s\nstun_ports=%s\n' "$OWNER_WRITE_PORTS_TCP" "$OWNER_WRITE_PORTS_UDP" "$OWNER_WRITE_STUN_PORTS"
        printf 'tcp_pkt_out=%s\ntcp_pkt_in=%s\nudp_pkt_out=%s\nudp_pkt_in=%s\ndesync_mark=%s\n' \
            "$OWNER_WRITE_TCP_PKT_OUT" "$OWNER_WRITE_TCP_PKT_IN" \
            "$OWNER_WRITE_UDP_PKT_OUT" "$OWNER_WRITE_UDP_PKT_IN" "$OWNER_WRITE_DESYNC_MARK"
        printf 'ipv4_active=%s\nipv6_active=%s\nipv4_connbytes=%s\nipv4_multiport=%s\nipv4_mark=%s\n' "$OWNER_WRITE_IPV4_ACTIVE" "$OWNER_WRITE_IPV6_ACTIVE" "$OWNER_WRITE_IPV4_CONNBYTES" "$OWNER_WRITE_IPV4_MULTIPORT" "$OWNER_WRITE_IPV4_MARK"
        printf 'ipv6_connbytes=%s\nipv6_multiport=%s\nipv6_mark=%s\nipv4_rules=%s\nipv6_rules=%s\n' "$OWNER_WRITE_IPV6_CONNBYTES" "$OWNER_WRITE_IPV6_MULTIPORT" "$OWNER_WRITE_IPV6_MARK" "$OWNER_WRITE_IPV4_RULES" "$OWNER_WRITE_IPV6_RULES"
        printf 'ipv4_spec=%s\nipv6_spec=%s\nfirewall_fingerprint=%s\n' "$OWNER_WRITE_IPV4_SPEC" "$OWNER_WRITE_IPV6_SPEC" "$OWNER_WRITE_FIREWALL_FINGERPRINT"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    size="$(wc -c < "$tmp" 2>/dev/null)" || { rm -f "$tmp"; return 1; }
    is_decimal "$size" && [ "$size" -gt 0 ] 2>/dev/null &&
        [ "$size" -le "$OWNER_STATE_MAX_BYTES" ] 2>/dev/null || { rm -f "$tmp"; return 1; }
    chmod 0600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$OWNER_STATE" || { rm -f "$tmp"; return 1; }
    OWNER_WRITE_READY=0; OWNER_WRITE_SOURCE_GENERATION=""
}

publish_nfqws_owner() {
    local pid="$1" start="$2" qnum="$3" phase="$4" argv_sha256 generation
    is_decimal "$pid" && is_decimal "$start" || return 1
    # This is the single launch-time process proof. verify_nfqws_pid captures
    # the stable start time and argv digest in the same pass; recomputing both
    # before owner publication used to double the expensive /proc traversal.
    verify_nfqws_pid "$pid" "$start" "" "$qnum" capture-argv || return 1
    start="$VERIFIED_STARTTIME"
    argv_sha256="$VERIFIED_ARGV_SHA256"
    generation="${PENDING_OWNER_GENERATION:-}"
    [ -n "$generation" ] || generation="$(new_lifecycle_token)" || return 1
    # The authenticated, boot-bound owner is the publication commit marker.
    # Publish it first so a same-boot process interruption can leave at worst
    # an owner-only state, which process preflight can verify exactly. A bare
    # numeric pidfile is intentionally never produced. Cross-boot recovery
    # proves that the corresponding process and kernel firewall state vanished.
    write_owner_state "$pid" "$start" "$argv_sha256" "$qnum" "$generation" "$phase" || return 1
    write_numeric_pidfile "$pid" || return 1
    PUBLISHED_PID="$pid"
    PUBLISHED_START="$start"
    PUBLISHED_ARGV_SHA256="$argv_sha256"
    PUBLISHED_GENERATION="$generation"
    PUBLISHED_FIREWALL_FINGERPRINT="$OWNER_WRITE_FIREWALL_FINGERPRINT"
    PUBLISHED_IPV4_RULES="$OWNER_WRITE_IPV4_RULES"
    PUBLISHED_IPV6_RULES="$OWNER_WRITE_IPV6_RULES"
    PUBLISHED_IPV6_ACTIVE="$OWNER_WRITE_IPV6_ACTIVE"
    PUBLISHED_INSTALL_GENERATION="$OWNER_WRITE_INSTALL_GENERATION"
    PUBLISHED_INSTALL_ARCHIVE_SHA256="$OWNER_WRITE_INSTALL_ARCHIVE_SHA256"
    return 0
}

set_owner_phase() {
    local phase="$1"
    read_owner_state && owner_state_is_current_boot || return 1
    [ "$OWNER_STATE_PHASE" = "$phase" ] && return 0
    verify_nfqws_pid "$OWNER_STATE_PID" "$OWNER_STATE_START" "$OWNER_STATE_ARGV_SHA256" "$OWNER_STATE_QNUM" || return 1
    write_owner_state "$OWNER_STATE_PID" "$OWNER_STATE_START" "$OWNER_STATE_ARGV_SHA256" "$OWNER_STATE_QNUM" "$OWNER_STATE_GENERATION" "$phase"
}

retire_owner_metadata() {
    scan_exact_owned_nfqws >/dev/null 2>&1 || return 1
    [ -z "$OWNED_SCAN_PIDS" ] || return 1
    # Rejected/corrupt PID or owner metadata is repair evidence and must not be
    # silently removed.  Verified publication cleanup happens in
    # stop_pidfile_process().
    [ ! -e "$PIDFILE" ] && [ ! -L "$PIDFILE" ] || return 1
    [ ! -e "$OWNER_STATE" ] && [ ! -L "$OWNER_STATE" ] || return 1
    return 0
}

VERIFIED_STARTTIME=""
VERIFIED_ARGV_SHA256=""
verify_nfqws_pid() {
    local pid="$1" expected_start="${2:-}" expected_argv_sha256="${3:-}" expected_qnum="${4:-}"
    local capture_argv="${5:-}" before after cmd_exe binary_exe actual_argv_sha256="" argv0 runtime_nfqws2
    runtime_nfqws2="${AUDIT_NFQWS2_OVERRIDE:-$NFQWS2}"
    VERIFIED_STARTTIME=""
    VERIFIED_ARGV_SHA256=""
    is_decimal "$pid" || return 1
    [ "$pid" -gt 0 ] 2>/dev/null || return 1
    before="$(proc_starttime "$pid")" || return 1
    [ -z "$expected_start" ] || [ "$before" = "$expected_start" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    argv0="$(proc_argv0 "$pid")" || return 1
    [ "$argv0" = "$runtime_nfqws2" ] || return 1
    if [ -n "$expected_qnum" ]; then
        normalize_qnum "$expected_qnum" || return 1
        pid_cmdline_has_arg "$pid" "--qnum=$QNUM_NORMALIZED" || return 1
    fi
    if [ -n "$expected_argv_sha256" ] || [ "$capture_argv" = capture-argv ]; then
        actual_argv_sha256="$(proc_cmdline_sha256 "$pid")" || return 1
    fi
    if [ -n "$expected_argv_sha256" ]; then
        is_lower_sha256 "$expected_argv_sha256" || return 1
        [ "$actual_argv_sha256" = "$expected_argv_sha256" ] || return 1
    fi

    cmd_exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"
    binary_exe="$(readlink -f "$runtime_nfqws2" 2>/dev/null)"
    # Exact argv0 is mandatory on every platform.  /proc/PID/exe strengthens
    # that identity when readlink is available, but its absence on some
    # Android kernels must not weaken or disable the exact argv0 check above.
    if [ -n "$cmd_exe" ] && [ -n "$binary_exe" ]; then
        [ "$cmd_exe" = "$binary_exe" ] || return 1
    fi
    after="$(proc_starttime "$pid")" || return 1
    [ "$before" = "$after" ] || return 1
    VERIFIED_STARTTIME="$after"
    VERIFIED_ARGV_SHA256="$actual_argv_sha256"
    return 0
}

read_verified_pidfile() {
    VERIFIED_PID=""
    VERIFIED_PID_START=""
    VERIFIED_PID_ARGV_SHA256=""
    VERIFIED_PID_QNUM=""
    state_file_is_secure "$PIDFILE" && [ -r "$PIDFILE" ] || return 1
    local candidate
    candidate="$(cat "$PIDFILE" 2>/dev/null)"
    is_decimal "$candidate" || return 1
    if [ -e "$OWNER_STATE" ]; then
        read_owner_state && owner_state_is_current_boot || return 1
        [ "$OWNER_STATE_PID" = "$candidate" ] || return 1
        verify_nfqws_pid "$candidate" "$OWNER_STATE_START" "$OWNER_STATE_ARGV_SHA256" "$OWNER_STATE_QNUM" || return 1
        VERIFIED_PID_ARGV_SHA256="$OWNER_STATE_ARGV_SHA256"
        VERIFIED_PID_QNUM="$OWNER_STATE_QNUM"
    else
        # A bare numeric PID cannot authenticate a current lifecycle owner.
        return 1
    fi
    VERIFIED_PID="$candidate"
    VERIFIED_PID_START="$VERIFIED_STARTTIME"
    return 0
}

verify_status_snapshot_pid() {
    local candidate before after actual_argv_sha256
    VERIFIED_PID=""
    VERIFIED_PID_START=""
    VERIFIED_PID_ARGV_SHA256=""
    VERIFIED_PID_QNUM=""
    observer_state_file_is_secure "$PIDFILE" && [ -r "$PIDFILE" ] || return 1
    IFS= read -r candidate < "$PIDFILE" 2>/dev/null || return 1
    is_canonical_positive_decimal "$candidate" || return 1
    [ "$candidate" = "$STATUS_FILE_OWN_PID" ] || return 1
    is_canonical_nonnegative_i64 "$STATUS_FILE_OWN_PID_STARTTIME" || return 1
    is_lower_sha256 "$STATUS_FILE_OWN_ARGV_SHA256" || return 1
    before="$(proc_starttime "$candidate")" || return 1
    [ "$before" = "$STATUS_FILE_OWN_PID_STARTTIME" ] || return 1
    kill -0 "$candidate" 2>/dev/null || return 1
    proc_cmdline_may_match_nfqws "$candidate" || return 1
    actual_argv_sha256="$(proc_cmdline_sha256 "$candidate")" || return 1
    [ "$actual_argv_sha256" = "$STATUS_FILE_OWN_ARGV_SHA256" ] || return 1
    after="$(proc_starttime "$candidate")" || return 1
    [ "$before" = "$after" ] || return 1
    VERIFIED_PID="$candidate"
    VERIFIED_PID_START="$after"
    VERIFIED_PID_ARGV_SHA256="$actual_argv_sha256"
    VERIFIED_PID_QNUM="$STATUS_FILE_QNUM"
    return 0
}

read_live_pidfile() {
    LIVE_PIDFILE_PID=""
    state_file_is_secure "$PIDFILE" && [ -r "$PIDFILE" ] || return 1
    local candidate
    candidate="$(cat "$PIDFILE" 2>/dev/null)"
    is_decimal "$candidate" || return 1
    [ "$candidate" -gt 0 ] 2>/dev/null || return 1
    kill -0 "$candidate" 2>/dev/null || return 1
    proc_starttime "$candidate" >/dev/null 2>&1 || return 1
    LIVE_PIDFILE_PID="$candidate"
    return 0
}

stop_verified_nfqws_pid() {
    local pid="$1" start="$2" expected_argv_sha256="${3:-}" expected_qnum="${4:-}" n=0
    verify_nfqws_pid "$pid" "$start" "$expected_argv_sha256" "$expected_qnum" || return 2
    kill -TERM "$pid" 2>/dev/null || return 1
    while [ "$n" -lt 50 ]; do
        sleep 0.1
        verify_nfqws_pid "$pid" "$start" "$expected_argv_sha256" "$expected_qnum" || return 0
        n=$((n + 1))
    done
    verify_nfqws_pid "$pid" "$start" "$expected_argv_sha256" "$expected_qnum" || return 0
    kill -KILL "$pid" 2>/dev/null || return 1
    n=0
    while [ "$n" -lt 30 ]; do
        sleep 0.1
        verify_nfqws_pid "$pid" "$start" "$expected_argv_sha256" "$expected_qnum" || return 0
        n=$((n + 1))
    done
    return 1
}

PROCESS_CLEANUP_PREFLIGHT_PROVEN=0
PROCESS_PREFLIGHT_PID=""
PROCESS_PREFLIGHT_START=""
PROCESS_PREFLIGHT_ARGV_SHA256=""
PROCESS_PREFLIGHT_QNUM=""
PROCESS_PREFLIGHT_GENERATION=""
PROCESS_PREFLIGHT_PHASE=""
PROCESS_PREFLIGHT_PIDFILE_PRESENT=0
PROCESS_PREFLIGHT_OWNER_PRESENT=0
PROCESS_PREFLIGHT_LIVE=0

process_snapshot_owner_matches() {
    [ "$PROCESS_PREFLIGHT_OWNER_PRESENT" = 1 ] || {
        [ ! -e "$OWNER_STATE" ] && [ ! -L "$OWNER_STATE" ]
        return
    }
    read_owner_state && owner_state_is_current_boot || return 1
    [ "$OWNER_STATE_PID" = "$PROCESS_PREFLIGHT_PID" ] &&
        [ "$OWNER_STATE_START" = "$PROCESS_PREFLIGHT_START" ] &&
        [ "$OWNER_STATE_ARGV_SHA256" = "$PROCESS_PREFLIGHT_ARGV_SHA256" ] &&
        [ "$OWNER_STATE_QNUM" = "$PROCESS_PREFLIGHT_QNUM" ] &&
        [ "$OWNER_STATE_GENERATION" = "$PROCESS_PREFLIGHT_GENERATION" ] &&
        [ "$OWNER_STATE_PHASE" = "$PROCESS_PREFLIGHT_PHASE" ]
}

process_snapshot_pidfile_matches() {
    local candidate
    [ "$PROCESS_PREFLIGHT_PIDFILE_PRESENT" = 1 ] || {
        [ ! -e "$PIDFILE" ] && [ ! -L "$PIDFILE" ]
        return
    }
    state_file_is_secure "$PIDFILE" && [ -r "$PIDFILE" ] || return 1
    candidate="$(cat "$PIDFILE" 2>/dev/null)" || return 1
    [ "$candidate" = "$PROCESS_PREFLIGHT_PID" ]
}

stop_pidfile_process() {
    local rc=0
    [ "$PROCESS_CLEANUP_PREFLIGHT_PROVEN" = 1 ] || preflight_owned_process_cleanup || return 1
    process_snapshot_pidfile_matches && process_snapshot_owner_matches || return 1
    if [ "$PROCESS_PREFLIGHT_LIVE" = 1 ]; then
        verify_nfqws_pid "$PROCESS_PREFLIGHT_PID" "$PROCESS_PREFLIGHT_START" \
            "$PROCESS_PREFLIGHT_ARGV_SHA256" "$PROCESS_PREFLIGHT_QNUM" || return 1
        stop_verified_nfqws_pid "$PROCESS_PREFLIGHT_PID" "$PROCESS_PREFLIGHT_START" \
            "$PROCESS_PREFLIGHT_ARGV_SHA256" "$PROCESS_PREFLIGHT_QNUM" || rc=1
    fi
    # Never kill a process that appeared after the read-only proof. A new exact
    # process makes teardown incomplete and leaves its evidence intact.
    scan_exact_owned_nfqws >/dev/null 2>&1 || rc=1
    [ -z "$OWNED_SCAN_PIDS" ] || rc=1
    if [ "$rc" -eq 0 ]; then
        process_snapshot_pidfile_matches && process_snapshot_owner_matches || return 1
        if [ "$PROCESS_PREFLIGHT_PIDFILE_PRESENT" = 1 ]; then rm -f "$PIDFILE" 2>/dev/null || rc=1; fi
        if [ "$PROCESS_PREFLIGHT_OWNER_PRESENT" = 1 ]; then rm -f "$OWNER_STATE" 2>/dev/null || rc=1; fi
    fi
    return "$rc"
}

scan_exact_owned_nfqws() {
    local procdir pid start restore_noglob=0
    OWNED_SCAN_PIDS=""
    case "$-" in *f*) restore_noglob=1; set +f ;; esac
    for procdir in /proc/[0-9]*; do
        [ -d "$procdir" ] || continue
        pid="${procdir#/proc/}"
        # The previous implementation performed multiple /proc reads plus
        # tr/sed forks for every Android process. Filter with one shell-builtin
        # read and reserve the strict identity proof for plausible candidates.
        proc_cmdline_may_match_nfqws "$pid" || continue
        start="$(proc_starttime "$pid")" || continue
        if verify_nfqws_pid "$pid" "$start" "" ""; then
            if [ -n "$OWNED_SCAN_PIDS" ]; then OWNED_SCAN_PIDS="$OWNED_SCAN_PIDS $pid"
            else OWNED_SCAN_PIDS="$pid"; fi
        fi
    done
    [ "$restore_noglob" = 1 ] && set -f
    printf '%s\n' "$OWNED_SCAN_PIDS"
}

scan_exact_owned_nfqws_for_path() {
    local AUDIT_NFQWS2_OVERRIDE="$1"
    [ -n "$AUDIT_NFQWS2_OVERRIDE" ] || return 1
    scan_exact_owned_nfqws
}

stop_all_exact_owned_nfqws() {
    local pid start rc=0
    scan_exact_owned_nfqws >/dev/null 2>&1 || return 1
    for pid in $OWNED_SCAN_PIDS; do
        start="$(proc_starttime "$pid")" || continue
        stop_verified_nfqws_pid "$pid" "$start" "" "" || rc=1
    done
    scan_exact_owned_nfqws >/dev/null 2>&1 || return 1
    [ -z "$OWNED_SCAN_PIDS" ] || rc=1
    return "$rc"
}

stop_all_exact_owned_nfqws_for_path() {
    local AUDIT_NFQWS2_OVERRIDE="$1"
    [ -n "$AUDIT_NFQWS2_OVERRIDE" ] || return 1
    stop_all_exact_owned_nfqws
}

# Refuse teardown when exact process publication cannot account for every
# module-binary process.  In particular, a rejected PID/owner file must never
# fall through to the broad exact-path scan and kill a listener.
PROCESS_CLEANUP_PREFLIGHT_ERROR=""
preflight_owned_process_cleanup() {
    local count=0 pid pidfile_present=0 owner_present=0 argv_sha256 start
    PROCESS_CLEANUP_PREFLIGHT_ERROR=""
    PROCESS_CLEANUP_PREFLIGHT_PROVEN=0
    PROCESS_PREFLIGHT_PID=""; PROCESS_PREFLIGHT_START=""; PROCESS_PREFLIGHT_ARGV_SHA256=""
    PROCESS_PREFLIGHT_QNUM=""; PROCESS_PREFLIGHT_GENERATION=""; PROCESS_PREFLIGHT_PHASE=""
    PROCESS_PREFLIGHT_PIDFILE_PRESENT=0; PROCESS_PREFLIGHT_OWNER_PRESENT=0
    PROCESS_PREFLIGHT_LIVE=0
    { [ -e "$PIDFILE" ] || [ -L "$PIDFILE" ]; } && pidfile_present=1
    { [ -e "$OWNER_STATE" ] || [ -L "$OWNER_STATE" ]; } && owner_present=1
    scan_exact_owned_nfqws >/dev/null 2>&1 || {
        PROCESS_CLEANUP_PREFLIGHT_ERROR="exact module process scan is unavailable"
        return 1
    }
    for pid in $OWNED_SCAN_PIDS; do count=$((count + 1)); done
    [ "$count" -le 1 ] || {
        PROCESS_CLEANUP_PREFLIGHT_ERROR="multiple exact module processes are ambiguous"
        return 1
    }
    if [ "$count" = 0 ] && [ "$pidfile_present" = 1 ]; then
        PROCESS_CLEANUP_PREFLIGHT_ERROR="PID publication exists but cannot be matched to an exact live module process"
        return 1
    fi
    if [ "$owner_present" = 1 ]; then
        read_owner_state || {
            PROCESS_CLEANUP_PREFLIGHT_ERROR="owner metadata is malformed or unsafe"
            return 1
        }
        owner_state_is_current_boot || {
            PROCESS_CLEANUP_PREFLIGHT_ERROR="owner metadata is not bound to the current boot"
            return 1
        }
        PROCESS_PREFLIGHT_OWNER_PRESENT=1
        PROCESS_PREFLIGHT_GENERATION="$OWNER_STATE_GENERATION"
        PROCESS_PREFLIGHT_PHASE="$OWNER_STATE_PHASE"
    fi
    if [ "$count" = 1 ]; then
        [ "$owner_present" = 1 ] || {
            PROCESS_CLEANUP_PREFLIGHT_ERROR="live module process lacks an authenticated current owner"
            return 1
        }
        PROCESS_PREFLIGHT_LIVE=1
        pid="$OWNED_SCAN_PIDS"
        start="$(proc_starttime "$pid")" || return 1
        argv_sha256="$(proc_cmdline_sha256 "$pid")" || return 1
        if [ "$pidfile_present" = 1 ]; then
            read_verified_pidfile || {
                PROCESS_CLEANUP_PREFLIGHT_ERROR="live PID publication is corrupt or unverified"
                return 1
            }
            [ "$VERIFIED_PID" = "$pid" ] || {
                PROCESS_CLEANUP_PREFLIGHT_ERROR="PID publication names a different live process"
                return 1
            }
            PROCESS_PREFLIGHT_PIDFILE_PRESENT=1
            PROCESS_PREFLIGHT_QNUM="$VERIFIED_PID_QNUM"
        elif [ "$owner_present" = 1 ]; then
            [ "$OWNER_STATE_PID" = "$pid" ] && [ "$OWNER_STATE_START" = "$start" ] &&
                [ "$OWNER_STATE_ARGV_SHA256" = "$argv_sha256" ] &&
                verify_nfqws_pid "$pid" "$start" "$argv_sha256" "$OWNER_STATE_QNUM" || {
                    PROCESS_CLEANUP_PREFLIGHT_ERROR="owner metadata does not match the exact module process"
                    return 1
                }
            PROCESS_PREFLIGHT_QNUM="$OWNER_STATE_QNUM"
        fi
        PROCESS_PREFLIGHT_PID="$pid"
        PROCESS_PREFLIGHT_START="$start"
        PROCESS_PREFLIGHT_ARGV_SHA256="$argv_sha256"
    elif [ "$owner_present" = 1 ]; then
        PROCESS_CLEANUP_PREFLIGHT_ERROR="current-boot owner publication has no exact live module process"
        return 1
    fi
    PROCESS_CLEANUP_PREFLIGHT_PROVEN=1
    return 0
}

owner_family_generation_healthy() {
    local tool="$1" family="$2" active connbytes expected
    local PORTS_TCP="$OWNER_STATE_PORTS_TCP" PORTS_UDP="$OWNER_STATE_PORTS_UDP"
    local TCP_PKT_OUT="$OWNER_STATE_TCP_PKT_OUT" TCP_PKT_IN="$OWNER_STATE_TCP_PKT_IN"
    local UDP_PKT_OUT="$OWNER_STATE_UDP_PKT_OUT" UDP_PKT_IN="$OWNER_STATE_UDP_PKT_IN"
    local QNUM="$OWNER_STATE_QNUM" DESYNC_MARK="$OWNER_STATE_DESYNC_MARK"
    is_safe_firewall_identity "$OWNER_STATE_FIREWALL_TAG" \
        "$OWNER_STATE_OUT_CHAIN" "$OWNER_STATE_IN_CHAIN" || return 1
    [ "$OWNER_STATE_OUT_CHAIN" = "$Z2_FW_OUT_CHAIN" ] &&
        [ "$OWNER_STATE_IN_CHAIN" = "$Z2_FW_IN_CHAIN" ] || return 1
    if [ "$family" = ipv4 ]; then
        active="$OWNER_STATE_IPV4_ACTIVE"
        connbytes="$OWNER_STATE_IPV4_CONNBYTES"
        expected="$OWNER_STATE_IPV4_RULES"
        [ "$OWNER_STATE_IPV4_MULTIPORT" = 1 ] && [ "$OWNER_STATE_IPV4_MARK" = 1 ] || return 1
    else
        active="$OWNER_STATE_IPV6_ACTIVE"
        connbytes="$OWNER_STATE_IPV6_CONNBYTES"
        expected="$OWNER_STATE_IPV6_RULES"
        [ "$OWNER_STATE_IPV6_MULTIPORT" = 1 ] && [ "$OWNER_STATE_IPV6_MARK" = 1 ] || return 1
    fi
    if [ "$active" = 0 ]; then
        z2_fw_family_absent "$tool"
        return
    fi
    z2_fw_verify_family "$tool" "$connbytes" || return 1
    [ "$Z2_FW_RULES" = "$expected" ]
}

audit_owned_firewall_for_cleanup() {
    FIREWALL_CLEANUP_PREFLIGHT_ERROR=""
    command -v z2_fw_cleanup_family >/dev/null 2>&1 || {
        FIREWALL_CLEANUP_PREFLIGHT_ERROR="firewall reconciler is unavailable"
        return 1
    }
    z2_fw_tool_available iptables || {
        FIREWALL_CLEANUP_PREFLIGHT_ERROR="IPv4 mangle backend is unavailable"
        return 1
    }
    z2_fw_cleanup_is_unambiguous iptables || {
        FIREWALL_CLEANUP_PREFLIGHT_ERROR="IPv4 stable namespace has a foreign reference"
        return 1
    }
    z2_fw_save_audit iptables || {
        FIREWALL_CLEANUP_PREFLIGHT_ERROR="IPv4 stable namespace audit could not be retained"
        return 1
    }
    # The probe budget is spent here, once. Teardown then follows this
    # decision instead of waiting again: a family whose baseline was never
    # captured cannot be torn down from an audit, so a second wait would only
    # walk into a guaranteed failure.
    FIREWALL_IPV6_UNQUERYABLE=0
    FIREWALL_IPV6_AUDITED_EMPTY=0
    if command -v ip6tables >/dev/null 2>&1; then
        if z2_fw_tool_available ip6tables ||
           ! firewall_family_persistently_unavailable ip6tables; then
            if ! z2_fw_cleanup_is_unambiguous ip6tables || ! z2_fw_save_audit ip6tables; then
                FIREWALL_CLEANUP_PREFLIGHT_ERROR="IPv6 stable namespace has a foreign reference"
                return 1
            fi
            # A read that found nothing of ours is a proof, not an absence of
            # one. If the frontend goes busy before teardown, that proof is
            # what separates "we could not look" from "we looked and there was
            # nothing" — and only the former deserves a reservation. Nothing
            # can appear in between: teardown publishes no rules and the
            # lifecycle lock is held across both steps.
            [ "${Z2_FW_AUDIT_IP6TABLES:-}" != "0 0 0 0" ] || FIREWALL_IPV6_AUDITED_EMPTY=1
        else
            FIREWALL_IPV6_UNQUERYABLE=1
        fi
    fi
    # Stable chain names are the ownership boundary. Cleanup is idempotent and
    # never touches another chain or a non-exact built-in anchor.
    return 0
}

# Teardown may skip an IPv6 family it cannot query only when something proves
# this generation published nothing there. That decision was being made
# separately by stop, full rollback, start's rollback and the failure snapshot,
# and the four copies disagreed — so it lives here now, with one priority
# order: what the running transaction did, then the authenticated owner
# record, then a snapshot committed with a verified ruleset, then the
# conservative default.
#
# Publishes two answers to two different questions:
#   CLEANUP_IPV6_OWNERSHIP_EXPECTED — may an unqueryable family be skipped?
#   IPV6_PUBLICATION_RECORDED       — is there positive evidence we published?
CLEANUP_IPV6_OWNERSHIP_EXPECTED=1
IPV6_PUBLICATION_RECORDED=0
resolve_ipv6_ownership_expectation() {
    local owner_available="${1:-0}"
    CLEANUP_IPV6_OWNERSHIP_EXPECTED=1
    IPV6_PUBLICATION_RECORDED=0
    if [ "${IPV6_TOUCHED:-0}" = 1 ] || [ "${IPV6_BUILT:-0}" = 1 ] ||
       [ "${IPV6_ACTIVE:-0}" = 1 ]; then
        IPV6_PUBLICATION_RECORDED=1
        return 0
    fi
    if [ "$owner_available" = 1 ]; then
        CLEANUP_IPV6_OWNERSHIP_EXPECTED="${OWNER_STATE_IPV6_ACTIVE:-1}"
        IPV6_PUBLICATION_RECORDED="${OWNER_STATE_IPV6_ACTIVE:-0}"
        return 0
    fi
    case "${STATUS_FILE_STATUS:-}" in
        ok|stopped)
            [ "${STATUS_FILE_RULESET_VERIFIED:-0}" = 1 ] &&
                CLEANUP_IPV6_OWNERSHIP_EXPECTED="${STATUS_FILE_IPV6_ACTIVE:-1}"
            IPV6_PUBLICATION_RECORDED="${STATUS_FILE_IPV6_ACTIVE:-0}"
            ;;
        ?*) IPV6_PUBLICATION_RECORDED="${STATUS_FILE_IPV6_ACTIVE:-0}" ;;
    esac
    return 0
}

# A busy xtables lock looks exactly like a missing table in a single probe, and
# netd, tethering and VPN apps take that lock constantly. Treating one failed
# probe as permanent would leave real rules behind, so require the condition to
# persist. A frontend that is not installed at all can never become queryable.
FIREWALL_PROBE_ATTEMPTS="${FIREWALL_PROBE_ATTEMPTS:-5}"
firewall_family_persistently_unavailable() {
    local tool="$1" attempt=0 attempts="$FIREWALL_PROBE_ATTEMPTS"
    # A zero, negative or non-numeric budget would skip the loop entirely and
    # report "permanently unavailable" without probing once — the fail-open
    # this function exists to prevent.
    # Bounded on both sides: the caller holds the lifecycle lock while this
    # runs, so an unbounded budget would hold it for hours.
    is_decimal "$attempts" && [ "$attempts" -ge 1 ] 2>/dev/null &&
        [ "$attempts" -le 60 ] 2>/dev/null || attempts=5
    command -v "$tool" >/dev/null 2>&1 || return 0
    while [ "$attempt" -lt "$attempts" ]; do
        z2_fw_tool_available "$tool" && return 1
        attempt=$((attempt + 1))
        [ "$attempt" -ge "$attempts" ] || sleep 1
    done
    return 0
}

FIREWALL_IPV6_SKIPPED_UNPROVEN=0
FIREWALL_IPV6_UNQUERYABLE=0
FIREWALL_IPV6_AUDITED_EMPTY=0
cleanup_owned_firewall() {
    local baseline_mode="${1:-owned}" rc=0 result
    case "$baseline_mode" in owned|audited) ;; *) return 1;; esac
    FIREWALL_IPV6_SKIPPED_UNPROVEN=0
    command -v z2_fw_cleanup_family >/dev/null 2>&1 || return 1
    z2_fw_cleanup_family iptables "$baseline_mode"
    result=$?
    [ "$result" = 0 ] || rc=1
    if command -v ip6tables >/dev/null 2>&1; then
        # An audited teardown can only remove what the preflight captured, so a
        # family the preflight could not read is not one this mode can touch.
        # An owned teardown captures its own baseline, so it only needs the
        # frontend to answer now.
        if { [ "$baseline_mode" != audited ] || [ "${FIREWALL_IPV6_UNQUERYABLE:-0}" != 1 ]; } &&
           { z2_fw_tool_available ip6tables || ! firewall_family_persistently_unavailable ip6tables; }; then
            z2_fw_cleanup_family ip6tables "$baseline_mode" ||
                { FIREWALL_CLEANUP_PREFLIGHT_ERROR="IPv6 owned ruleset could not be removed"; rc=1; }
        else
            # This family cannot be proven now, and on this device it cannot be
            # proven later either. Refusing would fence every teardown until a
            # reboot — and the next boot would refuse the same way. So skip it
            # and make the uncertainty travel with the result: the caller
            # reports it, the committed receipt withholds its verification
            # claim, and the reboot clears whatever survived.
            #
            # No reservation is needed when our own record already proves this
            # generation published nothing there, or when this run's own
            # preflight read the family and found nothing of ours in it. The
            # preflight proof counts only for the mode that produced it.
            if [ "${CLEANUP_IPV6_OWNERSHIP_EXPECTED:-1}" != 0 ] &&
               { [ "$baseline_mode" != audited ] ||
                 [ "${FIREWALL_IPV6_AUDITED_EMPTY:-0}" != 1 ]; }; then
                FIREWALL_IPV6_SKIPPED_UNPROVEN=1
            fi
        fi
    fi
    return "$rc"
}

owned_family_present() {
    z2_fw_family_absent "$1"
    case $? in 0) return 1;; 1) return 0;; *) return 2;; esac
}

# Read-only namespace discovery for a failed generation that never reached
# owner.meta publication. Dynamic chain names are strict module-owned kernel
# object identities; detecting them is safe even when teardown still requires
# a stronger journal/owner proof.
zapret2_namespace_present() {
    local tool="$1" listing
    listing="$("$tool" -t mangle -S 2>/dev/null)" || return 2
    printf '%s\n' "$listing" | awk '
        function owned(name, tag, side, ordinal) {
            if (name == "ZAPRET2_OUT" || name == "ZAPRET2_IN" || name == "ZAPRET2_PROBE") return 1
            if ((index(name,"Z2O_")==1 || index(name,"Z2I_")==1) && length(name)==14) {
                tag=substr(name,5,10)
                return tag !~ /[^A-Za-z0-9]/
            }
            if (index(name,"Z2R_")==1 && length(name)>=17) {
                tag=substr(name,5,10); side=substr(name,16,1); ordinal=substr(name,17)
                return substr(name,15,1)=="_" && tag !~ /[^A-Za-z0-9]/ &&
                    (side=="O" || side=="I") && ordinal ~ /^[1-9][0-9]*$/
            }
            return 0
        }
        $1 == "-N" && owned($2) { found=1 }
        $1 == "-A" {
            if (owned($2)) found=1
            for (i=3;i<=NF;i++) if (($i=="-j" || $i=="--jump" || $i=="-g" || $i=="--goto") && owned($(i+1))) found=1
        }
        END { exit found ? 0 : 1 }
    '
}

zapret2_delete_simple_jump_all() {
    local tool="$1" source="$2" target="$3" count=0
    while "$tool" -t mangle -C "$source" -j "$target" >/dev/null 2>&1; do
        [ "$count" -lt 4096 ] 2>/dev/null || return 1
        "$tool" -t mangle -D "$source" -j "$target" >/dev/null 2>&1 || return 1
        count=$((count + 1))
    done
    return 0
}

# The root-manager removal marker is a durable global start fence. Once that marker
# has been authenticated, uninstall may remove every strictly named Zapret2
# generation even when its interrupted build journal is unavailable. No broad
# table flush or rule-number deletion is used: only exact module-created jumps
# and the reserved chain namespace are touched.
purge_zapret2_namespace() {
    local tool="$1" listing chains chain rest tag suffix parent pass
    listing="$("$tool" -t mangle -S 2>/dev/null)" || return 1
    chains="$(printf '%s\n' "$listing" | awk '
        function owned(name, tag, side, ordinal) {
            if (name == "ZAPRET2_OUT" || name == "ZAPRET2_IN" || name == "ZAPRET2_PROBE") return 1
            if ((index(name,"Z2O_")==1 || index(name,"Z2I_")==1) && length(name)==14) {
                tag=substr(name,5,10)
                return tag !~ /[^A-Za-z0-9]/
            }
            if (index(name,"Z2R_")==1 && length(name)>=17) {
                tag=substr(name,5,10); side=substr(name,16,1); ordinal=substr(name,17)
                return substr(name,15,1)=="_" && tag !~ /[^A-Za-z0-9]/ &&
                    (side=="O" || side=="I") && ordinal ~ /^[1-9][0-9]*$/
            }
            return 0
        }
        $1 == "-N" && owned($2) { print $2 }
    ')" || return 1

    for chain in $chains; do
        case "$chain" in
            Z2R_*)
                rest="${chain#Z2R_}"; tag="${rest%%_*}"; suffix="${rest#*_}"
                case "$suffix" in O[1-9]* ) parent="Z2O_$tag" ;; I[1-9]* ) parent="Z2I_$tag" ;; *) return 1 ;; esac
                zapret2_delete_simple_jump_all "$tool" "$parent" "$chain" || return 1
                ;;
            Z2O_*) zapret2_delete_simple_jump_all "$tool" OUTPUT "$chain" || return 1 ;;
            Z2I_*) zapret2_delete_simple_jump_all "$tool" INPUT "$chain" || return 1 ;;
            ZAPRET2_OUT) zapret2_delete_simple_jump_all "$tool" OUTPUT "$chain" || return 1 ;;
            ZAPRET2_IN) zapret2_delete_simple_jump_all "$tool" INPUT "$chain" || return 1 ;;
            ZAPRET2_PROBE) ;;
            *) return 1 ;;
        esac
    done

    for chain in $chains; do
        "$tool" -t mangle -S "$chain" >/dev/null 2>&1 || continue
        "$tool" -t mangle -F "$chain" >/dev/null 2>&1 || return 1
    done
    for pass in 1 2; do
        for chain in $chains; do
            case "$pass:$chain" in
                1:Z2R_*|1:ZAPRET2_PROBE|2:Z2O_*|2:Z2I_*|2:ZAPRET2_OUT|2:ZAPRET2_IN) ;;
                *) continue ;;
            esac
            "$tool" -t mangle -S "$chain" >/dev/null 2>&1 || continue
            "$tool" -t mangle -X "$chain" >/dev/null 2>&1 || return 1
        done
    done
    zapret2_namespace_present "$tool"
    case $? in 1) return 0 ;; *) return 1 ;; esac
}

owned_family_absent() {
    z2_fw_family_absent "$1"
}

status_safe_value() { printf '%s' "$1" | tr '\r\n' '  '; }

LOG_READY="${LOG_READY:-0}"

prepare_lifecycle_log() {
    local log_size
    ensure_state_dir || return 1
    umask 077
    # Refuse symlinks and special files.  Removing a hostile path is not
    # necessary for logging and leaves less room for a replacement race.
    state_file_target_is_safe "$LOGFILE" || return 1
    state_file_target_is_safe "$LOGFILE_PREVIOUS" || return 1
    if [ -f "$LOGFILE" ]; then
        log_size="$(wc -c < "$LOGFILE" 2>/dev/null)" || return 1
        is_decimal "$log_size" || return 1
        if [ "$log_size" -ge "$LOG_MAX_BYTES" ] 2>/dev/null; then
            rm -f "$LOGFILE_PREVIOUS" 2>/dev/null || return 1
            mv -f "$LOGFILE" "$LOGFILE_PREVIOUS" 2>/dev/null || return 1
            chmod 0600 "$LOGFILE_PREVIOUS" 2>/dev/null || return 1
        fi
    fi
    : >> "$LOGFILE" || return 1
    chmod 0600 "$LOGFILE" 2>/dev/null || return 1
    state_file_is_secure "$LOGFILE" || return 1
    LOG_READY=1
    return 0
}

append_lifecycle_log() {
    [ "$LOG_READY" = 1 ] || return 0
    printf '%s\n' "$1" >> "$LOGFILE" 2>/dev/null
}

STATUS_FILE_STATUS=""
STATUS_FILE_QNUM=""
STATUS_FILE_RULES_TOTAL=0
STATUS_FILE_NFQUEUE_SUPPORTED=0
STATUS_FILE_QUEUE_BYPASS_SUPPORTED=0
STATUS_FILE_CONNBYTES_SUPPORTED=0
STATUS_FILE_MULTIPORT_SUPPORTED=0
STATUS_FILE_MARK_SUPPORTED=0
STATUS_FILE_IPV4_ACTIVE=0
STATUS_FILE_IPV6_ACTIVE=0
STATUS_FILE_IPV4_RULES=0
STATUS_FILE_IPV6_RULES=0
STATUS_FILE_CHAINS=0
STATUS_FILE_ANCHORS=0
STATUS_FILE_RULESET_VERIFIED=0
STATUS_FILE_OWNER_METADATA_VERIFIED=0
STATUS_FILE_RULES_EXPECTED=0
STATUS_FILE_OWN_PID=""
STATUS_FILE_OWN_PID_STARTTIME=""
STATUS_FILE_OWN_ARGV_SHA256=""
STATUS_FILE_OWNER_GENERATION=""
STATUS_FILE_DIAGNOSTICS=""
STATUS_FILE_ERROR_SCHEMA=0
STATUS_FILE_ERROR_STATUS=OK
STATUS_FILE_ERROR_DOMAIN=NONE
STATUS_FILE_ERROR_CODE=NONE
STATUS_FILE_ERROR_STAGE=NONE
STATUS_FILE_ERROR_DETAIL=""

# A rejected snapshot must leave nothing behind: consumers read STATUS_FILE_*
# whether or not they check the return code, so partially parsed facts from a
# file this function refused would be indistinguishable from accepted ones.
read_iptables_status() {
    read_iptables_status_parse "$@" && return 0
    reset_status_file_facts
    return 1
}

reset_status_file_facts() {
    STATUS_FILE_STATUS=""; STATUS_FILE_QNUM=""; STATUS_FILE_RULES_TOTAL=0
    STATUS_FILE_NFQUEUE_SUPPORTED=0; STATUS_FILE_QUEUE_BYPASS_SUPPORTED=0
    STATUS_FILE_CONNBYTES_SUPPORTED=0; STATUS_FILE_MULTIPORT_SUPPORTED=0
    STATUS_FILE_MARK_SUPPORTED=0; STATUS_FILE_IPV4_ACTIVE=0; STATUS_FILE_IPV6_ACTIVE=0
    STATUS_FILE_IPV4_RULES=0; STATUS_FILE_IPV6_RULES=0
    STATUS_FILE_CHAINS=0; STATUS_FILE_ANCHORS=0; STATUS_FILE_RULESET_VERIFIED=0
    STATUS_FILE_OWNER_METADATA_VERIFIED=0; STATUS_FILE_RULES_EXPECTED=0; STATUS_FILE_DIAGNOSTICS=""
    STATUS_FILE_OWN_PID=""; STATUS_FILE_OWN_PID_STARTTIME=""
    STATUS_FILE_OWN_ARGV_SHA256=""; STATUS_FILE_OWNER_GENERATION=""
    STATUS_FILE_ERROR_SCHEMA=0; STATUS_FILE_ERROR_STATUS=OK
    STATUS_FILE_ERROR_DOMAIN=NONE; STATUS_FILE_ERROR_CODE=NONE
    STATUS_FILE_ERROR_STAGE=NONE; STATUS_FILE_ERROR_DETAIL=""
    STATUS_FILE_BOOT_ID=""
}

read_iptables_status_parse() {
    local path="${1:-$IPTABLES_STATUS}"
    STATUS_FILE_STATUS=""; STATUS_FILE_QNUM=""; STATUS_FILE_RULES_TOTAL=0
    STATUS_FILE_NFQUEUE_SUPPORTED=0; STATUS_FILE_QUEUE_BYPASS_SUPPORTED=0
    STATUS_FILE_CONNBYTES_SUPPORTED=0; STATUS_FILE_MULTIPORT_SUPPORTED=0
    STATUS_FILE_MARK_SUPPORTED=0; STATUS_FILE_IPV4_ACTIVE=0; STATUS_FILE_IPV6_ACTIVE=0
    STATUS_FILE_IPV4_RULES=0; STATUS_FILE_IPV6_RULES=0
    STATUS_FILE_CHAINS=0; STATUS_FILE_ANCHORS=0; STATUS_FILE_RULESET_VERIFIED=0
    STATUS_FILE_OWNER_METADATA_VERIFIED=0; STATUS_FILE_RULES_EXPECTED=0; STATUS_FILE_DIAGNOSTICS=""
    STATUS_FILE_OWN_PID=""; STATUS_FILE_OWN_PID_STARTTIME=""
    STATUS_FILE_OWN_ARGV_SHA256=""; STATUS_FILE_OWNER_GENERATION=""
    STATUS_FILE_ERROR_SCHEMA=0; STATUS_FILE_ERROR_STATUS=OK
    STATUS_FILE_ERROR_DOMAIN=NONE; STATUS_FILE_ERROR_CODE=NONE
    STATUS_FILE_ERROR_STAGE=NONE; STATUS_FILE_ERROR_DETAIL=""
    STATUS_FILE_BOOT_ID=""
    [ "$path" = "$IPTABLES_STATUS" ] || return 1
    if [ "${OBSERVER_STATE_DIR_VERIFIED:-0}" = 1 ]; then
        observer_state_file_is_secure "$path" && [ -r "$path" ] || return 1
    else
        state_file_is_secure "$path" && [ -r "$path" ] || return 1
    fi
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            status) STATUS_FILE_STATUS="$value" ;;
            qnum) STATUS_FILE_QNUM="$value" ;;
            rules_total|total) STATUS_FILE_RULES_TOTAL="$value" ;;
            nfqueue_supported) STATUS_FILE_NFQUEUE_SUPPORTED="$value" ;;
            queue_bypass_supported) STATUS_FILE_QUEUE_BYPASS_SUPPORTED="$value" ;;
            connbytes_supported) STATUS_FILE_CONNBYTES_SUPPORTED="$value" ;;
            multiport_supported) STATUS_FILE_MULTIPORT_SUPPORTED="$value" ;;
            mark_supported) STATUS_FILE_MARK_SUPPORTED="$value" ;;
            ipv4_active) STATUS_FILE_IPV4_ACTIVE="$value" ;;
            ipv6_active) STATUS_FILE_IPV6_ACTIVE="$value" ;;
            ipv4_rules) STATUS_FILE_IPV4_RULES="$value" ;;
            ipv6_rules) STATUS_FILE_IPV6_RULES="$value" ;;
            chains) STATUS_FILE_CHAINS="$value" ;;
            anchors) STATUS_FILE_ANCHORS="$value" ;;
            ruleset_verified) STATUS_FILE_RULESET_VERIFIED="$value" ;;
            owner_metadata_verified) STATUS_FILE_OWNER_METADATA_VERIFIED="$value" ;;
            rules_expected) STATUS_FILE_RULES_EXPECTED="$value" ;;
            own_pid) STATUS_FILE_OWN_PID="$value" ;;
            own_pid_starttime) STATUS_FILE_OWN_PID_STARTTIME="$value" ;;
            own_argv_sha256) STATUS_FILE_OWN_ARGV_SHA256="$value" ;;
            owner_generation) STATUS_FILE_OWNER_GENERATION="$value" ;;
            boot_id) STATUS_FILE_BOOT_ID="$value" ;;
            diagnostics) STATUS_FILE_DIAGNOSTICS="$value" ;;
            error_schema) STATUS_FILE_ERROR_SCHEMA="$value" ;;
            error_status) STATUS_FILE_ERROR_STATUS="$value" ;;
            error_domain) STATUS_FILE_ERROR_DOMAIN="$value" ;;
            error_code) STATUS_FILE_ERROR_CODE="$value" ;;
            error_stage) STATUS_FILE_ERROR_STAGE="$value" ;;
            error_detail) STATUS_FILE_ERROR_DETAIL="$value" ;;
        esac
    done < "$path"
    # The snapshot describes processes and netfilter objects that a reboot
    # destroys, so one from an earlier boot is not stale data to reconcile —
    # it describes nothing that exists. Reject it here and every consumer is
    # correct without needing a separate retirement pass.
    read_current_boot_id || return 1
    [ "$STATUS_FILE_BOOT_ID" = "$CURRENT_BOOT_ID" ] || return 1
    normalize_qnum "$STATUS_FILE_QNUM" && STATUS_FILE_QNUM="$QNUM_NORMALIZED" || STATUS_FILE_QNUM=""
    for value in "$STATUS_FILE_RULES_TOTAL" "$STATUS_FILE_IPV4_RULES" \
        "$STATUS_FILE_IPV6_RULES" "$STATUS_FILE_RULES_EXPECTED" \
        "$STATUS_FILE_CHAINS" "$STATUS_FILE_ANCHORS"; do
        is_decimal "$value" || return 1
    done
    for value in "$STATUS_FILE_NFQUEUE_SUPPORTED" "$STATUS_FILE_QUEUE_BYPASS_SUPPORTED" \
        "$STATUS_FILE_CONNBYTES_SUPPORTED" "$STATUS_FILE_MULTIPORT_SUPPORTED" \
        "$STATUS_FILE_MARK_SUPPORTED" "$STATUS_FILE_IPV4_ACTIVE" "$STATUS_FILE_IPV6_ACTIVE" \
        "$STATUS_FILE_RULESET_VERIFIED" "$STATUS_FILE_OWNER_METADATA_VERIFIED"; do
        case "$value" in 0|1) ;; *) return 1 ;; esac
    done
    if [ -n "$STATUS_FILE_OWN_PID" ] || [ -n "$STATUS_FILE_OWN_PID_STARTTIME" ] ||
       [ -n "$STATUS_FILE_OWN_ARGV_SHA256" ] || [ -n "$STATUS_FILE_OWNER_GENERATION" ]; then
        is_decimal "$STATUS_FILE_OWN_PID" &&
            is_decimal "$STATUS_FILE_OWN_PID_STARTTIME" &&
            is_safe_token "$STATUS_FILE_OWNER_GENERATION" || return 1
        [ -z "$STATUS_FILE_OWN_ARGV_SHA256" ] ||
            is_lower_sha256 "$STATUS_FILE_OWN_ARGV_SHA256" || return 1
    fi
    if [ "$STATUS_FILE_ERROR_SCHEMA" = "$Z2_ERROR_SCHEMA_VERSION" ] &&
       z2_error_fields_are_valid "$STATUS_FILE_ERROR_STATUS" "$STATUS_FILE_ERROR_DOMAIN" \
           "$STATUS_FILE_ERROR_STAGE" "$STATUS_FILE_ERROR_CODE" "$STATUS_FILE_ERROR_DETAIL"; then
        :
    elif [ "$STATUS_FILE_ERROR_SCHEMA" = 0 ]; then
        STATUS_FILE_ERROR_STATUS=OK
        STATUS_FILE_ERROR_DOMAIN=NONE; STATUS_FILE_ERROR_CODE=NONE
        STATUS_FILE_ERROR_STAGE=NONE; STATUS_FILE_ERROR_DETAIL=""
    else
        return 1
    fi
    return 0
}

restore_status_facts() {
    read_iptables_status >/dev/null 2>&1 || true
    [ -n "${STATUS_QNUM:-}" ] || STATUS_QNUM="${QNUM:-$STATUS_FILE_QNUM}"
    [ -n "${STATUS_QNUM:-}" ] || { read_owner_state >/dev/null 2>&1 && STATUS_QNUM="$OWNER_STATE_QNUM"; }
    STATUS_NFQUEUE_SUPPORTED="${STATUS_NFQUEUE_SUPPORTED:-$STATUS_FILE_NFQUEUE_SUPPORTED}"
    STATUS_QUEUE_BYPASS_SUPPORTED="${STATUS_QUEUE_BYPASS_SUPPORTED:-$STATUS_FILE_QUEUE_BYPASS_SUPPORTED}"
    STATUS_CONNBYTES_SUPPORTED="${STATUS_CONNBYTES_SUPPORTED:-$STATUS_FILE_CONNBYTES_SUPPORTED}"
    STATUS_MULTIPORT_SUPPORTED="${STATUS_MULTIPORT_SUPPORTED:-$STATUS_FILE_MULTIPORT_SUPPORTED}"
    STATUS_MARK_SUPPORTED="${STATUS_MARK_SUPPORTED:-$STATUS_FILE_MARK_SUPPORTED}"
}

write_iptables_status() {
    local state="$1" tmp="$IPTABLES_STATUS.tmp.$$" errors diagnostics
    local error_status="${STATUS_ERROR_STATUS:-OK}"
    local error_domain="${STATUS_ERROR_DOMAIN:-NONE}" error_code="${STATUS_ERROR_CODE:-NONE}"
    local error_stage="${STATUS_ERROR_STAGE:-NONE}" error_detail
    errors="$(status_safe_value "${STATUS_ERRORS:-}")"
    diagnostics="$(status_safe_value "${STATUS_DIAGNOSTICS:-}")"
    error_detail="$(z2_error_detail_normalize "${STATUS_ERROR_DETAIL:-}")"
    z2_error_fields_are_valid "$error_status" "$error_domain" "$error_stage" "$error_code" \
        "$error_detail" ||
        return 1
    ensure_state_dir || return 1
    read_current_boot_id || return 1
    state_file_target_is_safe "$IPTABLES_STATUS" || return 1
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
    umask 077
    {
        echo "status=$state"
        echo "boot_id=$CURRENT_BOOT_ID"
        echo "timestamp=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "rules_ok=${STATUS_RULES_OK:-0}"
        echo "rules_fail=${STATUS_RULES_FAIL:-0}"
        echo "rules_total=${STATUS_RULES_TOTAL:-0}"
        echo "ok=${STATUS_RULES_OK:-0}"
        echo "fail=${STATUS_RULES_FAIL:-0}"
        echo "total=${STATUS_RULES_TOTAL:-0}"
        echo "errors=$errors"
        echo "own_pid=${STATUS_OWN_PID:-}"
        echo "own_pid_starttime=${STATUS_OWN_PID_STARTTIME:-}"
        echo "own_argv_sha256=${STATUS_OWN_ARGV_SHA256:-}"
        echo "owner_generation=${STATUS_OWNER_GENERATION:-}"
        echo "pid_verified=${STATUS_PID_VERIFIED:-0}"
        echo "owner_metadata_verified=${STATUS_OWNER_METADATA_VERIFIED:-0}"
        echo "ruleset_verified=${STATUS_RULESET_VERIFIED:-0}"
        echo "rules_expected=${STATUS_RULES_EXPECTED:-0}"
        echo "qnum=${STATUS_QNUM:-${QNUM:-}}"
        echo "ipv4_active=${STATUS_IPV4_ACTIVE:-0}"
        echo "ipv6_active=${STATUS_IPV6_ACTIVE:-0}"
        echo "ipv4_rules=${STATUS_IPV4_RULES:-0}"
        echo "ipv6_rules=${STATUS_IPV6_RULES:-0}"
        echo "chains=${STATUS_CHAINS:-0}"
        echo "anchors=${STATUS_ANCHORS:-0}"
        echo "nfqueue_supported=${STATUS_NFQUEUE_SUPPORTED:-0}"
        echo "queue_bypass_supported=${STATUS_QUEUE_BYPASS_SUPPORTED:-0}"
        echo "connbytes_supported=${STATUS_CONNBYTES_SUPPORTED:-0}"
        echo "multiport_supported=${STATUS_MULTIPORT_SUPPORTED:-0}"
        echo "mark_supported=${STATUS_MARK_SUPPORTED:-0}"
        echo "fallback_mode=${STATUS_FALLBACK_MODE:-0}"
        printf 'error_schema=%s\n' "$Z2_ERROR_SCHEMA_VERSION"
        printf 'error_status=%s\n' "$error_status"
        printf 'error_domain=%s\n' "$error_domain"
        printf 'error_code=%s\n' "$error_code"
        printf 'error_stage=%s\n' "$error_stage"
        printf 'error_detail=%s\n' "$error_detail"
        echo "diagnostics=$diagnostics"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$IPTABLES_STATUS" || { rm -f "$tmp"; return 1; }
}

# Lifecycle mutations already own the expensive process/firewall verification
# that produces STATUS_*. When explicitly requested by a compatible app, return
# that committed v6 projection on the same root transport instead of making the
# app launch zapret-status.sh and re-parse the snapshot immediately afterward.
emit_committed_status_v6() {
    local state="$1" lifecycle_state="$2" owner_kind="$3"
    local owned process active pid pid_verified pid_start generation owner_verified
    local ipv4 ipv6 rules expected ipv4_rules ipv6_rules ruleset nfqueue queue_bypass
    [ "${ZAPRET2_EMIT_STATUS_V6:-0}" = 1 ] || return 0
    case "$lifecycle_state:$owner_kind" in
        idle:none|owned:android-mutation) ;;
        *) return 1 ;;
    esac
    [ ! -e "$UNINSTALL_TOMBSTONE" ] && [ ! -L "$UNINSTALL_TOMBSTONE" ] ||
        return 1
    module_removal_pending && return 1
    case "$state" in
        ok)
            owned=1; process=1; active=1
            pid="${STATUS_OWN_PID:-}"; pid_verified=1
            pid_start="${STATUS_OWN_PID_STARTTIME:-}"
            generation="${STATUS_OWNER_GENERATION:-}"; owner_verified=1
            ipv4="${STATUS_IPV4_ACTIVE:-0}"; ipv6="${STATUS_IPV6_ACTIVE:-0}"
            rules="${STATUS_RULES_TOTAL:-0}"; expected="${STATUS_RULES_EXPECTED:-0}"
            ipv4_rules="${STATUS_IPV4_RULES:-0}"; ipv6_rules="${STATUS_IPV6_RULES:-0}"
            ruleset=1; nfqueue=1; queue_bypass=1
            ;;
        stopped)
            owned=0; process=0; active=0
            pid=""; pid_verified=0; pid_start=""; generation=""; owner_verified=0
            ipv4=0; ipv6=0; rules=0; expected=0; ipv4_rules=0; ipv6_rules=0
            # A stopped receipt reports what this teardown actually proved.
            # Everything measurable is zero either way; the single thing a
            # teardown that had to skip an unqueryable family cannot do is
            # certify the ruleset. Carrying that on the receipt is what lets
            # the operation report its own reservation, instead of staying
            # silent and leaving the caller to infer it from a second,
            # separately-raced observation. Unset defaults to withholding the
            # claim: asserting a verification nobody recorded is the one
            # direction this field must never fail in.
            ruleset="${STATUS_RULESET_VERIFIED:-0}"; nfqueue=0; queue_bypass=0
            ;;
        *) return 1 ;;
    esac
    cat <<EOF
Z2_PROTOCOL=6
Z2_STATUS=$state
Z2_OWNED=$owned
Z2_PROCESS=$process
Z2_ACTIVE=$active
Z2_PID=$pid
Z2_PID_VERIFIED=$pid_verified
Z2_PID_STARTTIME=$pid_start
Z2_OWNER_GENERATION=$generation
Z2_OWNER_METADATA_VERIFIED=$owner_verified
Z2_QNUM=${STATUS_QNUM:-${QNUM:-}}
Z2_IPV4=$ipv4
Z2_IPV6=$ipv6
Z2_RULES=$rules
Z2_EXPECTED_RULES=$expected
Z2_IPV4_RULES=$ipv4_rules
Z2_IPV6_RULES=$ipv6_rules
Z2_RULESET_VERIFIED=$ruleset
Z2_NFQUEUE=$nfqueue
Z2_QUEUE_BYPASS=$queue_bypass
Z2_UPDATE_BLOCKED=0
Z2_UNINSTALL_TOMBSTONE=0
Z2_LIFECYCLE_STATE=$lifecycle_state
Z2_LIFECYCLE_OWNER_KIND=$owner_kind
Z2_CHAINS=${STATUS_CHAINS:-0}
Z2_ANCHORS=${STATUS_ANCHORS:-0}
Z2_ERROR_SCHEMA=$Z2_ERROR_SCHEMA_VERSION
Z2_ERROR_STATUS=OK
Z2_ERROR_DOMAIN=NONE
Z2_ERROR_STAGE=NONE
Z2_ERROR_CODE=NONE
Z2_ERROR_DETAIL=
Z2_COMPLETE=1
EOF
}
