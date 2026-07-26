#!/system/bin/sh
# Idempotent boot-local firewall reconciler.
#
# The stable ZAPRET2_OUT/ZAPRET2_IN namespace is exclusively owned by this
# module. A complete ruleset is derived from the compiled preset on every
# start. There is deliberately no firewall WAL: iptables-restore validates the
# complete candidate and publishes it at COMMIT. Any interruption is recovered
# by repeating z2_fw_cleanup_family under the lifecycle lock.

# common.sh defines the fork-free line emitter and sources this file before
# that definition runs; the fallback only keeps the reconciler sourceable on
# its own, which the reconciler tests do.
command -v z2_emit_line >/dev/null 2>&1 || z2_emit_line() { printf '%s\n' "$1"; }

Z2_FW_OUT_CHAIN="${Z2_FW_OUT_CHAIN:-ZAPRET2_OUT}"
Z2_FW_IN_CHAIN="${Z2_FW_IN_CHAIN:-ZAPRET2_IN}"
Z2_FW_BACKEND=""
Z2_FW_CONNBYTES=0
Z2_FW_MULTIPORT=1
Z2_FW_RULES=0
Z2_FW_CHAINS=0
Z2_FW_ANCHORS=0
Z2_FW_FAILURE_CLASS=""
Z2_FW_ERROR_DETAIL=""
Z2_FW_FALLBACK_DETAIL=""
Z2_FW_LAST_RESTORE_EXIT=0
Z2_FW_LAST_RESTORE_DETAIL=""
Z2_FW_LAST_FAILURE_CLASS=""
Z2_FW_RESTORE_WAIT_IPTABLES=unknown
Z2_FW_RESTORE_WAIT_IP6TABLES=unknown
Z2_FW_BASELINE_READY=0
Z2_FW_BASELINE_OUT_CHAIN=0
Z2_FW_BASELINE_IN_CHAIN=0
Z2_FW_BASELINE_OUT_ANCHORS=0
Z2_FW_BASELINE_IN_ANCHORS=0
Z2_FW_AUDIT_IPTABLES=""
Z2_FW_AUDIT_IP6TABLES=""
Z2_FW_VERIFY_DETAIL=""

# iptables-restore gained native xtables-lock waiting later than the oldest
# Android release supported by the module. Prefer the backend's own lock wait
# when advertised. Older/vendor backends receive the same bounded wait only
# after they explicitly report the xtables lock as busy.
Z2_FW_LOCK_WAIT_SECONDS=5
Z2_FW_DIAGNOSTIC_MAX_BYTES=384

z2_fw_restore_command_read() {
    Z2_FW_RESTORE_COMMAND=""
    case "$1" in
        iptables) Z2_FW_RESTORE_COMMAND=iptables-restore ;;
        ip6tables) Z2_FW_RESTORE_COMMAND=ip6tables-restore ;;
        *) return 1 ;;
    esac
}

z2_fw_restore_available() {
    z2_fw_restore_command_read "$1" || return 1
    command -v "$Z2_FW_RESTORE_COMMAND" >/dev/null 2>&1
}

z2_fw_restore_supports_wait() {
    local restore="$1" cached
    case "$restore" in
        iptables-restore) cached="$Z2_FW_RESTORE_WAIT_IPTABLES" ;;
        ip6tables-restore) cached="$Z2_FW_RESTORE_WAIT_IP6TABLES" ;;
        *) return 1 ;;
    esac
    if [ "$cached" = unknown ]; then
        if "$restore" --help 2>&1 | grep -Fq -- '--wait'; then
            cached=1
        else
            cached=0
        fi
        case "$restore" in
            iptables-restore) Z2_FW_RESTORE_WAIT_IPTABLES="$cached" ;;
            ip6tables-restore) Z2_FW_RESTORE_WAIT_IP6TABLES="$cached" ;;
        esac
    fi
    [ "$cached" = 1 ]
}

z2_fw_reset_restore_wait_capabilities() {
    Z2_FW_RESTORE_WAIT_IPTABLES=unknown
    Z2_FW_RESTORE_WAIT_IP6TABLES=unknown
}

z2_fw_normalize_diagnostic() {
    local LC_ALL=C
    printf '%s' "$1" | tr '[:cntrl:]' ' ' | cut -b "1-$Z2_FW_DIAGNOSTIC_MAX_BYTES"
}

z2_fw_read_restore_diagnostic() {
    local path="$1" detail
    detail="$(tail -c "$Z2_FW_DIAGNOSTIC_MAX_BYTES" "$path" 2>/dev/null)" || detail=""
    z2_fw_normalize_diagnostic "$detail"
}

z2_fw_diagnostic_is_lock_busy() {
    case "$1" in
        *xtables*lock*|*XTABLES*lock*|*Another\ app*holding*lock*|\
        *another\ app*holding*lock*|*lock*temporarily\ unavailable*|\
        *lock*busy*) return 0 ;;
        *) return 1 ;;
    esac
}

z2_fw_lock_retry_pause() {
    sleep 1
}

z2_fw_diagnostic_is_connbytes_unsupported() {
    case "$1" in
        *[Cc]onnbytes*) return 0 ;;
        *) return 1 ;;
    esac
}

# Two independent signals are required here, unlike connbytes. A kernel without
# xt_multiport makes iptables report the missing extension and then reject the
# port argument it can no longer parse, so the port complaint arrives together
# with the extension name. That complaint on its own is also exactly what a
# genuinely malformed port list produces, and silently rebuilding the intended
# topology because of it would hide a broken configuration instead of a missing
# kernel module.
z2_fw_diagnostic_is_multiport_unsupported() {
    case "$1" in
        *[Mm]ultiport*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *not\ supported*|*missing\ kernel\ module*|*no\ kernel\ module*|\
        *load\ match*|*[Uu]nknown\ option*|*invalid\ port/service*) return 0 ;;
        *) return 1 ;;
    esac
}

# The backend answers a missing extension with several lines of warnings and a
# parser complaint about whatever it could no longer read. Handed to the user
# unchanged that reads as a broken configuration. Every match and target the
# module authors is named here, so the one the kernel refused can be said
# plainly ahead of the backend's own words — including the three that have no
# fallback, where naming the extension is the only help there is.
z2_fw_missing_extension() {
    local detail="$1" name
    case "$detail" in
        *not\ supported*|*missing\ kernel\ module*|*no\ kernel\ module*|\
        *[Nn]o\ chain/target/match*|*[Uu]nknown\ option*|*[Cc]ouldn\'t\ load*) ;;
        *) return 1 ;;
    esac
    for name in multiport connbytes mark NFQUEUE; do
        case "$detail" in
            *"$name"*) printf '%s\n' "$name"; return 0 ;;
        esac
    done
    return 1
}

