#!/system/bin/sh
# In-process replacement for a validated preset whose capture topology changed.
#
# The caller holds the lifecycle lock, has authenticated the running process
# and owner receipt, and has already dry-run the candidate argv. This layer
# audits the exact old chains once, snapshots both rule generations in memory,
# then replaces only the contents of the stable private chains. Every family
# commit is atomic. Any later failure restores those old rules and relaunches
# the preserved old argv before the outer transaction restores runtime data.

Z2_TOPOLOGY_OLD_PORTS_TCP=
Z2_TOPOLOGY_OLD_PORTS_UDP=
Z2_TOPOLOGY_OLD_TCP_PKT_OUT=
Z2_TOPOLOGY_OLD_TCP_PKT_IN=
Z2_TOPOLOGY_OLD_UDP_PKT_OUT=
Z2_TOPOLOGY_OLD_UDP_PKT_IN=
Z2_TOPOLOGY_OLD_DESYNC_MARK=
Z2_TOPOLOGY_OLD_IPV4_CONNBYTES=0
Z2_TOPOLOGY_OLD_IPV4_MULTIPORT=0
Z2_TOPOLOGY_OLD_IPV4_MARK=0
Z2_TOPOLOGY_OLD_IPV6_ACTIVE=0
Z2_TOPOLOGY_OLD_IPV6_CONNBYTES=0
Z2_TOPOLOGY_OLD_IPV6_MULTIPORT=0
Z2_TOPOLOGY_OLD_IPV6_MARK=0
Z2_TOPOLOGY_OLD_IPV4_RULES=0
Z2_TOPOLOGY_OLD_IPV6_RULES=0
Z2_TOPOLOGY_OLD_IPV4_SPEC=
Z2_TOPOLOGY_OLD_IPV6_SPEC=
Z2_TOPOLOGY_OLD_FIREWALL_FINGERPRINT=

Z2_TOPOLOGY_NEW_PORTS_TCP=
Z2_TOPOLOGY_NEW_PORTS_UDP=
Z2_TOPOLOGY_NEW_TCP_PKT_OUT=
Z2_TOPOLOGY_NEW_TCP_PKT_IN=
Z2_TOPOLOGY_NEW_UDP_PKT_OUT=
Z2_TOPOLOGY_NEW_UDP_PKT_IN=
Z2_TOPOLOGY_NEW_DESYNC_MARK=
Z2_TOPOLOGY_NEW_IPV4_CONNBYTES=0
Z2_TOPOLOGY_NEW_IPV4_MULTIPORT=0
Z2_TOPOLOGY_NEW_IPV4_MARK=0
Z2_TOPOLOGY_NEW_IPV6_ACTIVE=0
Z2_TOPOLOGY_NEW_IPV6_CONNBYTES=0
Z2_TOPOLOGY_NEW_IPV6_MULTIPORT=0
Z2_TOPOLOGY_NEW_IPV6_MARK=0
Z2_TOPOLOGY_NEW_IPV4_RULES=0
Z2_TOPOLOGY_NEW_IPV6_RULES=0
Z2_TOPOLOGY_NEW_IPV4_SPEC=
Z2_TOPOLOGY_NEW_IPV6_SPEC=
Z2_TOPOLOGY_NEW_FIREWALL_FINGERPRINT=
Z2_TOPOLOGY_FIREWALL_STAGE=START_FIREWALL_IPV4

