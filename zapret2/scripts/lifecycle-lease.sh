#!/system/bin/sh
# Cross-process ownership protocol for ordinary Android-side module writes.
#
# The app used to inline this whole protocol into its persistent root shell,
# where the interpreter shim cannot apply and every fork pays the full mksh
# image tax. As a packaged entry script it runs under the standalone-ash
# interpreter and the lease ceremony costs a fraction of a second.
#
# The record intentionally remains readable by common.sh (pid/starttime/token),
# while the additional exact fields let Android distinguish its own stale
# records from foreign lifecycle owners. Unknown or malformed lifecycle locks
# are never removed by this protocol.
#
# Usage:
#   lifecycle-lease.sh acquire APP_PID TOKEN
#   lifecycle-lease.sh probe   APP_PID TOKEN
#   lifecycle-lease.sh release PID STARTTIME BOOT_ID TOKEN RELEASE_TOKEN
#
# stdout contracts (parsed by the app; byte-stable):
#   acquire/probe success: 5 Z2_MUTATION_LOCK_* lines ending COMPLETE=1
#   probe with no lock:    Z2_MUTATION_LOCK_ABSENT=1
#   release success:       Z2_MUTATION_LOCK_RELEASED=1

case "$0" in
    /*//*|/*/./*|/*/../*|*/..|*/.) SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" ;;
    /*/*) SCRIPT_DIR="${0%/*}" ;;
    *) SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" ;;
esac
ZAPRET_DIR="${SCRIPT_DIR%/*}"
MODDIR="${ZAPRET_DIR%/*}"
ZAPRET2_LAZY_FIREWALL_RECONCILER=1
LIFECYCLE_LOCK_WAIT_SECONDS=1
. "$SCRIPT_DIR/common.sh"

Z2_LEASE_VERSION=1
Z2_LEASE_KIND=android-mutation
module_dir="$MODDIR"

lease_usage_error() {
    echo "ERROR: usage: lifecycle-lease.sh acquire|probe|release ..." >&2
    exit 2
}

is_safe_lease_token() {
    is_safe_token "$1" && [ "${#1}" -le 128 ] 2>/dev/null
}

# Exact-schema reader for the android-mutation owner record. Field order and
# multiplicity are pinned; anything else is a foreign owner and is preserved.
z2_read_android_mutation_owner() {
    local key value size links
    z2_owner_version=""; z2_owner_kind=""; z2_owner_pid=""; z2_owner_start=""
    z2_owner_boot=""; z2_owner_token=""; z2_owner_module=""
    z2_owner_order=""
    z2_seen_version=0; z2_seen_kind=0; z2_seen_pid=0; z2_seen_start=0
    z2_seen_boot=0; z2_seen_token=0; z2_seen_module=0
    state_dir_is_secure || return 1
    [ -d "$LIFECYCLE_LOCK" ] && [ ! -L "$LIFECYCLE_LOCK" ] || return 1
    path_uid_is_root "$LIFECYCLE_LOCK" || return 1
    [ "$(stat -c %a "$LIFECYCLE_LOCK" 2>/dev/null)" = 700 ] || return 1
    [ -f "$LIFECYCLE_LOCK_OWNER" ] && [ ! -L "$LIFECYCLE_LOCK_OWNER" ] || return 1
    path_uid_is_root "$LIFECYCLE_LOCK_OWNER" || return 1
    [ "$(stat -c %a "$LIFECYCLE_LOCK_OWNER" 2>/dev/null)" = 600 ] || return 1
    links=$(stat -c %h "$LIFECYCLE_LOCK_OWNER" 2>/dev/null) || return 1
    [ "$links" = 1 ] || return 1
    size=$(stat -c %s "$LIFECYCLE_LOCK_OWNER" 2>/dev/null) || return 1
    [ "$size" -gt 0 ] && [ "$size" -le 1024 ] || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            version) [ "$z2_seen_version" = 0 ] || return 1; z2_owner_version="$value"; z2_seen_version=1; z2_owner_order="${z2_owner_order}v" ;;
            kind) [ "$z2_seen_kind" = 0 ] || return 1; z2_owner_kind="$value"; z2_seen_kind=1; z2_owner_order="${z2_owner_order}k" ;;
            pid) [ "$z2_seen_pid" = 0 ] || return 1; z2_owner_pid="$value"; z2_seen_pid=1; z2_owner_order="${z2_owner_order}p" ;;
            starttime) [ "$z2_seen_start" = 0 ] || return 1; z2_owner_start="$value"; z2_seen_start=1; z2_owner_order="${z2_owner_order}s" ;;
            boot_id) [ "$z2_seen_boot" = 0 ] || return 1; z2_owner_boot="$value"; z2_seen_boot=1; z2_owner_order="${z2_owner_order}b" ;;
            token) [ "$z2_seen_token" = 0 ] || return 1; z2_owner_token="$value"; z2_seen_token=1; z2_owner_order="${z2_owner_order}t" ;;
            module_dir) [ "$z2_seen_module" = 0 ] || return 1; z2_owner_module="$value"; z2_seen_module=1; z2_owner_order="${z2_owner_order}m" ;;
            *) return 1 ;;
        esac
    done < "$LIFECYCLE_LOCK_OWNER"
    [ "$z2_seen_version:$z2_seen_kind:$z2_seen_pid:$z2_seen_start:$z2_seen_boot:$z2_seen_token:$z2_seen_module" = 1:1:1:1:1:1:1 ] || return 1
    [ "$z2_owner_order" = vkpsbtm ] || return 1
    [ "$z2_owner_version" = "$Z2_LEASE_VERSION" ] && [ "$z2_owner_kind" = "$Z2_LEASE_KIND" ] || return 1
    is_decimal "$z2_owner_pid" && [ "$z2_owner_pid" -gt 0 ] 2>/dev/null || return 1
    is_canonical_nonnegative_i64 "$z2_owner_start" || return 1
    is_valid_boot_id "$z2_owner_boot" || return 1
    is_safe_lease_token "$z2_owner_token" || return 1
    [ "$z2_owner_module" = "$module_dir" ]
}

z2_android_mutation_owner_state() {
    z2_owner_state=ambiguous
    if [ "$z2_owner_boot" != "$current_boot" ]; then
        z2_owner_state=stale
        return 1
    fi
    if [ ! -e "/proc/$z2_owner_pid" ]; then
        z2_owner_state=stale
        return 1
    fi
    proc_starttime_read "$z2_owner_pid" || return 2
    if [ "$PROC_STARTTIME" = "$z2_owner_start" ]; then
        z2_owner_state=active
        return 0
    fi
    z2_owner_state=stale
    return 1
}

lease_emit() {
    echo "Z2_MUTATION_LOCK_PID=$1"
    echo "Z2_MUTATION_LOCK_START=$2"
    echo "Z2_MUTATION_LOCK_BOOT=$3"
    echo "Z2_MUTATION_LOCK_TOKEN=$4"
    echo Z2_MUTATION_LOCK_COMPLETE=1
}

lease_acquire() {
    local app_pid="$1" app_token="$2"
    local self_start app_start app_start_after current_boot boot_after
    local stale_pid stale_start stale_boot stale_token stale_module
    local entries quarantine candidate_size candidate_entries
    is_decimal "$app_pid" && [ "$app_pid" -gt 0 ] 2>/dev/null &&
        is_safe_lease_token "$app_token" || lease_usage_error

    z2_candidate=""
    z2_gate_held=0
    z2_gate_token="android.$app_token"
    z2_cleanup_acquire() {
        local rc=$?
        trap - EXIT HUP INT TERM
        if [ -n "$z2_candidate" ] && [ -d "$z2_candidate" ] && [ ! -L "$z2_candidate" ]; then
            if [ -f "$z2_candidate/owner" ] && [ ! -L "$z2_candidate/owner" ]; then
                rm -f "$z2_candidate/owner" 2>/dev/null || rc=1
            fi
            rmdir "$z2_candidate" 2>/dev/null || rc=1
        fi
        if [ "$z2_gate_held" = 1 ]; then
            release_lifecycle_gate "$z2_gate_token" >/dev/null 2>&1 || rc=1
        fi
        exit "$rc"
    }
    trap z2_cleanup_acquire EXIT
    trap 'exit 1' HUP INT TERM

    ensure_state_dir || exit 1
    proc_starttime_read "$$" || exit 1
    self_start="$PROC_STARTTIME"
    proc_starttime_read "$app_pid" || exit 1
    app_start="$PROC_STARTTIME"
    IFS= read -r current_boot < /proc/sys/kernel/random/boot_id || exit 1
    is_valid_boot_id "$current_boot" || exit 1
    claim_lifecycle_gate "$self_start" "$z2_gate_token" || {
        echo "ERROR: Zapret2 lifecycle is busy; changes were not started" >&2
        exit 1
    }
    z2_gate_held=1

    if [ -e "$LIFECYCLE_LOCK" ] || [ -L "$LIFECYCLE_LOCK" ]; then
        z2_read_android_mutation_owner || {
            echo "ERROR: foreign, malformed, or unknown lifecycle owner was preserved" >&2
            exit 1
        }
        stale_pid="$z2_owner_pid"; stale_start="$z2_owner_start"; stale_boot="$z2_owner_boot"
        stale_token="$z2_owner_token"; stale_module="$z2_owner_module"
        z2_android_mutation_owner_state >/dev/null 2>&1 || true
        [ "$z2_owner_state" = stale ] || {
            echo "ERROR: active or ambiguous lifecycle owner blocks mutation" >&2
            exit 1
        }
        sleep 1
        z2_read_android_mutation_owner || exit 1
        [ "$z2_owner_pid" = "$stale_pid" ] &&
            [ "$z2_owner_start" = "$stale_start" ] &&
            [ "$z2_owner_boot" = "$stale_boot" ] &&
            [ "$z2_owner_token" = "$stale_token" ] &&
            [ "$z2_owner_module" = "$stale_module" ] || exit 1
        z2_android_mutation_owner_state >/dev/null 2>&1 || true
        [ "$z2_owner_state" = stale ] || exit 1
        entries=$(find "$LIFECYCLE_LOCK" -mindepth 1 -maxdepth 1 -print 2>/dev/null) || exit 1
        [ "$entries" = "$LIFECYCLE_LOCK_OWNER" ] || {
            echo "ERROR: lifecycle lock contains unknown entries; it was preserved" >&2
            exit 1
        }
        quarantine="$LIFECYCLE_LOCK_QUARANTINE.android.$$.$app_token"
        [ ! -e "$quarantine" ] && [ ! -L "$quarantine" ] || exit 1
        mv "$LIFECYCLE_LOCK" "$quarantine" || exit 1
        rm -f "$quarantine/owner" || exit 1
        rmdir "$quarantine" || exit 1
    fi

    z2_candidate="$LIFECYCLE_LOCK.candidate.android.$$.$app_token"
    [ ! -e "$z2_candidate" ] && [ ! -L "$z2_candidate" ] || exit 1
    mkdir "$z2_candidate" || exit 1
    chmod 0700 "$z2_candidate" || exit 1
    printf 'version=%s\nkind=%s\npid=%s\nstarttime=%s\nboot_id=%s\ntoken=%s\nmodule_dir=%s\n' \
        "$Z2_LEASE_VERSION" "$Z2_LEASE_KIND" \
        "$app_pid" "$app_start" "$current_boot" "$app_token" "$module_dir" > "$z2_candidate/owner" || exit 1
    chmod 0600 "$z2_candidate/owner" || exit 1
    [ "$(stat -c %u "$z2_candidate" 2>/dev/null)" = 0 ] || exit 1
    [ "$(stat -c %u "$z2_candidate/owner" 2>/dev/null)" = 0 ] || exit 1
    [ "$(stat -c %h "$z2_candidate/owner" 2>/dev/null)" = 1 ] || exit 1
    candidate_size=$(stat -c %s "$z2_candidate/owner" 2>/dev/null) || exit 1
    [ "$candidate_size" -gt 0 ] && [ "$candidate_size" -le 1024 ] || exit 1
    candidate_entries=$(find "$z2_candidate" -mindepth 1 -maxdepth 1 -print 2>/dev/null) || exit 1
    [ "$candidate_entries" = "$z2_candidate/owner" ] || exit 1
    proc_starttime_read "$app_pid" || exit 1
    app_start_after="$PROC_STARTTIME"
    IFS= read -r boot_after < /proc/sys/kernel/random/boot_id || exit 1
    [ "$app_start_after" = "$app_start" ] && [ "$boot_after" = "$current_boot" ] || exit 1
    [ ! -e "$LIFECYCLE_LOCK" ] && [ ! -L "$LIFECYCLE_LOCK" ] || exit 1
    mv "$z2_candidate" "$LIFECYCLE_LOCK" || exit 1
    z2_candidate=""

    release_lifecycle_gate "$z2_gate_token" >/dev/null 2>&1 || true
    z2_gate_held=0
    trap - EXIT HUP INT TERM
    lease_emit "$app_pid" "$app_start" "$current_boot" "$app_token"
}

# Probes only the exact record this app may have published after an ambiguous
# command result. Read-only: the before/after content identity proves nothing
# was mutated while the record was being read.
lease_probe() {
    local expected_pid="$1" expected_token="$2"
    local version_line kind_line pid_line start_line boot_line token_line module_line
    local start boot before after current_boot entries
    is_decimal "$expected_pid" && [ "$expected_pid" -gt 0 ] 2>/dev/null &&
        is_safe_lease_token "$expected_token" || lease_usage_error
    state_dir_is_secure || exit 1
    if [ ! -e "$LIFECYCLE_LOCK" ] && [ ! -L "$LIFECYCLE_LOCK" ]; then
        echo Z2_MUTATION_LOCK_ABSENT=1
        exit 0
    fi
    [ -d "$LIFECYCLE_LOCK" ] && [ ! -L "$LIFECYCLE_LOCK" ] || exit 1
    path_uid_is_root "$LIFECYCLE_LOCK" || exit 1
    [ "$(stat -c %a "$LIFECYCLE_LOCK" 2>/dev/null)" = 700 ] || exit 1
    [ -f "$LIFECYCLE_LOCK_OWNER" ] && [ ! -L "$LIFECYCLE_LOCK_OWNER" ] || exit 1
    path_uid_is_root "$LIFECYCLE_LOCK_OWNER" || exit 1
    [ "$(stat -c %a "$LIFECYCLE_LOCK_OWNER" 2>/dev/null)" = 600 ] || exit 1
    [ "$(stat -c %h "$LIFECYCLE_LOCK_OWNER" 2>/dev/null)" = 1 ] || exit 1
    [ "$(wc -l < "$LIFECYCLE_LOCK_OWNER" 2>/dev/null)" = 7 ] || exit 1
    before=$(sha256sum "$LIFECYCLE_LOCK_OWNER" 2>/dev/null) || exit 1
    before="${before%% *}"
    {
        IFS= read -r version_line || exit 1
        IFS= read -r kind_line || exit 1
        IFS= read -r pid_line || exit 1
        IFS= read -r start_line || exit 1
        IFS= read -r boot_line || exit 1
        IFS= read -r token_line || exit 1
        IFS= read -r module_line || exit 1
    } < "$LIFECYCLE_LOCK_OWNER"
    [ "$version_line" = "version=$Z2_LEASE_VERSION" ] && [ "$kind_line" = "kind=$Z2_LEASE_KIND" ] || exit 1
    [ "$pid_line" = "pid=$expected_pid" ] && [ "$token_line" = "token=$expected_token" ] || exit 1
    [ "$module_line" = "module_dir=$module_dir" ] || exit 1
    start="${start_line#starttime=}"; boot="${boot_line#boot_id=}"
    [ "$start_line" = "starttime=$start" ] && [ "$boot_line" = "boot_id=$boot" ] || exit 1
    is_canonical_nonnegative_i64 "$start" && is_valid_boot_id "$boot" || exit 1
    IFS= read -r current_boot < /proc/sys/kernel/random/boot_id || exit 1
    [ "$current_boot" = "$boot" ] || exit 1
    proc_starttime_read "$expected_pid" || exit 1
    [ "$PROC_STARTTIME" = "$start" ] || exit 1
    entries=$(find "$LIFECYCLE_LOCK" -mindepth 1 -maxdepth 1 -print 2>/dev/null) || exit 1
    [ "$entries" = "$LIFECYCLE_LOCK_OWNER" ] || exit 1
    after=$(sha256sum "$LIFECYCLE_LOCK_OWNER" 2>/dev/null) || exit 1
    after="${after%% *}"
    [ "$after" = "$before" ] || exit 1
    lease_emit "$expected_pid" "$start" "$boot" "$expected_token"
}

lease_release() {
    local expected_pid="$1" expected_start="$2" expected_boot="$3"
    local expected_token="$4" release_token="$5"
    local gate_token self_start attempts quarantine
    is_decimal "$expected_pid" && [ "$expected_pid" -gt 0 ] 2>/dev/null &&
        is_canonical_nonnegative_i64 "$expected_start" &&
        is_valid_boot_id "$expected_boot" &&
        is_safe_lease_token "$expected_token" &&
        is_safe_lease_token "$release_token" || lease_usage_error
    gate_token="android-release.$release_token"

    z2_read_exact_owner() {
        local key value size entries version kind pid start boot token module owner_order
        local seen_version seen_kind seen_pid seen_start seen_boot seen_token seen_module
        version=""; kind=""; pid=""; start=""; boot=""; token=""; module=""
        owner_order=""
        seen_version=0; seen_kind=0; seen_pid=0; seen_start=0; seen_boot=0; seen_token=0; seen_module=0
        state_dir_is_secure || return 1
        [ -d "$LIFECYCLE_LOCK" ] && [ ! -L "$LIFECYCLE_LOCK" ] || return 1
        path_uid_is_root "$LIFECYCLE_LOCK" || return 1
        [ "$(stat -c %a "$LIFECYCLE_LOCK" 2>/dev/null)" = 700 ] || return 1
        [ -f "$LIFECYCLE_LOCK_OWNER" ] && [ ! -L "$LIFECYCLE_LOCK_OWNER" ] || return 1
        path_uid_is_root "$LIFECYCLE_LOCK_OWNER" || return 1
        [ "$(stat -c %a "$LIFECYCLE_LOCK_OWNER" 2>/dev/null)" = 600 ] || return 1
        [ "$(stat -c %h "$LIFECYCLE_LOCK_OWNER" 2>/dev/null)" = 1 ] || return 1
        size=$(stat -c %s "$LIFECYCLE_LOCK_OWNER" 2>/dev/null) || return 1
        [ "$size" -gt 0 ] && [ "$size" -le 1024 ] || return 1
        while IFS='=' read -r key value; do
            case "$key" in
                version) [ "$seen_version" = 0 ] || return 1; version="$value"; seen_version=1; owner_order="${owner_order}v" ;;
                kind) [ "$seen_kind" = 0 ] || return 1; kind="$value"; seen_kind=1; owner_order="${owner_order}k" ;;
                pid) [ "$seen_pid" = 0 ] || return 1; pid="$value"; seen_pid=1; owner_order="${owner_order}p" ;;
                starttime) [ "$seen_start" = 0 ] || return 1; start="$value"; seen_start=1; owner_order="${owner_order}s" ;;
                boot_id) [ "$seen_boot" = 0 ] || return 1; boot="$value"; seen_boot=1; owner_order="${owner_order}b" ;;
                token) [ "$seen_token" = 0 ] || return 1; token="$value"; seen_token=1; owner_order="${owner_order}t" ;;
                module_dir) [ "$seen_module" = 0 ] || return 1; module="$value"; seen_module=1; owner_order="${owner_order}m" ;;
                *) return 1 ;;
            esac
        done < "$LIFECYCLE_LOCK_OWNER"
        [ "$seen_version:$seen_kind:$seen_pid:$seen_start:$seen_boot:$seen_token:$seen_module" = 1:1:1:1:1:1:1 ] || return 1
        [ "$owner_order" = vkpsbtm ] || return 1
        [ "$version" = "$Z2_LEASE_VERSION" ] && [ "$kind" = "$Z2_LEASE_KIND" ] && [ "$module" = "$module_dir" ] || return 1
        [ "$pid" = "$expected_pid" ] && [ "$start" = "$expected_start" ] &&
            [ "$boot" = "$expected_boot" ] && [ "$token" = "$expected_token" ] || return 1
        entries=$(find "$LIFECYCLE_LOCK" -mindepth 1 -maxdepth 1 -print 2>/dev/null) || return 1
        [ "$entries" = "$LIFECYCLE_LOCK_OWNER" ]
    }

    gate_held=0
    z2_cleanup_release() {
        local rc=$?
        trap - EXIT HUP INT TERM
        if [ "$gate_held" = 1 ]; then
            release_lifecycle_gate "$gate_token" >/dev/null 2>&1 || rc=1
        fi
        exit "$rc"
    }
    trap z2_cleanup_release EXIT
    trap 'exit 1' HUP INT TERM
    proc_starttime_read "$$" || exit 1
    self_start="$PROC_STARTTIME"
    attempts=0
    while [ "$attempts" -lt 3 ]; do
        claim_lifecycle_gate "$self_start" "$gate_token" && break
        attempts=$((attempts + 1))
        sleep 1
    done
    [ "$attempts" -lt 3 ] || exit 1
    gate_held=1
    z2_read_exact_owner || {
        release_lifecycle_gate "$gate_token" >/dev/null 2>&1 || true
        gate_held=0
        echo "ERROR: lifecycle ownership changed; foreign evidence was preserved" >&2
        exit 1
    }
    quarantine="$LIFECYCLE_LOCK_QUARANTINE.release.android.$$.$gate_token"
    [ ! -e "$quarantine" ] && [ ! -L "$quarantine" ] || exit 1
    mv "$LIFECYCLE_LOCK" "$quarantine" || exit 1
    rm -f "$quarantine/owner" || exit 1
    rmdir "$quarantine" || exit 1
    release_lifecycle_gate "$gate_token" >/dev/null 2>&1 || true
    gate_held=0
    trap - EXIT HUP INT TERM
    echo Z2_MUTATION_LOCK_RELEASED=1
}

case "${1:-}" in
    acquire)
        [ "$#" -eq 3 ] || lease_usage_error
        lease_acquire "$2" "$3"
        ;;
    probe)
        [ "$#" -eq 3 ] || lease_usage_error
        lease_probe "$2" "$3"
        ;;
    release)
        [ "$#" -eq 6 ] || lease_usage_error
        lease_release "$2" "$3" "$4" "$5" "$6"
        ;;
    *) lease_usage_error ;;
esac
exit 0