z2_fw_ensure_scratch_dir() {
    # common.sh owns the authenticated implementation; the standalone fallback
    # exists only for tests that source this reconciler on its own.
    if command -v ensure_state_tmp_dir >/dev/null 2>&1; then
        ensure_state_tmp_dir
        return
    fi
    umask 077
    if [ ! -e "$STATE_DIR/tmp" ] && [ ! -L "$STATE_DIR/tmp" ]; then
        mkdir "$STATE_DIR/tmp" 2>/dev/null
    fi
    [ -d "$STATE_DIR/tmp" ] && [ ! -L "$STATE_DIR/tmp" ] || return 1
    chmod 0700 "$STATE_DIR/tmp" 2>/dev/null || return 1
    [ -d "$STATE_DIR/tmp" ] && [ ! -L "$STATE_DIR/tmp" ] || return 1
}

# Scratch names end in the creating PID, so residue from a previous boot whose
# PID the kernel handed us again would otherwise fence every transaction
# forever — and a liveness sweep cannot help, because the PID in the name is
# ours and therefore alive. Nothing else can hold this name: we own the
# lifecycle lock and have not written it yet in this process, so whatever is
# there was abandoned by a process that no longer exists.
z2_fw_claim_scratch_path() {
    local path="$1"
    { [ -e "$path" ] || [ -L "$path" ]; } || return 0
    rm -rf "$path" 2>/dev/null || return 1
    [ ! -e "$path" ] && [ ! -L "$path" ]
}

z2_fw_run_restore() {
    local restore="$1" tool="$2" phase="$3" batch="$4"
    local capture wait_supported=0 attempts=0 rc=1 cleanup_rc=0 detail
    capture="$STATE_DIR/tmp/firewall-restore.${tool}.$$.error"
    # Reset the result fields before the first failure exit, or a failure here
    # would report the exit code of the previous phase.
    Z2_FW_LAST_RESTORE_EXIT=0
    Z2_FW_LAST_RESTORE_DETAIL=""
    Z2_FW_LAST_FAILURE_CLASS=""
    z2_fw_ensure_scratch_dir || {
        Z2_FW_LAST_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_LAST_RESTORE_DETAIL="unavailable firewall scratch directory"
        return 1
    }
    state_path_is_managed_file "$capture" || {
        Z2_FW_LAST_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_LAST_RESTORE_DETAIL="unsafe firewall diagnostic path"
        return 1
    }
    z2_fw_claim_scratch_path "$capture" || {
        Z2_FW_LAST_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_LAST_RESTORE_DETAIL="firewall diagnostic path already exists"
        return 1
    }
    umask 077
    if ! : > "$capture"; then
        rm -f "$capture" 2>/dev/null
        Z2_FW_LAST_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_LAST_RESTORE_DETAIL="cannot create private firewall diagnostic capture"
        return 1
    fi
    z2_fw_restore_supports_wait "$restore" && wait_supported=1

    while :; do
        : > "$capture" || {
            rc=1
            Z2_FW_LAST_FAILURE_CLASS=STATE_UNAVAILABLE
            Z2_FW_LAST_RESTORE_DETAIL="cannot reset firewall diagnostic capture"
            break
        }
        if [ "$wait_supported" = 1 ]; then
            if [ "$phase" = test ]; then
                "$restore" --wait "$Z2_FW_LOCK_WAIT_SECONDS" --test --noflush \
                    < "$batch" >/dev/null 2>"$capture"
            else
                "$restore" --wait "$Z2_FW_LOCK_WAIT_SECONDS" --noflush \
                    < "$batch" >/dev/null 2>"$capture"
            fi
        elif [ "$phase" = test ]; then
            "$restore" --test --noflush < "$batch" >/dev/null 2>"$capture"
        else
            "$restore" --noflush < "$batch" >/dev/null 2>"$capture"
        fi
        rc=$?
        detail="$(z2_fw_read_restore_diagnostic "$capture")"
        [ "$rc" -ne 0 ] || break
        if [ "$wait_supported" = 0 ] && [ "$rc" -eq 4 ] 2>/dev/null &&
           z2_fw_diagnostic_is_lock_busy "$detail" &&
           [ "$attempts" -lt "$Z2_FW_LOCK_WAIT_SECONDS" ] 2>/dev/null; then
            attempts=$((attempts + 1))
            if ! z2_fw_lock_retry_pause; then
                Z2_FW_LAST_FAILURE_CLASS=STATE_UNAVAILABLE
                Z2_FW_LAST_RESTORE_DETAIL="xtables lock wait could not be scheduled"
                rc=1
                break
            fi
            continue
        fi
        break
    done

    Z2_FW_LAST_RESTORE_EXIT="$rc"
    if [ -z "$Z2_FW_LAST_RESTORE_DETAIL" ]; then
        Z2_FW_LAST_RESTORE_DETAIL="$(z2_fw_read_restore_diagnostic "$capture")"
    fi
    rm -f "$capture" 2>/dev/null || cleanup_rc=1
    if [ "$cleanup_rc" -ne 0 ]; then
        Z2_FW_LAST_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_LAST_RESTORE_DETAIL="cannot remove private firewall diagnostic capture"
        return 1
    fi
    [ "$rc" -eq 0 ] 2>/dev/null && return 0
    if [ -z "$Z2_FW_LAST_FAILURE_CLASS" ]; then
        if z2_fw_diagnostic_is_lock_busy "$Z2_FW_LAST_RESTORE_DETAIL"; then
            Z2_FW_LAST_FAILURE_CLASS=LOCK_TIMEOUT
        elif [ "$phase" = test ]; then
            Z2_FW_LAST_FAILURE_CLASS=RULESET_REJECTED
        else
            Z2_FW_LAST_FAILURE_CLASS=PUBLICATION_FAILED
        fi
    fi
    return "$rc"
}

z2_fw_set_restore_failure() {
    local restore="$1" phase="$2" connbytes="$3" detail missing cause=""
    detail="${Z2_FW_LAST_RESTORE_DETAIL:-no backend diagnostic}"
    Z2_FW_FAILURE_CLASS="${Z2_FW_LAST_FAILURE_CLASS:-PUBLICATION_FAILED}"
    if missing="$(z2_fw_missing_extension "$detail")"; then
        cause="this kernel does not provide the $missing extension; "
    fi
    Z2_FW_ERROR_DETAIL="$restore $phase failed (connbytes=$connbytes, exit=$Z2_FW_LAST_RESTORE_EXIT): $cause$detail"
    Z2_FW_ERROR_DETAIL="$(z2_fw_normalize_diagnostic "$Z2_FW_ERROR_DETAIL")"
}