topology_snapshot_old_generation() {
    Z2_TOPOLOGY_OLD_PORTS_TCP="$OWNER_STATE_PORTS_TCP"
    Z2_TOPOLOGY_OLD_PORTS_UDP="$OWNER_STATE_PORTS_UDP"
    Z2_TOPOLOGY_OLD_TCP_PKT_OUT="$OWNER_STATE_TCP_PKT_OUT"
    Z2_TOPOLOGY_OLD_TCP_PKT_IN="$OWNER_STATE_TCP_PKT_IN"
    Z2_TOPOLOGY_OLD_UDP_PKT_OUT="$OWNER_STATE_UDP_PKT_OUT"
    Z2_TOPOLOGY_OLD_UDP_PKT_IN="$OWNER_STATE_UDP_PKT_IN"
    Z2_TOPOLOGY_OLD_DESYNC_MARK="$OWNER_STATE_DESYNC_MARK"
    Z2_TOPOLOGY_OLD_IPV4_CONNBYTES="$OWNER_STATE_IPV4_CONNBYTES"
    Z2_TOPOLOGY_OLD_IPV4_MULTIPORT="$OWNER_STATE_IPV4_MULTIPORT"
    Z2_TOPOLOGY_OLD_IPV4_MARK="$OWNER_STATE_IPV4_MARK"
    Z2_TOPOLOGY_OLD_IPV6_ACTIVE="$OWNER_STATE_IPV6_ACTIVE"
    Z2_TOPOLOGY_OLD_IPV6_CONNBYTES="$OWNER_STATE_IPV6_CONNBYTES"
    Z2_TOPOLOGY_OLD_IPV6_MULTIPORT="$OWNER_STATE_IPV6_MULTIPORT"
    Z2_TOPOLOGY_OLD_IPV6_MARK="$OWNER_STATE_IPV6_MARK"
    Z2_TOPOLOGY_OLD_IPV4_RULES="$OWNER_STATE_IPV4_RULES"
    Z2_TOPOLOGY_OLD_IPV6_RULES="$OWNER_STATE_IPV6_RULES"
    Z2_TOPOLOGY_OLD_IPV4_SPEC="$OWNER_STATE_IPV4_SPEC"
    Z2_TOPOLOGY_OLD_IPV6_SPEC="$OWNER_STATE_IPV6_SPEC"
    Z2_TOPOLOGY_OLD_FIREWALL_FINGERPRINT="$OWNER_STATE_FIREWALL_FINGERPRINT"
}

topology_snapshot_new_generation() {
    Z2_TOPOLOGY_NEW_PORTS_TCP="$OWNER_WRITE_PORTS_TCP"
    Z2_TOPOLOGY_NEW_PORTS_UDP="$OWNER_WRITE_PORTS_UDP"
    Z2_TOPOLOGY_NEW_TCP_PKT_OUT="$OWNER_WRITE_TCP_PKT_OUT"
    Z2_TOPOLOGY_NEW_TCP_PKT_IN="$OWNER_WRITE_TCP_PKT_IN"
    Z2_TOPOLOGY_NEW_UDP_PKT_OUT="$OWNER_WRITE_UDP_PKT_OUT"
    Z2_TOPOLOGY_NEW_UDP_PKT_IN="$OWNER_WRITE_UDP_PKT_IN"
    Z2_TOPOLOGY_NEW_DESYNC_MARK="$OWNER_WRITE_DESYNC_MARK"
    Z2_TOPOLOGY_NEW_IPV4_CONNBYTES="$OWNER_WRITE_IPV4_CONNBYTES"
    Z2_TOPOLOGY_NEW_IPV4_MULTIPORT="$OWNER_WRITE_IPV4_MULTIPORT"
    Z2_TOPOLOGY_NEW_IPV4_MARK="$OWNER_WRITE_IPV4_MARK"
    Z2_TOPOLOGY_NEW_IPV6_ACTIVE="$OWNER_WRITE_IPV6_ACTIVE"
    Z2_TOPOLOGY_NEW_IPV6_CONNBYTES="$OWNER_WRITE_IPV6_CONNBYTES"
    Z2_TOPOLOGY_NEW_IPV6_MULTIPORT="$OWNER_WRITE_IPV6_MULTIPORT"
    Z2_TOPOLOGY_NEW_IPV6_MARK="$OWNER_WRITE_IPV6_MARK"
    Z2_TOPOLOGY_NEW_IPV4_RULES="$OWNER_WRITE_IPV4_RULES"
    Z2_TOPOLOGY_NEW_IPV6_RULES="$OWNER_WRITE_IPV6_RULES"
    Z2_TOPOLOGY_NEW_IPV4_SPEC="$OWNER_WRITE_IPV4_SPEC"
    Z2_TOPOLOGY_NEW_IPV6_SPEC="$OWNER_WRITE_IPV6_SPEC"
    Z2_TOPOLOGY_NEW_FIREWALL_FINGERPRINT="$OWNER_WRITE_FIREWALL_FINGERPRINT"
}

