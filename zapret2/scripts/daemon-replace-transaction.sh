#!/system/bin/sh
# Daemon-only replacement inside an already locked, validated preset mutation.
#
# The preset transaction has already authenticated the package generation,
# compiled the exact candidate, run nfqws2 --dry-run, and published a
# generation-bound validation receipt.  Re-entering zapret-start.sh used to
# repeat those facts in a second large shell process.  This layer consumes the
# proofs in the same process and changes only the process publication; the
# authenticated firewall generation is retained byte-for-byte.

Z2_DAEMON_REPLACE_ERROR_DOMAIN=
Z2_DAEMON_REPLACE_ERROR_CODE=
Z2_DAEMON_REPLACE_ERROR_STAGE=
Z2_DAEMON_REPLACE_ERROR_DETAIL=
Z2_DAEMON_REPLACE_CONTROLLED=0
Z2_DAEMON_REPLACE_NEW_PID=0
Z2_DAEMON_REPLACE_LAUNCHED_PID=
Z2_DAEMON_REPLACE_LAUNCHED_START=
Z2_DAEMON_REPLACE_LAUNCHED_ARGV_SHA256=
Z2_DAEMON_REPLACE_TOPOLOGY_CHANGED=0
Z2_DAEMON_REPLACE_STATUS_DIAGNOSTICS=

daemon_replace_set_error() {
    Z2_DAEMON_REPLACE_ERROR_DOMAIN="$1"
    Z2_DAEMON_REPLACE_ERROR_CODE="$2"
    Z2_DAEMON_REPLACE_ERROR_STAGE="$3"
    Z2_DAEMON_REPLACE_ERROR_DETAIL="$4"
    return 1
}

daemon_replace_binding_current() {
    compiled_artifact_binding_current \
        "$COMPILED_ARGV_FILE" "$PRESETS_DIR/$ACTIVE_PRESET" "$ACTIVE_PRESET"
}

daemon_replace_load_compiled_spec() {
    [ "${COMPILED_METADATA_FOR:-}" = "$COMPILED_ARGV_FILE" ] ||
        read_compiled_artifact_metadata "$COMPILED_ARGV_FILE" || return 1
    [ "$COMPILED_PRESET" = "$ACTIVE_PRESET" ] || return 1
    PORTS_TCP="$COMPILED_TCP_PORTS"
    PORTS_UDP="$COMPILED_UDP_PORTS"
    TCP_PKT_OUT="$COMPILED_TCP_PKT_OUT"
    TCP_PKT_IN="$COMPILED_TCP_PKT_IN"
    UDP_PKT_OUT="$COMPILED_UDP_PKT_OUT"
    UDP_PKT_IN="$COMPILED_UDP_PKT_IN"
    [ -n "$PORTS_TCP$PORTS_UDP" ]
}