z2_fw_tool_available() {
    command -v "$1" >/dev/null 2>&1 &&
        "$1" -t mangle -L OUTPUT -n >/dev/null 2>&1
}

z2_fw_capture_baseline() {
    local tool="$1" listing plan
    Z2_FW_BASELINE_READY=0
    Z2_FW_BASELINE_OUT_CHAIN=0
    Z2_FW_BASELINE_IN_CHAIN=0
    Z2_FW_BASELINE_OUT_ANCHORS=0
    Z2_FW_BASELINE_IN_ANCHORS=0
    listing="$("$tool" -t mangle -S 2>/dev/null)" || return 1
    plan="$(printf '%s\n' "$listing" |
        awk -v out="$Z2_FW_OUT_CHAIN" -v inchain="$Z2_FW_IN_CHAIN" '
            $1 == "-N" && $2 == out { out_chain++ }
            $1 == "-N" && $2 == inchain { in_chain++ }
            $1 == "-A" {
                for (i = 3; i <= NF; i++) {
                    if ($i != "-j" && $i != "--jump" &&
                        $i != "-g" && $i != "--goto") continue
                    target = $(i + 1)
                    if (target == out) {
                        if ($0 == "-A OUTPUT -j " out) out_anchor++
                        else bad = 1
                    }
                    if (target == inchain) {
                        if ($0 == "-A INPUT -j " inchain) in_anchor++
                        else bad = 1
                    }
                }
            }
            END {
                if (bad || out_chain > 1 || in_chain > 1 ||
                    out_anchor > 8 || in_anchor > 8 ||
                    (out_anchor && !out_chain) || (in_anchor && !in_chain))
                    exit 1
                printf "%d %d %d %d\n",
                    out_chain, in_chain, out_anchor, in_anchor
            }
        ')" || return 1
    # The awk producer emits exactly four decimal fields.
    # shellcheck disable=SC2086
    set -- $plan
    [ "$#" = 4 ] || return 1
    Z2_FW_BASELINE_OUT_CHAIN="$1"
    Z2_FW_BASELINE_IN_CHAIN="$2"
    Z2_FW_BASELINE_OUT_ANCHORS="$3"
    Z2_FW_BASELINE_IN_ANCHORS="$4"
    Z2_FW_BASELINE_READY=1
    return 0
}

z2_fw_cleanup_is_unambiguous() {
    z2_fw_capture_baseline "$1"
}

z2_fw_save_audit() {
    local tool="$1" plan
    [ "$Z2_FW_BASELINE_READY" = 1 ] || return 1
    plan="$Z2_FW_BASELINE_OUT_CHAIN $Z2_FW_BASELINE_IN_CHAIN $Z2_FW_BASELINE_OUT_ANCHORS $Z2_FW_BASELINE_IN_ANCHORS"
    case "$tool" in
        iptables) Z2_FW_AUDIT_IPTABLES="$plan" ;;
        ip6tables) Z2_FW_AUDIT_IP6TABLES="$plan" ;;
        *) return 1 ;;
    esac
}

z2_fw_load_audit() {
    local tool="$1" plan
    case "$tool" in
        iptables) plan="$Z2_FW_AUDIT_IPTABLES" ;;
        ip6tables) plan="$Z2_FW_AUDIT_IP6TABLES" ;;
        *) return 1 ;;
    esac
    # Saved audit plans contain exactly four decimal fields.
    # shellcheck disable=SC2086
    set -- $plan
    [ "$#" = 4 ] || return 1
    Z2_FW_BASELINE_OUT_CHAIN="$1"
    Z2_FW_BASELINE_IN_CHAIN="$2"
    Z2_FW_BASELINE_OUT_ANCHORS="$3"
    Z2_FW_BASELINE_IN_ANCHORS="$4"
    Z2_FW_BASELINE_READY=1
}

z2_fw_family_absent() {
    local tool="$1"
    command -v "$tool" >/dev/null 2>&1 || return 2
    z2_fw_capture_baseline "$tool" || return 2
    [ "$Z2_FW_BASELINE_OUT_CHAIN:$Z2_FW_BASELINE_IN_CHAIN:$Z2_FW_BASELINE_OUT_ANCHORS:$Z2_FW_BASELINE_IN_ANCHORS" = 0:0:0:0 ]
}

# Builder counterpart of the old per-line emitter: cleanup lines land in
# Z2_FW_BUILT_CLEANUP (empty when the baseline is already clean) so batch
# authors can fold them into one write.
z2_fw_build_baseline_cleanup() {
    local n nl='
'
    Z2_FW_BUILT_CLEANUP=""
    [ "$Z2_FW_BASELINE_READY" = 1 ] || return 1
    n=0
    while [ "$n" -lt "$Z2_FW_BASELINE_OUT_ANCHORS" ]; do
        Z2_FW_BUILT_CLEANUP="${Z2_FW_BUILT_CLEANUP}${Z2_FW_BUILT_CLEANUP:+$nl}-D OUTPUT -j $Z2_FW_OUT_CHAIN"
        n=$((n + 1))
    done
    n=0
    while [ "$n" -lt "$Z2_FW_BASELINE_IN_ANCHORS" ]; do
        Z2_FW_BUILT_CLEANUP="${Z2_FW_BUILT_CLEANUP}${Z2_FW_BUILT_CLEANUP:+$nl}-D INPUT -j $Z2_FW_IN_CHAIN"
        n=$((n + 1))
    done
    if [ "$Z2_FW_BASELINE_IN_CHAIN" = 1 ]; then
        Z2_FW_BUILT_CLEANUP="${Z2_FW_BUILT_CLEANUP}${Z2_FW_BUILT_CLEANUP:+$nl}-F $Z2_FW_IN_CHAIN$nl-X $Z2_FW_IN_CHAIN"
    fi
    if [ "$Z2_FW_BASELINE_OUT_CHAIN" = 1 ]; then
        Z2_FW_BUILT_CLEANUP="${Z2_FW_BUILT_CLEANUP}${Z2_FW_BUILT_CLEANUP:+$nl}-F $Z2_FW_OUT_CHAIN$nl-X $Z2_FW_OUT_CHAIN"
    fi
}

