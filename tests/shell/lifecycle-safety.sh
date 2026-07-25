#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=${Z2_TEST_TMP:?}
CASE="$TMP/lifecycle-safety"
MOCK="$CASE/bin"
mkdir -p "$MOCK"

fail() { echo "FAIL: lifecycle-safety: $*" >&2; exit 1; }

cat > "$MOCK/iptables" <<'EOF'
#!/bin/sh
case "${Z2_QUERY_MODE:-clean}" in
    fail) exit 42 ;;
esac
case " $* " in
    *' -t mangle -L OUTPUT -n '*) exit 0 ;;
    *' -t mangle -S ZAPRET2_OUT '*)
        case "${Z2_QUERY_MODE:-clean}" in
            present|foreign) echo '-N ZAPRET2_OUT'; exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    *' -t mangle -S ZAPRET2_IN '*) exit 1 ;;
esac
case "${Z2_QUERY_MODE:-clean}: $* " in
    present:*' -t mangle -C OUTPUT -j ZAPRET2_OUT '*) exit 0 ;;
    present:*' -t mangle -S ')
        printf '%s\n' '-N ZAPRET2_OUT' '-A OUTPUT -j ZAPRET2_OUT'
        exit 0
        ;;
    foreign:*' -t mangle -S ')
        printf '%s\n' '-N ZAPRET2_OUT' '-A FORWARD -j ZAPRET2_OUT'
        exit 0
        ;;
    clean:*' -t mangle -S ') exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod 0755 "$MOCK/iptables"

SCRIPT_DIR="$ROOT/zapret2/scripts"
ZAPRET_DIR="$ROOT/zapret2"
MODDIR="$ROOT"
STATE_DIR="$CASE/state"
mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"
PATH="$MOCK:$PATH"
export PATH STATE_DIR
. "$ROOT/zapret2/scripts/common.sh"

# A stopped service must not perform the expensive exact identity proof for
# every Android PID. The shell-builtin cmdline prefilter admits the current
# process only when its actual argv0 prefix is selected.
(
    CURRENT_ARGV0="$(proc_argv0 "$$")" || fail "current argv0 unavailable"
    NFQWS2="$CURRENT_ARGV0"
    proc_cmdline_may_match_nfqws "$$" || fail "exact argv0 candidate was filtered out"
    NFQWS2="${CURRENT_ARGV0}.not-the-current-process"
    if proc_cmdline_may_match_nfqws "$$"; then fail "non-candidate argv0 prefix was admitted"; fi
    NFQWS2=/definitely/not/a/zapret2/process
    verify_nfqws_pid() { fail "strict PID proof ran for a non-candidate process"; }
    scan_exact_owned_nfqws >/dev/null || fail "empty exact process scan failed"
    [ -z "$OWNED_SCAN_PIDS" ] || fail "empty exact process scan reported an owner"
)

Z2_QUERY_MODE=fail; export Z2_QUERY_MODE
set +e
owned_family_present iptables
rc=$?
set -e
[ "$rc" = 2 ] || fail "query failure was not tri-state error"
if owned_family_absent iptables; then fail "query failure was accepted as absence"; fi

Z2_QUERY_MODE=clean; export Z2_QUERY_MODE
set +e
owned_family_present iptables
rc=$?
set -e
[ "$rc" = 1 ] || fail "clean snapshot was not absence"
owned_family_absent iptables || fail "clean snapshot absence was rejected"

Z2_QUERY_MODE=present; export Z2_QUERY_MODE
owned_family_present iptables || fail "owned chain/anchor was not detected"
if owned_family_absent iptables; then fail "owned state was accepted as absent"; fi

