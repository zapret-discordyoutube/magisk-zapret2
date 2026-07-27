#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
fail() { echo "FAIL: daemon-replace-transaction: $*" >&2; exit 1; }

# The file is a source-only transaction layer.
log_msg() { :; }
. "$ROOT/zapret2/scripts/daemon-replace-transaction.sh"

LOCK_HELD=1
COMPILED_ARGV_FILE=/state/compiled.argv
PRESETS_DIR=/module/presets
ACTIVE_PRESET=Alpha.txt
QNUM=200
DESYNC_MARK=0x40000000
INSTALL_META_GENERATION=install-a
INSTALL_META_ARCHIVE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
COMPILED_METADATA_FOR="$COMPILED_ARGV_FILE"
COMPILED_PRESET=Alpha.txt
COMPILED_TCP_PORTS=80
COMPILED_UDP_PORTS=443
COMPILED_TCP_PKT_OUT=20
COMPILED_TCP_PKT_IN=10
COMPILED_UDP_PKT_OUT=20
COMPILED_UDP_PKT_IN=10

read_install_generation_meta() { return 0; }
daemon_replace_binding_current() { return 0; }
compiled_validation_receipt_current() { return 0; }
preflight_owned_process_cleanup() {
    PROCESS_PREFLIGHT_LIVE=1
    PROCESS_PREFLIGHT_PHASE=active
    PROCESS_PREFLIGHT_PID=41
    PROCESS_PREFLIGHT_START=900
    PROCESS_PREFLIGHT_ARGV_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    return 0
}
read_owner_state() {
    OWNER_STATE_PID=41
    OWNER_STATE_START=900
    OWNER_STATE_ARGV_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    OWNER_STATE_QNUM=200
    OWNER_STATE_INSTALL_GENERATION=install-a
    OWNER_STATE_INSTALL_ARCHIVE_SHA256="$INSTALL_META_ARCHIVE_SHA256"
    OWNER_STATE_FIREWALL_FINGERPRINT=fingerprint-a
    OWNER_STATE_FIREWALL_TAG=stable0001
    OWNER_STATE_OUT_CHAIN=ZAPRET2_OUT
    OWNER_STATE_IN_CHAIN=ZAPRET2_IN
    OWNER_STATE_TETHERING=0
    OWNER_STATE_PORTS_TCP=80
    OWNER_STATE_PORTS_UDP=443
    OWNER_STATE_STUN_PORTS=0
    OWNER_STATE_TCP_PKT_OUT=20
    OWNER_STATE_TCP_PKT_IN=10
    OWNER_STATE_UDP_PKT_OUT=20
    OWNER_STATE_UDP_PKT_IN=10
    OWNER_STATE_DESYNC_MARK=0x40000000
    OWNER_STATE_IPV4_ACTIVE=1
    OWNER_STATE_IPV4_CONNBYTES=1
    OWNER_STATE_IPV4_MULTIPORT=1
    OWNER_STATE_IPV4_MARK=1
    OWNER_STATE_IPV6_ACTIVE=1
    OWNER_STATE_IPV6_CONNBYTES=1
    OWNER_STATE_IPV6_MULTIPORT=1
    OWNER_STATE_IPV6_MARK=1
    OWNER_STATE_IPV4_RULES=4
    OWNER_STATE_IPV6_RULES=4
    OWNER_STATE_IPV4_SPEC=ipv4-spec
    OWNER_STATE_IPV6_SPEC=ipv6-spec
    return 0
}
owner_state_is_current_boot() { return 0; }
canonical_mark() { MARK_CANONICAL="$1"; return 0; }
resolve_ipv6_ownership_expectation() { return 0; }

daemon_replace_prepare ||
    fail "an unchanged validated topology was refused"
[ "$PORTS_TCP:$PORTS_UDP" = 80:443 ] ||
    fail "compiled port topology was not projected"