# multiport accepts at most 15 values and a range spends two of them. That is a
# userspace parser limit rather than a kernel capability, so it is computed
# before the batch is written instead of being discovered from a rejection.
Z2_FW_MULTIPORT_MAX_VALUES=15

# One fork-free walk answers both interval questions a port list gets asked:
# the multiport value weight (a range spends two values) and the interval
# count that sizes the per-interval fallback topology.
z2_fw_measure_port_list() {
    local rest="$1" token
    Z2_FW_PORT_WEIGHT=0
    Z2_FW_PORT_INTERVALS=0
    while [ -n "$rest" ]; do
        case "$rest" in
            *,*) token="${rest%%,*}"; rest="${rest#*,}" ;;
            *) token="$rest"; rest="" ;;
        esac
        [ -n "$token" ] || continue
        case "$token" in
            *:*) Z2_FW_PORT_WEIGHT=$((Z2_FW_PORT_WEIGHT + 2)) ;;
            *) Z2_FW_PORT_WEIGHT=$((Z2_FW_PORT_WEIGHT + 1)) ;;
        esac
        Z2_FW_PORT_INTERVALS=$((Z2_FW_PORT_INTERVALS + 1))
    done
}

# Both families are authored from the same port lists, so one list over the
# limit disqualifies multiport for the whole ruleset rather than for one rule.
z2_fw_multiport_fits() {
    local tcp udp
    z2_fw_measure_port_list "$PORTS_TCP"
    tcp="$Z2_FW_PORT_WEIGHT"
    z2_fw_measure_port_list "$PORTS_UDP"
    udp="$Z2_FW_PORT_WEIGHT"
    [ "$tcp" -le "$Z2_FW_MULTIPORT_MAX_VALUES" ] &&
        [ "$udp" -le "$Z2_FW_MULTIPORT_MAX_VALUES" ]
}

# The rules a chain/protocol pair publishes, built as data in a global. The
# batch writer prints them and post-publication verification compares them,
# so building them here instead of inside a command substitution spares the
# verifier its per-call subshell forks.
z2_fw_build_batch_rules() {
    local chain="$1" proto="$2" direction="$3" ports="$4"
    local packet_count="$5" cb_dir="$6" connbytes="$7" multiport="${8:-1}"
    local tail rest token portopt nl='
'
    Z2_FW_BUILT_RULES=""
    [ -n "$ports" ] || return 0
    tail=""
    if [ "$connbytes" = 1 ]; then
        tail=" -m connbytes --connbytes 1:$packet_count --connbytes-dir $cb_dir --connbytes-mode packets"
    fi
    tail="$tail -m mark ! --mark $DESYNC_MARK/$DESYNC_MARK -j NFQUEUE --queue-num $QNUM --queue-bypass"
    if [ "$multiport" = 1 ]; then
        if [ "$direction" = out ]; then portopt="--dports"; else portopt="--sports"; fi
        Z2_FW_BUILT_RULES="-A $chain -p $proto -m multiport $portopt $ports$tail"
        return 0
    fi
    # A port list has no single-rule form without xt_multiport, so each
    # interval becomes its own rule. The protocol match provides --dport and
    # --sport natively, and both accept one port or one range, so this form
    # needs no extension beyond the one -p already loaded.
    if [ "$direction" = out ]; then portopt="--dport"; else portopt="--sport"; fi
    rest="$ports"
    while [ -n "$rest" ]; do
        case "$rest" in
            *,*) token="${rest%%,*}"; rest="${rest#*,}" ;;
            *) token="$rest"; rest="" ;;
        esac
        [ -n "$token" ] || continue
        Z2_FW_BUILT_RULES="${Z2_FW_BUILT_RULES}${Z2_FW_BUILT_RULES:+$nl}-A $chain -p $proto $portopt $token$tail"
    done
}

z2_fw_write_batch() {
    local path="$1" connbytes="$2" multiport="${3:-1}" batch nl='
'
    z2_fw_build_baseline_cleanup || return 1
    batch="*mangle"
    [ -z "$Z2_FW_BUILT_CLEANUP" ] || batch="$batch$nl$Z2_FW_BUILT_CLEANUP"
    batch="$batch$nl:$Z2_FW_OUT_CHAIN - [0:0]"
    [ "$connbytes" != 1 ] || batch="$batch$nl:$Z2_FW_IN_CHAIN - [0:0]"
    z2_fw_build_batch_rules "$Z2_FW_OUT_CHAIN" tcp out "$PORTS_TCP" "$TCP_PKT_OUT" original "$connbytes" "$multiport" || return 1
    [ -z "$Z2_FW_BUILT_RULES" ] || batch="$batch$nl$Z2_FW_BUILT_RULES"
    z2_fw_build_batch_rules "$Z2_FW_OUT_CHAIN" udp out "$PORTS_UDP" "$UDP_PKT_OUT" original "$connbytes" "$multiport" || return 1
    [ -z "$Z2_FW_BUILT_RULES" ] || batch="$batch$nl$Z2_FW_BUILT_RULES"
    if [ "$connbytes" = 1 ]; then
        z2_fw_build_batch_rules "$Z2_FW_IN_CHAIN" tcp in "$PORTS_TCP" "$TCP_PKT_IN" reply 1 "$multiport" || return 1
        [ -z "$Z2_FW_BUILT_RULES" ] || batch="$batch$nl$Z2_FW_BUILT_RULES"
        z2_fw_build_batch_rules "$Z2_FW_IN_CHAIN" udp in "$PORTS_UDP" "$UDP_PKT_IN" reply 1 "$multiport" || return 1
        [ -z "$Z2_FW_BUILT_RULES" ] || batch="$batch$nl$Z2_FW_BUILT_RULES"
    fi
    batch="$batch$nl-A OUTPUT -j $Z2_FW_OUT_CHAIN"
    [ "$connbytes" != 1 ] || batch="$batch$nl-A INPUT -j $Z2_FW_IN_CHAIN"
    batch="$batch${nl}COMMIT"
    z2_emit_line "$batch" > "$path"
}