# An IPv6 frontend that exists but cannot answer is not a proof of absence.
# A family that cannot be queried now but might answer in a moment is a busy
# lock: teardown must retry rather than accept it. A family that stays
# unqueryable can never be proven on this device, so refusing forever would
# fence every teardown until a reboot that would refuse the same way — it is
# skipped instead, and the skip is reported unless our own record already
# proves this generation published nothing there.
cat > "$MOCK/ip6tables" <<'EOF'
#!/bin/sh
count_file="${Z2_IP6_PROBE_COUNT:-}"
if [ -n "$count_file" ]; then
    n=0
    [ ! -f "$count_file" ] || IFS= read -r n < "$count_file"
    n=$((n + 1))
    printf '%s\n' "$n" > "$count_file"
    succeed_at="${Z2_IP6_PROBE_SUCCEED_AT:-0}"
    if [ "$succeed_at" -gt 0 ] && [ "$n" -ge "$succeed_at" ]; then exit 0; fi
fi
exit 42
EOF
chmod 0755 "$MOCK/ip6tables"
(
    Z2_QUERY_MODE=clean; export Z2_QUERY_MODE
    z2_fw_cleanup_family() { return 0; }

    FIREWALL_PROBE_ATTEMPTS=3
    Z2_IP6_PROBE_COUNT="$CASE/ip6probe"; export Z2_IP6_PROBE_COUNT
    Z2_IP6_PROBE_SUCCEED_AT=2; export Z2_IP6_PROBE_SUCCEED_AT
    rm -f "$Z2_IP6_PROBE_COUNT"
    CLEANUP_IPV6_OWNERSHIP_EXPECTED=1
    cleanup_owned_firewall audited ||
        fail "a frontend that answered on retry was treated as permanently unavailable"
    [ "${FIREWALL_IPV6_SKIPPED_UNPROVEN:-0}" = 0 ] ||
        fail "a family that was actually torn down was reported as skipped"

    Z2_IP6_PROBE_SUCCEED_AT=0; export Z2_IP6_PROBE_SUCCEED_AT
    rm -f "$Z2_IP6_PROBE_COUNT"
    FIREWALL_PROBE_ATTEMPTS=1
    CLEANUP_IPV6_OWNERSHIP_EXPECTED=1
    cleanup_owned_firewall audited ||
        fail "a permanently unqueryable family fenced the teardown"
    [ "${FIREWALL_IPV6_SKIPPED_UNPROVEN:-0}" = 1 ] ||
        fail "an unqueryable IPv6 family was skipped without reporting it"

    rm -f "$Z2_IP6_PROBE_COUNT"
    CLEANUP_IPV6_OWNERSHIP_EXPECTED=0
    cleanup_owned_firewall audited ||
        fail "a family this generation never published still blocked cleanup"
    [ "${FIREWALL_IPV6_SKIPPED_UNPROVEN:-0}" = 0 ] ||
        fail "a proven-absent family produced a reservation"
)
rm -f "$MOCK/ip6tables"

Z2_QUERY_MODE=foreign; export Z2_QUERY_MODE
if z2_fw_cleanup_is_unambiguous iptables; then
    fail "foreign reference to the stable namespace passed cleanup preflight"
fi

grep -Fq 'boot_id=%s' "$ROOT/zapret2/scripts/common.sh" || fail "owner publication is not boot-bound"
grep -Fq 'return 2' "$ROOT/zapret2/scripts/common.sh" || fail "tri-state query error is absent"
grep -Fq 'phase_at_least process-clean' "$ROOT/zapret2/scripts/zapret-full-rollback.sh" || fail "rollback resume gates are absent"

# Boot-local firewall state is reconstructed from one stable namespace. It has
# no durability journal and rejects ambiguous foreign references before delete.
grep -Fq 'z2_fw_cleanup_is_unambiguous' "$ROOT/zapret2/scripts/firewall-reconciler.sh" ||
    fail "stable namespace cleanup preflight is absent"
grep -Fq -- '--test --noflush' "$ROOT/zapret2/scripts/firewall-reconciler.sh" ||
    fail "whole-batch restore validation is absent"
if grep -Eq 'prepare_teardown_marker|consume_bracketed_teardown_target|target-consumed' \
    "$ROOT/zapret2/scripts/firewall-reconciler.sh"; then
    fail "firewall reconciler contains obsolete teardown WAL machinery"
fi

echo "Lifecycle safety shell tests passed"