# One exact process preflight also loads the current owner receipt.  Its
# firewall fingerprint is then recomputed from the already-validated candidate
# while carrying forward only capabilities the retained generation actually
# published.  A changed port/capture topology cannot enter this path.
daemon_replace_prepare() {
    local previous_fingerprint
    case "${LOCK_HELD:-0}" in 1|inherited) ;; *) return 1 ;; esac
    read_install_generation_meta || return 1
    if [ "${Z2_DAEMON_REPLACE_PREVALIDATED:-0}" = 1 ]; then
        [ "${COMPILED_METADATA_FOR:-}" = "$COMPILED_ARGV_FILE" ] &&
            [ "$COMPILED_PRESET" = "$ACTIVE_PRESET" ] &&
            [ "$COMPILED_INSTALL_GENERATION" = "$INSTALL_META_GENERATION" ] &&
            [ "$COMPILED_INSTALL_ARCHIVE_SHA256" = "$INSTALL_META_ARCHIVE_SHA256" ] ||
            return 1
    else
        daemon_replace_binding_current || return 1
        compiled_validation_receipt_current "$COMPILED_ARGV_FILE" || return 1
    fi
    daemon_replace_load_compiled_spec || return 1
    preflight_owned_process_cleanup || return 1
    [ "$PROCESS_PREFLIGHT_LIVE" = 1 ] &&
        [ "$PROCESS_PREFLIGHT_PHASE" = active ] || return 1
    read_owner_state && owner_state_is_current_boot || return 1
    [ "$OWNER_STATE_PID" = "$PROCESS_PREFLIGHT_PID" ] &&
        [ "$OWNER_STATE_START" = "$PROCESS_PREFLIGHT_START" ] &&
        [ "$OWNER_STATE_ARGV_SHA256" = "$PROCESS_PREFLIGHT_ARGV_SHA256" ] &&
        [ "$OWNER_STATE_QNUM" = "$QNUM" ] &&
        [ "$OWNER_STATE_INSTALL_GENERATION" = "$INSTALL_META_GENERATION" ] &&
        [ "$OWNER_STATE_INSTALL_ARCHIVE_SHA256" = "$INSTALL_META_ARCHIVE_SHA256" ] ||
        return 1

    previous_fingerprint="$OWNER_STATE_FIREWALL_FINGERPRINT"
    canonical_mark "$DESYNC_MARK" || return 1
    if [ "$PORTS_TCP" != "$OWNER_STATE_PORTS_TCP" ] ||
       [ "$PORTS_UDP" != "$OWNER_STATE_PORTS_UDP" ] ||
       [ "$TCP_PKT_OUT" != "$OWNER_STATE_TCP_PKT_OUT" ] ||
       [ "$TCP_PKT_IN" != "$OWNER_STATE_TCP_PKT_IN" ] ||
       [ "$UDP_PKT_OUT" != "$OWNER_STATE_UDP_PKT_OUT" ] ||
       [ "$UDP_PKT_IN" != "$OWNER_STATE_UDP_PKT_IN" ] ||
       [ "${TETHERING:-0}" != "$OWNER_STATE_TETHERING" ] ||
       [ "$MARK_CANONICAL" != "$OWNER_STATE_DESYNC_MARK" ]; then
        Z2_DAEMON_REPLACE_TOPOLOGY_CHANGED=1
        return 2
    fi
    IPV4_CONNBYTES="$OWNER_STATE_IPV4_CONNBYTES"
    IPV4_MULTIPORT="$OWNER_STATE_IPV4_MULTIPORT"
    IPV4_MARK="$OWNER_STATE_IPV4_MARK"
    IPV6_ACTIVE="$OWNER_STATE_IPV6_ACTIVE"
    IPV6_BUILT="$OWNER_STATE_IPV6_ACTIVE"
    IPV6_CONNBYTES="$OWNER_STATE_IPV6_CONNBYTES"
    IPV6_MULTIPORT="$OWNER_STATE_IPV6_MULTIPORT"
    IPV6_MARK="$OWNER_STATE_IPV6_MARK"
    IPV4_ACTIVE=1
    IPV4_BUILT=1
    # The owner record already contains the complete canonical firewall spec.
    # Exact comparison of every candidate-controlled topology field above is
    # stronger and cheaper than rebuilding and hashing the same spec.
    OWNER_WRITE_FIREWALL_TAG="$OWNER_STATE_FIREWALL_TAG"
    OWNER_WRITE_OUT_CHAIN="$OWNER_STATE_OUT_CHAIN"
    OWNER_WRITE_IN_CHAIN="$OWNER_STATE_IN_CHAIN"
    OWNER_WRITE_TETHERING="$OWNER_STATE_TETHERING"
    OWNER_WRITE_QNUM="$OWNER_STATE_QNUM"
    OWNER_WRITE_PORTS_TCP="$OWNER_STATE_PORTS_TCP"
    OWNER_WRITE_PORTS_UDP="$OWNER_STATE_PORTS_UDP"
    OWNER_WRITE_STUN_PORTS="$OWNER_STATE_STUN_PORTS"
    OWNER_WRITE_TCP_PKT_OUT="$OWNER_STATE_TCP_PKT_OUT"
    OWNER_WRITE_TCP_PKT_IN="$OWNER_STATE_TCP_PKT_IN"
    OWNER_WRITE_UDP_PKT_OUT="$OWNER_STATE_UDP_PKT_OUT"
    OWNER_WRITE_UDP_PKT_IN="$OWNER_STATE_UDP_PKT_IN"
    OWNER_WRITE_DESYNC_MARK="$OWNER_STATE_DESYNC_MARK"
    OWNER_WRITE_IPV4_ACTIVE="$OWNER_STATE_IPV4_ACTIVE"
    OWNER_WRITE_IPV6_ACTIVE="$OWNER_STATE_IPV6_ACTIVE"
    OWNER_WRITE_IPV4_CONNBYTES="$OWNER_STATE_IPV4_CONNBYTES"
    OWNER_WRITE_IPV4_MULTIPORT="$OWNER_STATE_IPV4_MULTIPORT"
    OWNER_WRITE_IPV4_MARK="$OWNER_STATE_IPV4_MARK"
    OWNER_WRITE_IPV6_CONNBYTES="$OWNER_STATE_IPV6_CONNBYTES"
    OWNER_WRITE_IPV6_MULTIPORT="$OWNER_STATE_IPV6_MULTIPORT"
    OWNER_WRITE_IPV6_MARK="$OWNER_STATE_IPV6_MARK"
    OWNER_WRITE_IPV4_RULES="$OWNER_STATE_IPV4_RULES"
    OWNER_WRITE_IPV6_RULES="$OWNER_STATE_IPV6_RULES"
    OWNER_WRITE_IPV4_SPEC="$OWNER_STATE_IPV4_SPEC"
    OWNER_WRITE_IPV6_SPEC="$OWNER_STATE_IPV6_SPEC"
    OWNER_WRITE_FIREWALL_FINGERPRINT="$previous_fingerprint"
    OWNER_WRITE_INSTALL_GENERATION="$INSTALL_META_GENERATION"
    OWNER_WRITE_INSTALL_ARCHIVE_SHA256="$INSTALL_META_ARCHIVE_SHA256"
    OWNER_WRITE_SOURCE_GENERATION=""
    OWNER_WRITE_READY=1
    IPV4_RULES="$OWNER_WRITE_IPV4_RULES"
    IPV6_RULES="$OWNER_WRITE_IPV6_RULES"
    Z2_DAEMON_REPLACE_FIREWALL_FINGERPRINT="$previous_fingerprint"

    # If launch later fails, the retained generation is no longer useful
    # without a listener.  Preserve the authenticated ownership answer now so
    # the exceptional cleanup can remove it without inventing IPv6 state.
    OWNER_STATE_AVAILABLE_FOR_ROLLBACK=1
    resolve_ipv6_ownership_expectation 1
    return 0
}