# A running generation already owns exactly one stable chain/anchor topology.
# A preset whose capture ports change does not need that namespace torn down
# and rediscovered: flush only the authenticated private chains and repopulate
# them in one iptables-restore COMMIT. The built-in anchors never move, so the
# kernel transition is atomic for this family and cannot expose a duplicate or
# half-authored chain.
z2_fw_write_reconfigure_batch() {
    local path="$1" connbytes="$2" multiport="${3:-1}" batch nl='
'
    batch="*mangle$nl-F $Z2_FW_OUT_CHAIN"
    [ "$connbytes" != 1 ] || batch="$batch$nl-F $Z2_FW_IN_CHAIN"
    z2_fw_build_batch_rules "$Z2_FW_OUT_CHAIN" tcp out "$PORTS_TCP" "$TCP_PKT_OUT" original "$connbytes" "$multiport" || return 1
    [ -z "$Z2_FW_BUILT_RULES" ] || batch="$batch$nl$Z2_FW_BUILT_RULES"
    z2_fw_build_batch_rules "$Z2_FW_OUT_CHAIN" udp out "$PORTS_UDP" "$UDP_PKT_OUT" original "$connbytes" "$multiport" || return 1
    [ -z "$Z2_FW_BUILT_RULES" ] || batch="$batch$nl$Z2_FW_BUILT_RULES"
    if [ "$connbytes" = 1 ]; then
        z2_fw_build_batch_rules "$Z2_FW_IN_CHAIN" tcp in "$PORTS_TCP" "$TCP_PKT_IN" reply 1 "$multiport" || return 1
        [ -z "$Z2_FW_BUILT_RULES" ] || batch="$batch$nl$Z2_FW_BUILT_RULES"
        z2_fw_build_batch_rules "$Z2_FW_IN_CHAIN" udp in "$PORTS_UDP" "$UDP_PKT_IN" reply 1 "$multiport" || return 1
        [ -z "$Z2_FW_BUILT_RULES" ] || batch="$batch$nl$Z2_FW_BUILT_RULES"
    fi
    batch="$batch${nl}COMMIT"
    z2_emit_line "$batch" > "$path"
}

# Hot replacement consumes capabilities already authenticated in owner.meta.
# The deterministic rule vocabulary therefore needs one atomic COMMIT, not a
# speculative --test plus a second COMMIT. A rejected COMMIT leaves the family
# unchanged; exact post-publication verification still gates success.
z2_fw_reconfigure_family() {
    local tool="$1" connbytes="$2" multiport="${3:-1}" restore batch
    Z2_FW_BACKEND=""; Z2_FW_CONNBYTES=0; Z2_FW_MULTIPORT="$multiport"
    Z2_FW_RULES=0; Z2_FW_CHAINS=0; Z2_FW_ANCHORS=0
    Z2_FW_FAILURE_CLASS=""; Z2_FW_ERROR_DETAIL=""
    case "$connbytes:$multiport" in [01]:[01]) ;; *) return 2;; esac
    z2_fw_restore_command_read "$tool" || return 2
    restore="$Z2_FW_RESTORE_COMMAND"
    command -v "$restore" >/dev/null 2>&1 || return 3
    batch="$STATE_DIR/tmp/firewall-reconfigure.${tool}.$$"
    z2_fw_ensure_scratch_dir || {
        Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_ERROR_DETAIL="unavailable firewall scratch directory"
        return 1
    }
    state_path_is_managed_file "$batch" || {
        Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_ERROR_DETAIL="unsafe firewall reconfiguration path"
        return 1
    }
    z2_fw_claim_scratch_path "$batch" || {
        Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_ERROR_DETAIL="firewall reconfiguration path already exists"
        return 1
    }
    umask 077
    z2_fw_write_reconfigure_batch "$batch" "$connbytes" "$multiport" || {
        rm -f "$batch" 2>/dev/null
        Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_ERROR_DETAIL="cannot create firewall reconfiguration batch"
        return 1
    }
    if ! z2_fw_run_restore "$restore" "$tool" commit "$batch"; then
        z2_fw_set_restore_failure "$restore" commit "$connbytes"
        rm -f "$batch" 2>/dev/null || {
            Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
            Z2_FW_ERROR_DETAIL="cannot remove failed firewall reconfiguration batch"
            return 1
        }
        return 1
    fi
    rm -f "$batch" 2>/dev/null || {
        Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_ERROR_DETAIL="cannot remove committed firewall reconfiguration batch"
        return 1
    }
    # A zero restore exit is necessary but has been observed insufficient on
    # real kernels: a family commit can succeed while the published table does
    # not carry the authored topology, and a silent divergence here survives
    # daemon-only replacements untouched until a later audit refuses to work
    # on it. The canonical-signature comparison is the only detector for that
    # class, so it stays on the mutation path.
    if ! z2_fw_verify_family "$tool" "$connbytes" "$multiport"; then
        Z2_FW_FAILURE_CLASS=POSTCONDITION_FAILED
        Z2_FW_ERROR_DETAIL="$Z2_FW_VERIFY_DETAIL"
        return 1
    fi
    Z2_FW_BACKEND=restore
    Z2_FW_CONNBYTES="$connbytes"
    Z2_FW_MULTIPORT="$multiport"
    return 0
}

z2_fw_write_cleanup_batch() {
    local path="$1" batch nl='
'
    z2_fw_build_baseline_cleanup || return 1
    batch="*mangle"
    [ -z "$Z2_FW_BUILT_CLEANUP" ] || batch="$batch$nl$Z2_FW_BUILT_CLEANUP"
    batch="$batch${nl}COMMIT"
    z2_emit_line "$batch" > "$path"
}

z2_fw_apply_restore() {
    local tool="$1" connbytes="$2" multiport="${3:-1}" restore batch
    Z2_FW_FAILURE_CLASS=""
    Z2_FW_ERROR_DETAIL=""
    z2_fw_restore_command_read "$tool" || return 2
    restore="$Z2_FW_RESTORE_COMMAND"
    command -v "$restore" >/dev/null 2>&1 || return 3
    batch="$STATE_DIR/tmp/firewall-batch.${tool}.$$"
    z2_fw_ensure_scratch_dir || {
        Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_ERROR_DETAIL="unavailable firewall scratch directory"
        return 1
    }
    state_path_is_managed_file "$batch" || {
        Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_ERROR_DETAIL="unsafe firewall batch path"
        return 1
    }
    z2_fw_claim_scratch_path "$batch" || {
        Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_ERROR_DETAIL="firewall batch path already exists"
        return 1
    }
    umask 077
    z2_fw_write_batch "$batch" "$connbytes" "$multiport" || {
        rm -f "$batch" 2>/dev/null
        Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_ERROR_DETAIL="cannot create firewall batch"
        return 1
    }
    chmod 0600 "$batch" 2>/dev/null || {
        rm -f "$batch" 2>/dev/null
        Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_ERROR_DETAIL="cannot secure firewall batch"
        return 1
    }
    if z2_fw_run_restore "$restore" "$tool" test "$batch"; then
        :
    else
        z2_fw_set_restore_failure "$restore" test "$connbytes"
        rm -f "$batch" 2>/dev/null || {
            Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
            Z2_FW_ERROR_DETAIL="cannot remove rejected firewall batch"
            return 1
        }
        [ "$Z2_FW_FAILURE_CLASS" = RULESET_REJECTED ] && return 4
        return 1
    fi
    if z2_fw_run_restore "$restore" "$tool" commit "$batch"; then
        :
    else
        z2_fw_set_restore_failure "$restore" commit "$connbytes"
        rm -f "$batch" 2>/dev/null || {
            Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
            Z2_FW_ERROR_DETAIL="cannot remove failed firewall batch"
            return 1
        }
        return 1
    fi
    rm -f "$batch" 2>/dev/null || {
        Z2_FW_FAILURE_CLASS=STATE_UNAVAILABLE
        Z2_FW_ERROR_DETAIL="cannot remove committed firewall batch"
        return 1
    }
    Z2_FW_BACKEND=restore
    return 0
}