[ "$Z2_DAEMON_REPLACE_FIREWALL_FINGERPRINT" = fingerprint-a ] ||
    fail "the retained firewall identity was not captured"

COMPILED_TCP_PORTS=81
set +e
daemon_replace_prepare
prepare_rc=$?
set -e
[ "$prepare_rc" -eq 2 ] ||
    fail "a changed firewall topology did not return the topology result"
[ "$Z2_DAEMON_REPLACE_TOPOLOGY_CHANGED" = 1 ] ||
    fail "a changed firewall topology was not classified for in-process replacement"
COMPILED_TCP_PORTS=80

# The typed topology result must leave the transaction unentered and reach the
# lock-owning caller as exit 2, not collapse into the generic ineligibility
# error that would keep the topology layer permanently unreachable.
calls=
daemon_replace_prepare() {
    calls="${calls}prepare "
    Z2_DAEMON_REPLACE_TOPOLOGY_CHANGED=1
    return 2
}
stop_pidfile_process() { calls="${calls}stop "; return 0; }
set +e
replace_daemon_in_locked_transaction
topology_rc=$?
set -e
[ "$topology_rc" -eq 2 ] ||
    fail "a changed topology did not propagate the typed result to the caller"
[ "$calls" = "prepare " ] ||
    fail "a changed topology still entered the daemon-only mutation: $calls"
[ -z "$Z2_DAEMON_REPLACE_ERROR_CODE" ] ||
    fail "a changed topology was misreported as a typed failure"
[ "$Z2_DAEMON_REPLACE_CONTROLLED" = 0 ] ||
    fail "a changed topology fenced the transaction as controlled"

# Pin the transaction state machine separately from the proof constructor.
calls=
daemon_replace_prepare() { calls="${calls}prepare "; return 0; }
stop_pidfile_process() { calls="${calls}stop "; return 0; }
daemon_replace_launch() {
    calls="${calls}launch "
    PUBLISHED_PID=51
    STARTED_PID=51
    PUBLISHED_START=901
    STARTED_PID_START=901
    PUBLISHED_FIREWALL_FINGERPRINT=fingerprint-a
    Z2_DAEMON_REPLACE_FIREWALL_FINGERPRINT=fingerprint-a
    PUBLISHED_INSTALL_GENERATION=install-a
    PUBLISHED_INSTALL_ARCHIVE_SHA256="$INSTALL_META_ARCHIVE_SHA256"
    return 0
}
daemon_replace_write_ok_status() { calls="${calls}status "; return 0; }

replace_daemon_in_locked_transaction ||
    fail "the prepared daemon replacement did not commit"
[ "$calls" = "prepare stop launch status " ] ||
    fail "the success state sequence changed: $calls"

# P7: a diagnostic snapshot failure cannot undo a durable process/owner commit.
calls=
daemon_replace_write_ok_status() { calls="${calls}status "; return 1; }
replace_daemon_in_locked_transaction ||
    fail "a status-only failure undid a completed replacement"
[ "$calls" = "prepare stop launch status " ] ||
    fail "the status-failure sequence changed: $calls"

# A launch failure converges the retained firewall generation to stopped before
# the caller restores preset/runtime content.
calls=
daemon_replace_launch() { calls="${calls}launch "; return 1; }
daemon_replace_converge_stopped() { calls="${calls}rollback "; return 0; }
daemon_replace_write_error_status() { calls="${calls}error-status "; return 0; }
if replace_daemon_in_locked_transaction; then
    fail "a failed launch reported success"
fi
[ "$calls" = "prepare stop launch rollback error-status " ] ||
    fail "the launch-failure sequence changed: $calls"
[ "$Z2_DAEMON_REPLACE_ERROR_CODE:$Z2_DAEMON_REPLACE_ERROR_STAGE" = PROCESS_LAUNCH_FAILED:START_LAUNCH ] ||
    fail "the launch failure lost its stable typed identity"

echo "Daemon replace transaction shell tests passed"