topology_load_generation() {
    local which="$1"
    case "$which" in
        old)
            PORTS_TCP="$Z2_TOPOLOGY_OLD_PORTS_TCP"
            PORTS_UDP="$Z2_TOPOLOGY_OLD_PORTS_UDP"
            TCP_PKT_OUT="$Z2_TOPOLOGY_OLD_TCP_PKT_OUT"
            TCP_PKT_IN="$Z2_TOPOLOGY_OLD_TCP_PKT_IN"
            UDP_PKT_OUT="$Z2_TOPOLOGY_OLD_UDP_PKT_OUT"
            UDP_PKT_IN="$Z2_TOPOLOGY_OLD_UDP_PKT_IN"
            DESYNC_MARK="$Z2_TOPOLOGY_OLD_DESYNC_MARK"
            IPV4_CONNBYTES="$Z2_TOPOLOGY_OLD_IPV4_CONNBYTES"
            IPV4_MULTIPORT="$Z2_TOPOLOGY_OLD_IPV4_MULTIPORT"
            IPV4_MARK="$Z2_TOPOLOGY_OLD_IPV4_MARK"
            IPV6_ACTIVE="$Z2_TOPOLOGY_OLD_IPV6_ACTIVE"
            IPV6_CONNBYTES="$Z2_TOPOLOGY_OLD_IPV6_CONNBYTES"
            IPV6_MULTIPORT="$Z2_TOPOLOGY_OLD_IPV6_MULTIPORT"
            IPV6_MARK="$Z2_TOPOLOGY_OLD_IPV6_MARK"
            IPV4_RULES="$Z2_TOPOLOGY_OLD_IPV4_RULES"
            IPV6_RULES="$Z2_TOPOLOGY_OLD_IPV6_RULES"
            OWNER_WRITE_IPV4_SPEC="$Z2_TOPOLOGY_OLD_IPV4_SPEC"
            OWNER_WRITE_IPV6_SPEC="$Z2_TOPOLOGY_OLD_IPV6_SPEC"
            OWNER_WRITE_FIREWALL_FINGERPRINT="$Z2_TOPOLOGY_OLD_FIREWALL_FINGERPRINT"
            ;;
        new)
            PORTS_TCP="$Z2_TOPOLOGY_NEW_PORTS_TCP"
            PORTS_UDP="$Z2_TOPOLOGY_NEW_PORTS_UDP"
            TCP_PKT_OUT="$Z2_TOPOLOGY_NEW_TCP_PKT_OUT"
            TCP_PKT_IN="$Z2_TOPOLOGY_NEW_TCP_PKT_IN"
            UDP_PKT_OUT="$Z2_TOPOLOGY_NEW_UDP_PKT_OUT"
            UDP_PKT_IN="$Z2_TOPOLOGY_NEW_UDP_PKT_IN"
            DESYNC_MARK="$Z2_TOPOLOGY_NEW_DESYNC_MARK"
            IPV4_CONNBYTES="$Z2_TOPOLOGY_NEW_IPV4_CONNBYTES"
            IPV4_MULTIPORT="$Z2_TOPOLOGY_NEW_IPV4_MULTIPORT"
            IPV4_MARK="$Z2_TOPOLOGY_NEW_IPV4_MARK"
            IPV6_ACTIVE="$Z2_TOPOLOGY_NEW_IPV6_ACTIVE"
            IPV6_CONNBYTES="$Z2_TOPOLOGY_NEW_IPV6_CONNBYTES"
            IPV6_MULTIPORT="$Z2_TOPOLOGY_NEW_IPV6_MULTIPORT"
            IPV6_MARK="$Z2_TOPOLOGY_NEW_IPV6_MARK"
            IPV4_RULES="$Z2_TOPOLOGY_NEW_IPV4_RULES"
            IPV6_RULES="$Z2_TOPOLOGY_NEW_IPV6_RULES"
            OWNER_WRITE_IPV4_SPEC="$Z2_TOPOLOGY_NEW_IPV4_SPEC"
            OWNER_WRITE_IPV6_SPEC="$Z2_TOPOLOGY_NEW_IPV6_SPEC"
            OWNER_WRITE_FIREWALL_FINGERPRINT="$Z2_TOPOLOGY_NEW_FIREWALL_FINGERPRINT"
            ;;
        *) return 1 ;;
    esac
    IPV4_ACTIVE=1
    IPV4_BUILT=1
    IPV6_BUILT="$IPV6_ACTIVE"
    OWNER_WRITE_FIREWALL_TAG="$OWNER_STATE_FIREWALL_TAG"
    OWNER_WRITE_OUT_CHAIN="$OWNER_STATE_OUT_CHAIN"
    OWNER_WRITE_IN_CHAIN="$OWNER_STATE_IN_CHAIN"
    OWNER_WRITE_QNUM="$OWNER_STATE_QNUM"
    OWNER_WRITE_PORTS_TCP="$PORTS_TCP"
    OWNER_WRITE_PORTS_UDP="$PORTS_UDP"
    OWNER_WRITE_STUN_PORTS=0
    OWNER_WRITE_TCP_PKT_OUT="$TCP_PKT_OUT"
    OWNER_WRITE_TCP_PKT_IN="$TCP_PKT_IN"
    OWNER_WRITE_UDP_PKT_OUT="$UDP_PKT_OUT"
    OWNER_WRITE_UDP_PKT_IN="$UDP_PKT_IN"
    OWNER_WRITE_DESYNC_MARK="$DESYNC_MARK"
    OWNER_WRITE_IPV4_ACTIVE=1
    OWNER_WRITE_IPV6_ACTIVE="$IPV6_ACTIVE"
    OWNER_WRITE_IPV4_CONNBYTES="$IPV4_CONNBYTES"
    OWNER_WRITE_IPV4_MULTIPORT="$IPV4_MULTIPORT"
    OWNER_WRITE_IPV4_MARK="$IPV4_MARK"
    OWNER_WRITE_IPV6_CONNBYTES="$IPV6_CONNBYTES"
    OWNER_WRITE_IPV6_MULTIPORT="$IPV6_MULTIPORT"
    OWNER_WRITE_IPV6_MARK="$IPV6_MARK"
    OWNER_WRITE_IPV4_RULES="$IPV4_RULES"
    OWNER_WRITE_IPV6_RULES="$IPV6_RULES"
    OWNER_WRITE_INSTALL_GENERATION="$INSTALL_META_GENERATION"
    OWNER_WRITE_INSTALL_ARCHIVE_SHA256="$INSTALL_META_ARCHIVE_SHA256"
    OWNER_WRITE_SOURCE_GENERATION=
    OWNER_WRITE_READY=1
}