z2_fw_expected_rule_count() {
    local connbytes="$1" multiport="${2:-1}" per_direction=0 tcp udp
    Z2_FW_EXPECTED_RULES=0
    if [ "$multiport" = 1 ]; then
        [ -z "$PORTS_TCP" ] || per_direction=$((per_direction + 1))
        [ -z "$PORTS_UDP" ] || per_direction=$((per_direction + 1))
    else
        # One rule per interval, so the published count is the interval count.
        z2_fw_measure_port_list "$PORTS_TCP"
        tcp="$Z2_FW_PORT_INTERVALS"
        z2_fw_measure_port_list "$PORTS_UDP"
        udp="$Z2_FW_PORT_INTERVALS"
        per_direction=$((tcp + udp))
    fi
    Z2_FW_EXPECTED_RULES=$((per_direction * (1 + connbytes)))
}

z2_fw_verify_family() {
    local tool="$1" connbytes="$2" multiport="${3:-1}" listing verification
    local out_tcp out_udp in_tcp in_udp
    Z2_FW_VERIFY_DETAIL=""
    listing="$("$tool" -t mangle -S 2>/dev/null)" || {
        Z2_FW_VERIFY_DETAIL="$tool mangle snapshot command failed"
        return 1
    }
    z2_fw_build_batch_rules "$Z2_FW_OUT_CHAIN" tcp out "$PORTS_TCP" "$TCP_PKT_OUT" original "$connbytes" "$multiport" || return 1
    out_tcp="$Z2_FW_BUILT_RULES"
    z2_fw_build_batch_rules "$Z2_FW_OUT_CHAIN" udp out "$PORTS_UDP" "$UDP_PKT_OUT" original "$connbytes" "$multiport" || return 1
    out_udp="$Z2_FW_BUILT_RULES"
    in_tcp=""
    in_udp=""
    if [ "$connbytes" = 1 ]; then
        z2_fw_build_batch_rules "$Z2_FW_IN_CHAIN" tcp in "$PORTS_TCP" "$TCP_PKT_IN" reply 1 "$multiport" || return 1
        in_tcp="$Z2_FW_BUILT_RULES"
        z2_fw_build_batch_rules "$Z2_FW_IN_CHAIN" udp in "$PORTS_UDP" "$UDP_PKT_IN" reply 1 "$multiport" || return 1
        in_udp="$Z2_FW_BUILT_RULES"
    fi
    # The backend re-renders published rules in its own save format: match
    # option order, --dports vs --dport for a single port, and mark mask
    # elision all differ between iptables builds. Verification therefore
    # compares canonical rule signatures built from the closed module
    # vocabulary, never the authored batch text. Anything outside that
    # vocabulary inside the owned namespace is a foreign rule.
    # Android awk rejects newlines inside -v assignments. Feed the authored
    # rule sets and the backend snapshot as distinct stdin sections instead;
    # only bounded, single-line scalar identities remain command arguments.
    verification="$({
        printf '%s\n' 'Z2_EXPECTED_OUT_BEGIN'
        printf '%s\n' "$out_tcp"
        printf '%s\n' "$out_udp"
        printf '%s\n' 'Z2_EXPECTED_IN_BEGIN'
        printf '%s\n' "$in_tcp"
        printf '%s\n' "$in_udp"
        printf '%s\n' 'Z2_LISTING_BEGIN'
        printf '%s\n' "$listing"
    } | awk \
        -v out="$Z2_FW_OUT_CHAIN" -v inchain="$Z2_FW_IN_CHAIN" \
        -v connbytes="$connbytes" '
        # Without multiport a port list becomes one rule per interval, so a
        # single expected signature per chain and protocol is no longer the
        # shape to compare against. Expectations are loaded as a multiset of
        # canonical signatures: every published rule must match one, and every
        # expected one must appear exactly as often as it was authored.
        function load_expected_line(line, chainkey,    sig) {
            if (line == "") return
            sig = canon(line)
            if (sig == "") { expected_bad = 1; return }
            exp_count[sig]++
            exp_total[chainkey]++
        }
        function expectations_met(chainkey,    sig) {
            for (sig in exp_count)
                if (index(sig, "-A " chainkey " ") == 1 &&
                    seen_count[sig] != exp_count[sig]) return 0
            return 1
        }
        function canon(line,    n, t, i, tok, val, chain, proto, portskey,
                       ports, cbrange, cbdir, cbmode, markval, markinv,
                       target, qnum, bypass, invert, sig) {
            n = split(line, t, " ")
            if (n < 4 || t[1] != "-A") return ""
            chain = t[2]
            invert = 0
            for (i = 3; i <= n; i++) {
                tok = t[i]
                if (tok == "!") {
                    if (invert) return ""
                    invert = 1
                    continue
                }
                if (tok == "-m" || tok == "--match") {
                    i++
                    if (invert || i > n) return ""
                    if (t[i] != "multiport" && t[i] != "connbytes" &&
                        t[i] != "mark" && t[i] != "tcp" && t[i] != "udp")
                        return ""
                    continue
                }
                if (tok == "--queue-bypass") {
                    if (invert) return ""
                    bypass = 1
                    continue
                }
                i++
                if (i > n) return ""
                val = t[i]
                if (tok == "-p" || tok == "--protocol") {
                    if (invert || proto != "") return ""
                    proto = val
                } else if (tok == "--dports" || tok == "--dport") {
                    if (invert || ports != "") return ""
                    portskey = "d"; ports = val
                } else if (tok == "--sports" || tok == "--sport") {
                    if (invert || ports != "") return ""
                    portskey = "s"; ports = val
                } else if (tok == "--connbytes") {
                    if (invert || cbrange != "") return ""
                    cbrange = val
                } else if (tok == "--connbytes-dir") {
                    if (invert || cbdir != "") return ""
                    cbdir = val
                } else if (tok == "--connbytes-mode") {
                    if (invert || cbmode != "") return ""
                    cbmode = val
                } else if (tok == "--mark") {
                    if (markval != "") return ""
                    markinv = invert
                    invert = 0
                    if (!index(val, "/")) val = val "/0xffffffff"
                    markval = val
                } else if (tok == "-j" || tok == "--jump") {
                    if (invert || target != "") return ""
                    target = val
                } else if (tok == "--queue-num") {
                    if (invert || qnum != "") return ""
                    qnum = val
                } else {
                    return ""
                }
            }
            if (invert) return ""
            if ((cbrange != "" || cbdir != "" || cbmode != "") &&
                (cbrange == "" || cbdir == "" || cbmode == "")) return ""
            sig = "-A " chain " p=" proto " " portskey "ports=" ports
            if (cbrange != "") sig = sig " cb=" cbrange "/" cbmode "/" cbdir
            if (markval != "") sig = sig " mark=" (markinv ? "!" : "") markval
            sig = sig " j=" target
            if (qnum != "") sig = sig " qnum=" qnum
            if (bypass) sig = sig " bypass"
            return sig
        }
        $0 == "Z2_EXPECTED_OUT_BEGIN" { input_section="out"; next }
        $0 == "Z2_EXPECTED_IN_BEGIN" { input_section="in"; next }
        $0 == "Z2_LISTING_BEGIN" { input_section="listing"; next }
        input_section == "out" { load_expected_line($0, out); next }
        input_section == "in" { load_expected_line($0, inchain); next }
        $1 == "-N" && $2 == out { out_chain++ }
        $1 == "-N" && $2 == inchain { in_chain++ }
        $1 == "-A" && $2 == out {
            out_rules++
            sig = canon($0)
            if (sig != "" && (sig in exp_count)) seen_count[sig]++
            else bad=1
        }
        $1 == "-A" && $2 == inchain {
            in_rules++
            sig = canon($0)
            if (sig != "" && (sig in exp_count)) seen_count[sig]++
            else bad=1
        }
        $1 == "-A" {
            for (i=3; i<=NF; i++) {
                if ($i != "-j" && $i != "--jump" &&
                    $i != "-g" && $i != "--goto") continue
                target=$(i+1)
                if (target == out) {
                    if ($0 == "-A OUTPUT -j " out) out_anchor++
                    else bad=1
                } else if (target == inchain) {
                    if ($0 == "-A INPUT -j " inchain) in_anchor++
                    else bad=1
                }
            }
        }
        END {
            if (expected_bad) {
                print "EXPECTED_RULE_UNPARSEABLE"
                exit 1
            }
            expected_out=exp_total[out]
            expected_in=exp_total[inchain]
            if (bad) reason="FOREIGN_OR_UNEXPECTED_RULE"
            else if (out_chain != 1) reason="OUT_CHAIN_COUNT:" out_chain
            else if (out_anchor != 1) reason="OUT_ANCHOR_COUNT:" out_anchor
            else if (out_rules != expected_out) reason="OUT_RULE_COUNT:" out_rules
            else if (!expectations_met(out)) reason="OUT_RULE_MISMATCH"
            if (connbytes == 1) {
                if (reason == "" && in_chain != 1) reason="INPUT_CHAIN_COUNT:" in_chain
                else if (reason == "" && in_anchor != 1) reason="INPUT_ANCHOR_COUNT:" in_anchor
                else if (reason == "" && in_rules != expected_in) reason="INPUT_RULE_COUNT:" in_rules
                else if (reason == "" && !expectations_met(inchain))
                    reason="INPUT_RULE_MISMATCH"
            } else {
                if (reason == "" &&
                    (in_chain != 0 || in_anchor != 0 || in_rules != 0))
                    reason="UNEXPECTED_INPUT_TOPOLOGY"
            }
            if (reason != "") {
                print reason
                exit 1
            }
        }')" || {
        [ -n "$verification" ] || verification=UNKNOWN_TOPOLOGY_MISMATCH
        Z2_FW_VERIFY_DETAIL="$tool post-publication topology mismatch (connbytes=$connbytes, reason=$verification)"
        return 1
    }
    Z2_FW_CONNBYTES="$connbytes"
    z2_fw_expected_rule_count "$connbytes" "$multiport" || return 1
    Z2_FW_RULES="$Z2_FW_EXPECTED_RULES"
    Z2_FW_CHAINS=$((1 + connbytes))
    Z2_FW_ANCHORS=$((1 + connbytes))
    return 0
}