daemon_replace_launch() {
    local candidate n=0 start
    Z2_DAEMON_REPLACE_LAUNCHED_PID=
    Z2_DAEMON_REPLACE_LAUNCHED_START=
    Z2_DAEMON_REPLACE_LAUNCHED_ARGV_SHA256=
    [ "${Z2_DAEMON_REPLACE_PREVALIDATED:-0}" = 1 ] ||
        daemon_replace_binding_current || return 1
    [ ! -e "$PIDFILE" ] && [ ! -L "$PIDFILE" ] || return 1
    run_compiled_artifact "$COMPILED_ARGV_FILE" daemon || return 1
    Z2_DAEMON_REPLACE_LAUNCHED_PID="$LAUNCHED_PID"
    while [ "$n" -lt 100 ]; do
        candidate=
        if read_live_pidfile; then candidate="$LIVE_PIDFILE_PID"; fi
        if [ -n "$candidate" ] && proc_starttime_read "$candidate"; then
            start="$PROC_STARTTIME"
            if publish_nfqws_owner "$candidate" "$start" "$QNUM" active; then
                Z2_DAEMON_REPLACE_NEW_PID=1
                STARTED_PID="$candidate"
                STARTED_PID_START="$VERIFIED_STARTTIME"
                return 0
            fi
        fi
        n=$((n + 1))
        sleep 0.1
    done
    return 1
}

