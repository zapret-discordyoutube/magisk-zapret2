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

# The probe budget belongs to the preflight, which is also the only step that
# can capture a family's baseline. A teardown that waited again on its own
# would walk a recovered frontend into an audited cleanup with no baseline —
# and fail the teardown precisely on the devices the budget was added for.
(
    Z2_QUERY_MODE=clean; export Z2_QUERY_MODE
    Z2_IP6_PROBE_COUNT="$CASE/ip6probe.preflight"; export Z2_IP6_PROBE_COUNT
    Z2_IP6_PROBE_SUCCEED_AT=0; export Z2_IP6_PROBE_SUCCEED_AT
    rm -f "$Z2_IP6_PROBE_COUNT"
    FIREWALL_PROBE_ATTEMPTS=1
    audit_owned_firewall_for_cleanup ||
        fail "an unqueryable IPv6 family blocked the cleanup preflight"
    [ "${FIREWALL_IPV6_UNQUERYABLE:-0}" = 1 ] ||
        fail "the preflight did not record that it could not read the family"

    # The frontend comes back before teardown. Cleanup must not reach into an
    # audited teardown for a family whose baseline was never captured.
    Z2_IP6_PROBE_SUCCEED_AT=1; export Z2_IP6_PROBE_SUCCEED_AT
    rm -f "$Z2_IP6_PROBE_COUNT"
    z2_fw_cleanup_family() {
        [ "$1" != ip6tables ] ||
            fail "audited teardown ran for a family whose baseline was never captured"
        return 0
    }
    CLEANUP_IPV6_OWNERSHIP_EXPECTED=1
    cleanup_owned_firewall audited ||
        fail "teardown failed on a family whose baseline the preflight never captured"
    [ "${FIREWALL_IPV6_SKIPPED_UNPROVEN:-0}" = 1 ] ||
        fail "the skipped family was not reported"
)
# A frontend that answers now and goes busy later. In clean mode it delegates
# to the IPv4 mock, so the preflight sees a real, readable, empty family.
cat > "$MOCK/ip6tables" <<'EOF'
#!/bin/sh
mode=fail
[ ! -f "$Z2_IP6_MODE_FILE" ] || IFS= read -r mode < "$Z2_IP6_MODE_FILE"
[ "$mode" != fail ] || exit 42
Z2_QUERY_MODE="$mode" exec iptables "$@"
EOF
chmod 0755 "$MOCK/ip6tables"

# A preflight read that found nothing of ours is positive knowledge. If the
# frontend goes busy before teardown, discarding it turns "we looked and it was
# empty" into "we could not look" and raises a reservation the run can prove is
# unnecessary — a false alarm on the one channel that is meant to carry real
# uncertainty to the user.
(
    Z2_QUERY_MODE=clean; export Z2_QUERY_MODE
    Z2_IP6_MODE_FILE="$CASE/ip6mode"; export Z2_IP6_MODE_FILE
    z2_fw_cleanup_family() { return 0; }

    printf 'clean\n' > "$Z2_IP6_MODE_FILE"
    FIREWALL_PROBE_ATTEMPTS=1
    audit_owned_firewall_for_cleanup || fail "a readable empty IPv6 family failed the preflight"
    [ "${FIREWALL_IPV6_UNQUERYABLE:-1}" = 0 ] ||
        fail "a family the preflight actually read was recorded as unreadable"
    [ "${FIREWALL_IPV6_AUDITED_EMPTY:-0}" = 1 ] ||
        fail "the preflight did not record that it proved the family empty"

    printf 'fail\n' > "$Z2_IP6_MODE_FILE"
    CLEANUP_IPV6_OWNERSHIP_EXPECTED=1
    cleanup_owned_firewall audited ||
        fail "a family proven empty by the preflight fenced the teardown"
    [ "${FIREWALL_IPV6_SKIPPED_UNPROVEN:-0}" = 0 ] ||
        fail "a family the preflight proved empty still produced a reservation"

    # The same window, but the preflight found owned rules. Losing the frontend
    # now is real uncertainty and must be reported.
    printf 'present\n' > "$Z2_IP6_MODE_FILE"
    audit_owned_firewall_for_cleanup || fail "a readable populated IPv6 family failed the preflight"
    [ "${FIREWALL_IPV6_AUDITED_EMPTY:-1}" = 0 ] ||
        fail "a family holding owned rules was recorded as proven empty"
    printf 'fail\n' > "$Z2_IP6_MODE_FILE"
    cleanup_owned_firewall audited ||
        fail "an unreadable populated family fenced the teardown"
    [ "${FIREWALL_IPV6_SKIPPED_UNPROVEN:-0}" = 1 ] ||
        fail "a family that held owned rules was skipped without reporting it"
)