z2_fw_apply_cleanup() {
    local tool="$1" restore batch phase rc detail
    [ "$Z2_FW_BASELINE_READY" = 1 ] || return 1
    if [ "$Z2_FW_BASELINE_OUT_CHAIN:$Z2_FW_BASELINE_IN_CHAIN:$Z2_FW_BASELINE_OUT_ANCHORS:$Z2_FW_BASELINE_IN_ANCHORS" = 0:0:0:0 ]; then
        return 0
    fi
    z2_fw_restore_command_read "$tool" || return 2
    restore="$Z2_FW_RESTORE_COMMAND"
    command -v "$restore" >/dev/null 2>&1 || return 3
    batch="$STATE_DIR/tmp/firewall-cleanup.${tool}.$$"
    z2_fw_ensure_scratch_dir || return 1
    state_path_is_managed_file "$batch" || return 1
    z2_fw_claim_scratch_path "$batch" || return 1
    umask 077
    if ! z2_fw_write_cleanup_batch "$batch" ||
       ! chmod 0600 "$batch" 2>/dev/null; then
        rm -f "$batch" 2>/dev/null
        return 1
    fi
    for phase in test commit; do
        if z2_fw_run_restore "$restore" "$tool" "$phase" "$batch"; then
            :
        else
            rc=$?
            detail="${Z2_FW_LAST_RESTORE_DETAIL:-no backend diagnostic}"
            Z2_FW_FAILURE_CLASS="${Z2_FW_LAST_FAILURE_CLASS:-CLEANUP_FAILED}"
            Z2_FW_ERROR_DETAIL="$restore atomic cleanup $phase failed (exit=$Z2_FW_LAST_RESTORE_EXIT): $detail"
            Z2_FW_ERROR_DETAIL="$(z2_fw_normalize_diagnostic "$Z2_FW_ERROR_DETAIL")"
            rm -f "$batch" 2>/dev/null || true
            return "$rc"
        fi
    done
    rm -f "$batch" 2>/dev/null || return 1
    if z2_fw_family_absent "$tool"; then
        return 0
    fi
    Z2_FW_FAILURE_CLASS=POSTCONDITION_FAILED
    Z2_FW_ERROR_DETAIL="$tool atomic cleanup postcondition failed"
    return 1
}