topology_replace_prepare() {
    local multiport_fits=0
    [ "${Z2_DAEMON_REPLACE_TOPOLOGY_CHANGED:-0}" = 1 ] || return 1
    [ -n "${Z2_DAEMON_REPLACE_ROLLBACK_ARTIFACT:-}" ] &&
        state_file_is_secure "$Z2_DAEMON_REPLACE_ROLLBACK_ARTIFACT" &&
        path_mode_is_0600 "$Z2_DAEMON_REPLACE_ROLLBACK_ARTIFACT" || return 1
    z2_load_firewall_reconciler || return 1
    [ "$OWNER_STATE_OUT_CHAIN" = "$Z2_FW_OUT_CHAIN" ] &&
        [ "$OWNER_STATE_IN_CHAIN" = "$Z2_FW_IN_CHAIN" ] || return 1
    owner_family_generation_healthy iptables ipv4 || return 1
    if command -v ip6tables >/dev/null 2>&1; then
        owner_family_generation_healthy ip6tables ipv6 || return 1
    else
        [ "$OWNER_STATE_IPV6_ACTIVE" = 0 ] || return 1
    fi
    topology_snapshot_old_generation

    z2_fw_multiport_fits && multiport_fits=1
    IPV4_CONNBYTES="$OWNER_STATE_IPV4_CONNBYTES"
    IPV4_MULTIPORT="$OWNER_STATE_IPV4_MULTIPORT"
    [ "$multiport_fits" = 1 ] || IPV4_MULTIPORT=0
    IPV4_MARK="$OWNER_STATE_IPV4_MARK"
    IPV6_ACTIVE="$OWNER_STATE_IPV6_ACTIVE"
    IPV6_BUILT="$IPV6_ACTIVE"
    IPV6_CONNBYTES="$OWNER_STATE_IPV6_CONNBYTES"
    IPV6_MULTIPORT="$OWNER_STATE_IPV6_MULTIPORT"
    [ "$multiport_fits" = 1 ] || IPV6_MULTIPORT=0
    IPV6_MARK="$OWNER_STATE_IPV6_MARK"
    FIREWALL_TAG="$OWNER_STATE_FIREWALL_TAG"
    ZAPRET2_OUT="$OWNER_STATE_OUT_CHAIN"
    ZAPRET2_IN="$OWNER_STATE_IN_CHAIN"
    prepare_new_firewall_identity || return 1
    prepare_owner_generation_spec 1 "$IPV6_ACTIVE" || return 1
    topology_snapshot_new_generation
    return 0
}