daemon_replace_write_ok_status() {
    local total=$((IPV4_RULES + IPV6_RULES))
    STATUS_RULES_OK="$total"; STATUS_RULES_FAIL=0; STATUS_RULES_TOTAL="$total"
    STATUS_ERRORS=""; STATUS_OWN_PID="$STARTED_PID"; STATUS_PID_VERIFIED=1
    STATUS_QNUM="$QNUM"; STATUS_OWN_PID_STARTTIME="$STARTED_PID_START"
    STATUS_OWN_ARGV_SHA256="$PUBLISHED_ARGV_SHA256"
    STATUS_OWNER_GENERATION="$PUBLISHED_GENERATION"
    STATUS_OWNER_METADATA_VERIFIED=1; STATUS_RULESET_VERIFIED=1
    STATUS_RULES_EXPECTED="$total"; STATUS_IPV4_ACTIVE=1
    STATUS_IPV6_ACTIVE="$IPV6_ACTIVE"
    STATUS_IPV4_RULES="$IPV4_RULES"; STATUS_IPV6_RULES="$IPV6_RULES"
    STATUS_CHAINS=$((1 + IPV4_CONNBYTES + IPV6_ACTIVE * (1 + IPV6_CONNBYTES)))
    # The published generation keeps its own capture topology across a
    # daemon-only replacement, so its anchors are counted from that record.
    STATUS_ANCHORS=$((STATUS_CHAINS * (1 + OWNER_WRITE_TETHERING)))
    STATUS_NFQUEUE_SUPPORTED=1; STATUS_QUEUE_BYPASS_SUPPORTED=1
    STATUS_CONNBYTES_SUPPORTED="$IPV4_CONNBYTES"
    STATUS_MULTIPORT_SUPPORTED="$IPV4_MULTIPORT"
    STATUS_MARK_SUPPORTED="$IPV4_MARK"
    STATUS_FALLBACK_MODE=0
    if [ "$IPV4_CONNBYTES" != 1 ] ||
       { [ "$IPV6_ACTIVE" = 1 ] && [ "$IPV6_CONNBYTES" != 1 ]; }; then
        STATUS_FALLBACK_MODE=1
    fi
    STATUS_ERROR_STATUS=OK; STATUS_ERROR_DOMAIN=NONE; STATUS_ERROR_CODE=NONE
    STATUS_ERROR_STAGE=NONE; STATUS_ERROR_DETAIL=
    STATUS_DIAGNOSTICS="${Z2_DAEMON_REPLACE_STATUS_DIAGNOSTICS:-validated daemon-only replacement; authenticated firewall generation retained}"
    write_iptables_status ok
}

daemon_replace_write_error_status() {
    restore_status_facts
    STATUS_RULES_OK=0; STATUS_RULES_FAIL=1; STATUS_RULES_TOTAL=0
    STATUS_ERRORS="$Z2_DAEMON_REPLACE_ERROR_DETAIL"
    STATUS_OWN_PID=; STATUS_OWN_PID_STARTTIME=; STATUS_OWN_ARGV_SHA256=
    STATUS_OWNER_GENERATION=; STATUS_PID_VERIFIED=0
    STATUS_OWNER_METADATA_VERIFIED=0; STATUS_RULESET_VERIFIED=0
    STATUS_RULES_EXPECTED=0; STATUS_IPV4_ACTIVE=0; STATUS_IPV6_ACTIVE=0
    STATUS_IPV4_RULES=0; STATUS_IPV6_RULES=0; STATUS_CHAINS=0; STATUS_ANCHORS=0
    STATUS_ERROR_STATUS=ERROR
    STATUS_ERROR_DOMAIN="$Z2_DAEMON_REPLACE_ERROR_DOMAIN"
    STATUS_ERROR_CODE="$Z2_DAEMON_REPLACE_ERROR_CODE"
    STATUS_ERROR_STAGE="$Z2_DAEMON_REPLACE_ERROR_STAGE"
    STATUS_ERROR_DETAIL="$(z2_error_detail_normalize "$Z2_DAEMON_REPLACE_ERROR_DETAIL")"
    STATUS_DIAGNOSTICS="$Z2_DAEMON_REPLACE_ERROR_DETAIL"
    write_iptables_status error
}