z2_fw_cleanup_family() {
    local tool="$1" baseline_mode="${2:-owned}"
    case "$baseline_mode" in
        owned)
            command -v "$tool" >/dev/null 2>&1 || return 2
            z2_fw_capture_baseline "$tool" || return 1
            ;;
        audited)
            command -v "$tool" >/dev/null 2>&1 || return 2
            z2_fw_load_audit "$tool" || return 1
            ;;
        *) return 2 ;;
    esac
    z2_fw_restore_available "$tool" || return 3
    z2_fw_apply_cleanup "$tool"
}

z2_fw_reconcile_family() {
    local tool="$1" baseline_mode="${2:-owned}" apply_rc candidate_detail verify_detail
    local connbytes multiport
    case "$baseline_mode" in owned|audited) ;; *) return 2 ;; esac
    Z2_FW_BACKEND=""; Z2_FW_CONNBYTES=0; Z2_FW_MULTIPORT=1
    Z2_FW_RULES=0; Z2_FW_CHAINS=0; Z2_FW_ANCHORS=0
    Z2_FW_FAILURE_CLASS=""; Z2_FW_ERROR_DETAIL=""; Z2_FW_FALLBACK_DETAIL=""
    command -v "$tool" >/dev/null 2>&1 || {
        Z2_FW_FAILURE_CLASS=BACKEND_UNAVAILABLE
        Z2_FW_ERROR_DETAIL="$tool command is unavailable"
        return 2
    }
    z2_fw_restore_available "$tool" || {
        Z2_FW_FAILURE_CLASS=BACKEND_UNAVAILABLE
        Z2_FW_ERROR_DETAIL="$tool restore backend is unavailable"
        return 3
    }
    if [ "$baseline_mode" = audited ]; then
        z2_fw_load_audit "$tool" || {
            Z2_FW_FAILURE_CLASS=CLEANUP_FAILED
            Z2_FW_ERROR_DETAIL="$tool authenticated transition baseline is unavailable"
            return 1
        }
    else
        z2_fw_capture_baseline "$tool" || {
            Z2_FW_FAILURE_CLASS=CLEANUP_FAILED
            Z2_FW_ERROR_DETAIL="$tool stable namespace transition preflight failed"
            return 1
        }
    fi
    # Two optional capabilities, each with its own latch. A rejection may only
    # retire the capability its own diagnostic names, and each is retired at
    # most once, so at most two downgrades happen and neither can be undone by
    # a later failure. Anything the backend rejects for a reason it does not
    # name is a publication error: silently rebuilding a different topology
    # would hide a broken configuration instead of a missing kernel module.
    #
    # The two fail at different phases. iptables-restore --test parses in
    # userspace but asks the kernel for match revisions while doing so, which
    # is where a missing xt_multiport surfaces; connbytes passes the test phase
    # and is rejected only at COMMIT. Legacy restore submits the whole table in
    # one atomic replace, so a rejected COMMIT leaves the pre-transaction
    # state, and post-publication verification still gates every result.
    connbytes=1
    multiport=1
    # The 15-value limit is a parser rule, not a capability, so it is settled
    # before the first attempt rather than learned from a rejection.
    z2_fw_multiport_fits || {
        multiport=0
        Z2_FW_FALLBACK_DETAIL="port list exceeds the $Z2_FW_MULTIPORT_MAX_VALUES values multiport accepts"
    }
    while :; do
        if z2_fw_apply_restore "$tool" "$connbytes" "$multiport"; then
            apply_rc=0
        else
            apply_rc=$?
        fi
        if [ "$apply_rc" = 0 ]; then
            if ! z2_fw_verify_family "$tool" "$connbytes" "$multiport"; then
                verify_detail="$Z2_FW_VERIFY_DETAIL"
                z2_fw_cleanup_family "$tool" >/dev/null 2>&1 || true
                Z2_FW_FAILURE_CLASS=POSTCONDITION_FAILED
                Z2_FW_ERROR_DETAIL="$verify_detail"
                return 1
            fi
            Z2_FW_CONNBYTES="$connbytes"
            Z2_FW_MULTIPORT="$multiport"
            Z2_FW_FAILURE_CLASS=""; Z2_FW_ERROR_DETAIL=""
            return 0
        fi
        candidate_detail="$Z2_FW_ERROR_DETAIL"
        # A candidate rejection at test is a capability signal by itself; any
        # other failure has to be a publication failure to be one at all.
        if [ "$apply_rc" != 4 ] && [ "$Z2_FW_FAILURE_CLASS" != PUBLICATION_FAILED ]; then
            return 1
        fi
        # Match the raw backend stderr: the wrapped detail carries markers of
        # its own. The named capability wins, so a multiport rejection never
        # spends the connbytes latch on its way down.
        if [ "$connbytes" = 1 ] &&
           z2_fw_diagnostic_is_connbytes_unsupported "$Z2_FW_LAST_RESTORE_DETAIL"; then
            connbytes=0
        elif [ "$multiport" = 1 ] &&
             z2_fw_diagnostic_is_multiport_unsupported "$Z2_FW_LAST_RESTORE_DETAIL"; then
            multiport=0
        elif [ "$apply_rc" = 4 ] && [ "$connbytes" = 1 ]; then
            # An unnamed test rejection retires the richer topology first,
            # which is the only one whose absence a kernel can survive.
            connbytes=0
        else
            if [ -z "$Z2_FW_ERROR_DETAIL" ]; then
                Z2_FW_FAILURE_CLASS=POSTCONDITION_FAILED
                Z2_FW_ERROR_DETAIL="$tool post-publication verification failed (connbytes=$connbytes, multiport=$multiport)"
            fi
            return 1
        fi
        Z2_FW_FALLBACK_DETAIL="${Z2_FW_FALLBACK_DETAIL:+$Z2_FW_FALLBACK_DETAIL; }$candidate_detail"
    done
}