topology_reconfigure_loaded_generation() {
    Z2_TOPOLOGY_FIREWALL_STAGE=START_FIREWALL_IPV4
    z2_fw_reconfigure_family iptables "$IPV4_CONNBYTES" "$IPV4_MULTIPORT" ||
        return 1
    if [ "$IPV6_ACTIVE" = 1 ]; then
        Z2_TOPOLOGY_FIREWALL_STAGE=START_FIREWALL_IPV6
        z2_fw_reconfigure_family ip6tables "$IPV6_CONNBYTES" "$IPV6_MULTIPORT" ||
            return 1
    fi
    return 0
}

topology_restore_old_firewall() {
    topology_load_generation old || return 1
    topology_reconfigure_loaded_generation
}

topology_stop_partial_candidate() {
    local rc=0
    if [ "$Z2_DAEMON_REPLACE_NEW_PID" = 1 ]; then
        PROCESS_CLEANUP_PREFLIGHT_PROVEN=0
        preflight_owned_process_cleanup && stop_pidfile_process || rc=1
    elif [ -n "$Z2_DAEMON_REPLACE_LAUNCHED_PID" ]; then
        stop_all_exact_owned_nfqws >/dev/null 2>&1 || rc=1
        rm -f "$PIDFILE" "$OWNER_STATE" 2>/dev/null || rc=1
        retire_owner_read_cache
    fi
    Z2_DAEMON_REPLACE_NEW_PID=0
    Z2_DAEMON_REPLACE_LAUNCHED_PID=
    return "$rc"
}

topology_relaunch_old_generation() {
    local candidate_artifact="$COMPILED_ARGV_FILE"
    topology_load_generation old || return 1
    COMPILED_ARGV_FILE="$Z2_DAEMON_REPLACE_ROLLBACK_ARTIFACT"
    Z2_DAEMON_REPLACE_PREVALIDATED=1
    daemon_replace_launch
    local rc=$?
    COMPILED_ARGV_FILE="$candidate_artifact"
    [ "$rc" -eq 0 ] || return 1
    [ "$PUBLISHED_PID" = "$STARTED_PID" ] &&
        [ "$PUBLISHED_START" = "$STARTED_PID_START" ] &&
        [ "$PUBLISHED_FIREWALL_FINGERPRINT" = "$Z2_TOPOLOGY_OLD_FIREWALL_FINGERPRINT" ]
}