# An owned teardown captures its own baseline, so it never inherits the
# preflight's proof — including a stale one left by an earlier audited run in
# the same process.
(
    Z2_QUERY_MODE=clean; export Z2_QUERY_MODE
    Z2_IP6_MODE_FILE="$CASE/ip6mode.owned"; export Z2_IP6_MODE_FILE
    FIREWALL_PROBE_ATTEMPTS=1

    printf 'clean\n' > "$Z2_IP6_MODE_FILE"
    ipv6_torn_down=0
    z2_fw_cleanup_family() { [ "$1" != ip6tables ] || ipv6_torn_down=1; return 0; }
    CLEANUP_IPV6_OWNERSHIP_EXPECTED=1
    cleanup_owned_firewall owned || fail "an owned teardown failed on a readable family"
    [ "$ipv6_torn_down" = 1 ] ||
        fail "an owned teardown skipped a family it could read and own a baseline for"
    [ "${FIREWALL_IPV6_SKIPPED_UNPROVEN:-0}" = 0 ] ||
        fail "a family the owned teardown actually removed was reported as skipped"

    printf 'fail\n' > "$Z2_IP6_MODE_FILE"
    FIREWALL_IPV6_AUDITED_EMPTY=1
    z2_fw_cleanup_family() {
        [ "$1" != ip6tables ] || fail "an owned teardown ran against an unreachable frontend"
        return 0
    }
    cleanup_owned_firewall owned || fail "an unreadable family fenced an owned teardown"
    [ "${FIREWALL_IPV6_SKIPPED_UNPROVEN:-0}" = 1 ] ||
        fail "an owned teardown reused another mode's proof to suppress a reservation"
)
rm -f "$MOCK/ip6tables"

Z2_QUERY_MODE=foreign; export Z2_QUERY_MODE
if z2_fw_cleanup_is_unambiguous iptables; then
    fail "foreign reference to the stable namespace passed cleanup preflight"
fi

# An operation's own receipt must carry that operation's reservation. A stopped
# receipt that always certified the ruleset forced the caller to withhold the
# receipt and infer the reservation from a second, separately-raced observation
# — the extra trip through the snapshot that kept losing it.
(
    ZAPRET2_EMIT_STATUS_V6=1; export ZAPRET2_EMIT_STATUS_V6
    STATUS_RULESET_VERIFIED=0
    receipt="$(emit_committed_status_v6 stopped idle none)" ||
        fail "a stop with a reservation could not emit its receipt at all"
    printf '%s\n' "$receipt" | grep -Fxq 'Z2_STATUS=stopped' ||
        fail "the reserved receipt did not report a stopped service"
    printf '%s\n' "$receipt" | grep -Fxq 'Z2_RULESET_VERIFIED=0' ||
        fail "a stopped receipt certified a ruleset this teardown could not read"

    STATUS_RULESET_VERIFIED=1
    receipt="$(emit_committed_status_v6 stopped idle none)" ||
        fail "a fully verified stop could not emit its receipt"
    printf '%s\n' "$receipt" | grep -Fxq 'Z2_RULESET_VERIFIED=1' ||
        fail "a fully verified stop lost its verification claim"

    unset STATUS_RULESET_VERIFIED
    receipt="$(emit_committed_status_v6 stopped idle none)" ||
        fail "an unrecorded verification could not emit a receipt"
    printf '%s\n' "$receipt" | grep -Fxq 'Z2_RULESET_VERIFIED=0' ||
        fail "an unrecorded verification defaulted to asserting one"
)
if sed -n '/if \[ "\$STOP_STATUS_COMMITTED" = 1 \]/p' "$ROOT/zapret2/scripts/zapret-stop.sh" |
   grep -Fq 'FIREWALL_IPV6_SKIPPED_UNPROVEN'; then
    fail "the stop receipt is withheld again when a family had to be skipped"
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