# Failure-only convergence may load the heavy firewall layer: successful
# strategy/profile edits never do.  Stable chain ownership is audited before
# removal, so an unexpected foreign reference still fails closed.
daemon_replace_converge_stopped() {
    local rc=0
    if [ "$Z2_DAEMON_REPLACE_NEW_PID" = 1 ]; then
        PROCESS_CLEANUP_PREFLIGHT_PROVEN=0
        preflight_owned_process_cleanup &&
            stop_pidfile_process || rc=1
    elif [ -n "$Z2_DAEMON_REPLACE_LAUNCHED_PID" ]; then
        stop_all_exact_owned_nfqws >/dev/null 2>&1 || rc=1
        rm -f "$PIDFILE" "$OWNER_STATE" 2>/dev/null || rc=1
        retire_owner_read_cache
    fi
    if ! z2_load_firewall_reconciler ||
       ! audit_owned_firewall_for_cleanup ||
       ! cleanup_owned_firewall audited; then
        rc=1
    fi
    [ "$rc" -ne 0 ] || {
        rm -f "$PIDFILE" "$OWNER_STATE" 2>/dev/null || rc=1
        retire_owner_read_cache
    }
    return "$rc"
}

replace_daemon_in_locked_transaction() {
    Z2_DAEMON_REPLACE_ERROR_DOMAIN=
    Z2_DAEMON_REPLACE_ERROR_CODE=
    Z2_DAEMON_REPLACE_ERROR_STAGE=
    Z2_DAEMON_REPLACE_ERROR_DETAIL=
    Z2_DAEMON_REPLACE_CONTROLLED=0
    Z2_DAEMON_REPLACE_NEW_PID=0
    Z2_DAEMON_REPLACE_TOPOLOGY_CHANGED=0
    Z2_DAEMON_REPLACE_STATUS_DIAGNOSTICS=

    daemon_replace_prepare
    case $? in
        0) ;;
        2)
            # A changed capture topology is a typed routing result, not a
            # failure: the lock-owning caller loads the topology replacement
            # layer and re-enters with the same proofs.
            return 2
            ;;
        *)
            daemon_replace_set_error PROCESS PROCESS_STOP_FAILED START_CLEANUP \
                "the running daemon or retained firewall receipt is not eligible for in-transaction replacement" || :
            return 1
            ;;
    esac

    Z2_DAEMON_REPLACE_CONTROLLED=1
    stop_pidfile_process || {
        daemon_replace_set_error PROCESS PROCESS_STOP_FAILED START_CLEANUP \
            "the authenticated previous daemon could not be stopped"
        # The pre-transaction receipt remains the most accurate observation:
        # the exact old process may still be live and the caller restores the
        # old preset generation before returning.
        return 1
    }

    if ! daemon_replace_launch; then
        daemon_replace_set_error PROCESS PROCESS_LAUNCH_FAILED START_LAUNCH \
            "nfqws2 launch failed after the previous daemon stopped"
        daemon_replace_converge_stopped ||
            Z2_DAEMON_REPLACE_ERROR_DETAIL="$Z2_DAEMON_REPLACE_ERROR_DETAIL; stopped-state rollback is incomplete"
        daemon_replace_write_error_status >/dev/null 2>&1 || :
        return 1
    fi

    [ "$PUBLISHED_PID" = "$STARTED_PID" ] &&
        [ "$PUBLISHED_START" = "$STARTED_PID_START" ] &&
        [ "$PUBLISHED_FIREWALL_FINGERPRINT" = "$Z2_DAEMON_REPLACE_FIREWALL_FINGERPRINT" ] &&
        [ "$PUBLISHED_INSTALL_GENERATION" = "$INSTALL_META_GENERATION" ] &&
        [ "$PUBLISHED_INSTALL_ARCHIVE_SHA256" = "$INSTALL_META_ARCHIVE_SHA256" ] || {
        daemon_replace_set_error LIFECYCLE POSTCONDITION_FAILED START_COMMIT \
            "the replacement owner receipt is inconsistent"
        daemon_replace_converge_stopped ||
            Z2_DAEMON_REPLACE_ERROR_DETAIL="$Z2_DAEMON_REPLACE_ERROR_DETAIL; stopped-state rollback is incomplete"
        daemon_replace_write_error_status >/dev/null 2>&1 || :
        return 1
    }
    daemon_replace_write_ok_status || {
        # The process and owner publication are already durable.  A diagnostic
        # receipt failure must not undo the completed effect or make the caller
        # restore configuration the running daemon no longer uses.
        log_msg "WARNING: daemon replacement committed but its status snapshot could not be refreshed"
    }
    Z2_DAEMON_REPLACE_LAUNCHED_PID=
    log_msg "Daemon replaced with verified PID $STARTED_PID; firewall retained"
    return 0
}