topology_rollback_live_generation() {
    local rc=0
    topology_stop_partial_candidate || rc=1
    topology_restore_old_firewall || rc=1
    [ "$rc" -ne 0 ] || topology_relaunch_old_generation || rc=1
    if [ "$rc" -eq 0 ]; then
        Z2_DAEMON_REPLACE_STATUS_DIAGNOSTICS="topology replacement failed; previous daemon and firewall generation restored"
        daemon_replace_write_ok_status >/dev/null 2>&1 || :
        Z2_DAEMON_REPLACE_LAUNCHED_PID=
        log_msg "Topology replacement rolled back; previous daemon and firewall restored"
        return 0
    fi
    daemon_replace_converge_stopped >/dev/null 2>&1 || :
    daemon_replace_write_error_status >/dev/null 2>&1 || :
    return 1
}

replace_topology_in_locked_transaction() {
    topology_replace_prepare || {
        daemon_replace_set_error FIREWALL FIREWALL_CLEANUP_FAILED START_CLEANUP \
            "the authenticated firewall generation is not eligible for in-transaction reconfiguration"
        return 1
    }

    Z2_DAEMON_REPLACE_CONTROLLED=1
    stop_pidfile_process || {
        daemon_replace_set_error PROCESS PROCESS_STOP_FAILED START_CLEANUP \
            "the authenticated previous daemon could not be stopped"
        return 1
    }

    topology_load_generation new || {
        daemon_replace_set_error FIREWALL PREFLIGHT_FAILED START_IDENTITY \
            "the candidate firewall generation could not be loaded"
        topology_rollback_live_generation || :
        return 1
    }
    if ! topology_reconfigure_loaded_generation; then
        daemon_replace_set_error FIREWALL FIREWALL_PUBLICATION_FAILED \
            "$Z2_TOPOLOGY_FIREWALL_STAGE" \
            "atomic firewall reconfiguration failed: ${Z2_FW_ERROR_DETAIL:-unknown backend failure}"
        topology_rollback_live_generation ||
            Z2_DAEMON_REPLACE_ERROR_DETAIL="$Z2_DAEMON_REPLACE_ERROR_DETAIL; previous generation rollback is incomplete"
        return 1
    fi

    topology_load_generation new || return 1
    if ! daemon_replace_launch; then
        daemon_replace_set_error PROCESS PROCESS_LAUNCH_FAILED START_LAUNCH \
            "nfqws2 launch failed after firewall reconfiguration"
        topology_rollback_live_generation ||
            Z2_DAEMON_REPLACE_ERROR_DETAIL="$Z2_DAEMON_REPLACE_ERROR_DETAIL; previous generation rollback is incomplete"
        return 1
    fi
    [ "$PUBLISHED_PID" = "$STARTED_PID" ] &&
        [ "$PUBLISHED_START" = "$STARTED_PID_START" ] &&
        [ "$PUBLISHED_FIREWALL_FINGERPRINT" = "$Z2_TOPOLOGY_NEW_FIREWALL_FINGERPRINT" ] ||
        {
            daemon_replace_set_error LIFECYCLE POSTCONDITION_FAILED START_COMMIT \
                "the topology replacement owner receipt is inconsistent"
            topology_rollback_live_generation ||
                Z2_DAEMON_REPLACE_ERROR_DETAIL="$Z2_DAEMON_REPLACE_ERROR_DETAIL; previous generation rollback is incomplete"
            return 1
        }
    Z2_DAEMON_REPLACE_STATUS_DIAGNOSTICS="validated daemon and capture-topology replacement; stable private chain anchors retained"
    daemon_replace_write_ok_status ||
        log_msg "WARNING: topology replacement committed but its status snapshot could not be refreshed"
    Z2_DAEMON_REPLACE_LAUNCHED_PID=
    log_msg "Daemon and firewall topology replaced with verified PID $STARTED_PID; anchors retained"
    return 0
}
