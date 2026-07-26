#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
fail() { echo "FAIL: topology-replace-transaction: $*" >&2; exit 1; }

log_msg() { :; }
. "$ROOT/zapret2/scripts/topology-replace-transaction.sh"

calls=
Z2_DAEMON_REPLACE_CONTROLLED=0
Z2_TOPOLOGY_NEW_FIREWALL_FINGERPRINT=new-fingerprint
INSTALL_META_GENERATION=install-a
INSTALL_META_ARCHIVE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
daemon_replace_set_error() {
    Z2_DAEMON_REPLACE_ERROR_DOMAIN="$1"
    Z2_DAEMON_REPLACE_ERROR_CODE="$2"
    Z2_DAEMON_REPLACE_ERROR_STAGE="$3"
    Z2_DAEMON_REPLACE_ERROR_DETAIL="$4"
    return 1
}

topology_replace_prepare() { calls="${calls}prepare "; return 0; }
stop_pidfile_process() { calls="${calls}stop "; return 0; }
topology_load_generation() {
    calls="${calls}load-$1 "
    return 0
}
topology_reconfigure_loaded_generation() {
    calls="${calls}firewall "
    return 0
}
daemon_replace_launch() {
    calls="${calls}launch "
    STARTED_PID=51
    STARTED_PID_START=901
    PUBLISHED_PID=51
    PUBLISHED_START=901
    PUBLISHED_FIREWALL_FINGERPRINT=new-fingerprint
    return 0
}
daemon_replace_write_ok_status() { calls="${calls}status "; return 0; }

replace_topology_in_locked_transaction ||
    fail "the prepared topology replacement did not commit"
[ "$calls" = "prepare stop load-new firewall load-new launch status " ] ||
    fail "the success state sequence changed: $calls"
[ "$Z2_DAEMON_REPLACE_CONTROLLED" = 1 ] ||
    fail "topology mutation was not fenced as controlled"

# A family publication failure enters exactly one rollback and never launches
# the candidate afterward.
calls=
topology_reconfigure_loaded_generation() {
    calls="${calls}firewall-fail "
    Z2_FW_ERROR_DETAIL="mock publication failure"
    return 1
}
topology_rollback_live_generation() {
    calls="${calls}rollback "
    return 0
}
if replace_topology_in_locked_transaction; then
    fail "a failed topology publication reported success"
fi
[ "$calls" = "prepare stop load-new firewall-fail rollback " ] ||
    fail "the publication-failure sequence changed: $calls"
[ "$Z2_DAEMON_REPLACE_ERROR_CODE:$Z2_DAEMON_REPLACE_ERROR_STAGE" = \
    FIREWALL_PUBLICATION_FAILED:START_FIREWALL_IPV4 ] ||
    fail "the publication failure lost its stable typed identity"

# Rollback restores the old firewall before it binds and publishes the old
# daemon. A status-only failure cannot turn a successful rollback into an
# incomplete one.
. "$ROOT/zapret2/scripts/topology-replace-transaction.sh"
calls=
topology_stop_partial_candidate() { calls="${calls}stop-candidate "; return 0; }
topology_restore_old_firewall() { calls="${calls}restore-firewall "; return 0; }
topology_relaunch_old_generation() { calls="${calls}relaunch-old "; return 0; }
daemon_replace_write_ok_status() { calls="${calls}status "; return 1; }
topology_rollback_live_generation ||
    fail "a complete old-generation rollback was rejected"
[ "$calls" = "stop-candidate restore-firewall relaunch-old status " ] ||
    fail "the rollback sequence changed: $calls"

# The family that rejected its atomic commit is preserved in the typed stage;
# otherwise an IPv6-only backend failure is misreported as an IPv4 mutation.
. "$ROOT/zapret2/scripts/topology-replace-transaction.sh"
calls=
IPV4_CONNBYTES=1
IPV4_MULTIPORT=1
IPV6_ACTIVE=1
IPV6_CONNBYTES=1
IPV6_MULTIPORT=1
z2_fw_reconfigure_family() {
    calls="${calls}$1 "
    [ "$1" != ip6tables ]
}
if topology_reconfigure_loaded_generation; then
    fail "an IPv6 reconfiguration failure reported success"
fi
[ "$calls" = "iptables ip6tables " ] ||
    fail "the family publication order changed: $calls"
[ "$Z2_TOPOLOGY_FIREWALL_STAGE" = START_FIREWALL_IPV6 ] ||
    fail "the IPv6 failure lost its typed stage"

echo "Topology replace transaction shell tests passed"
