#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=${Z2_TEST_TMP:?}
CASE="$TMP/firewall-reconciler"
STATE="$CASE/state"
MOCK="$CASE/bin"
FW="$CASE/fw"

fail() { echo "FAIL: firewall-reconciler: $*" >&2; exit 1; }

mkdir -p "$STATE" "$MOCK" "$FW"

# Real backends re-render committed rules in their own save format instead of
# echoing the authored batch text: libxt_connbytes saves --connbytes-mode
# before --connbytes-dir, and nft-backed builds translate a single-port
# multiport match into the plain tcp match. Both mocks re-render through this
# shared filter so verification is exercised against kernel output, not
# against the module's own serialization.
cat > "$CASE/render-saved-rules" <<'EOF'
#!/bin/sh
sed \
    -e 's/--connbytes \([0-9:]*\) --connbytes-dir \([a-z]*\) --connbytes-mode \([a-z]*\)/--connbytes \1 --connbytes-mode \3 --connbytes-dir \2/' \
    -e 's/-p tcp -m multiport --dports \([0-9]*\) /-p tcp -m tcp --dport \1 /'
EOF
chmod 0755 "$CASE/render-saved-rules"

cat > "$MOCK/iptables" <<'EOF'
#!/bin/sh
state="$Z2_MOCK_FW"
args=" $* "
printf '%s\n' "$*" >> "$state/iptables.args"
case "$args" in
    *' -t mangle -L OUTPUT -n '*) exit 0 ;;
    *' -t mangle -C OUTPUT -j ZAPRET2_OUT '*) [ -f "$state/anchor.out" ] ;;
    *' -t mangle -C INPUT -j ZAPRET2_IN '*) [ -f "$state/anchor.in" ] ;;
    *' -t mangle -C FORWARD -j ZAPRET2_OUT '*) [ -f "$state/anchor.fwd.out" ] ;;
    *' -t mangle -C FORWARD -j ZAPRET2_IN '*) [ -f "$state/anchor.fwd.in" ] ;;
    *' -t mangle -D OUTPUT -j ZAPRET2_OUT '*) rm -f "$state/anchor.out" ;;
    *' -t mangle -D INPUT -j ZAPRET2_IN '*) rm -f "$state/anchor.in" ;;
    *' -t mangle -D FORWARD -j ZAPRET2_OUT '*) rm -f "$state/anchor.fwd.out" ;;
    *' -t mangle -D FORWARD -j ZAPRET2_IN '*) rm -f "$state/anchor.fwd.in" ;;
    *' -t mangle -S ZAPRET2_OUT '*)
        [ -f "$state/chain.out" ] || exit 1
        echo '-N ZAPRET2_OUT'
        [ ! -f "$state/rules.out" ] || cat "$state/rules.out"
        ;;
    *' -t mangle -S ZAPRET2_IN '*)
        [ -f "$state/chain.in" ] || exit 1
        echo '-N ZAPRET2_IN'
        [ ! -f "$state/rules.in" ] || cat "$state/rules.in"
        ;;
    *' -t mangle -C ZAPRET2_OUT '*)
        needle="-A ZAPRET2_OUT ${args#* -C ZAPRET2_OUT }"
        needle=$(printf '%s\n' "${needle% }" | "$Z2_MOCK_RENDER")
        grep -Fqx -- "$needle" "$state/rules.out"
        ;;
    *' -t mangle -C ZAPRET2_IN '*)
        needle="-A ZAPRET2_IN ${args#* -C ZAPRET2_IN }"
        needle=$(printf '%s\n' "${needle% }" | "$Z2_MOCK_RENDER")
        grep -Fqx -- "$needle" "$state/rules.in"
        ;;
    *' -t mangle -F ZAPRET2_OUT '*) : > "$state/rules.out" ;;
    *' -t mangle -F ZAPRET2_IN '*) : > "$state/rules.in" ;;
    *' -t mangle -X ZAPRET2_OUT '*)
        [ ! -s "$state/rules.out" ] && [ ! -f "$state/anchor.out" ] || exit 1
        rm -f "$state/chain.out" "$state/rules.out"
        ;;
    *' -t mangle -X ZAPRET2_IN '*)
        [ ! -s "$state/rules.in" ] && [ ! -f "$state/anchor.in" ] || exit 1
        rm -f "$state/chain.in" "$state/rules.in"
        ;;
    *' -t mangle -S '*)
        [ ! -f "$state/chain.out" ] || echo '-N ZAPRET2_OUT'
        [ ! -f "$state/chain.in" ] || echo '-N ZAPRET2_IN'
        [ ! -f "$state/anchor.out" ] || echo '-A OUTPUT -j ZAPRET2_OUT'
        [ ! -f "$state/anchor.in" ] || echo '-A INPUT -j ZAPRET2_IN'
        [ ! -f "$state/anchor.fwd.out" ] || echo '-A FORWARD -j ZAPRET2_OUT'
        [ ! -f "$state/anchor.fwd.in" ] || echo '-A FORWARD -j ZAPRET2_IN'
        [ "${Z2_FOREIGN_REF:-0}" != 1 ] || echo '-A PREROUTING -j ZAPRET2_OUT'
        [ ! -s "$state/rules.out" ] || cat "$state/rules.out"
        [ ! -s "$state/rules.in" ] || cat "$state/rules.in"
        ;;
    *) exit 1 ;;
esac
EOF

cat > "$MOCK/iptables-restore" <<'EOF'
#!/bin/sh
state="$Z2_MOCK_FW"
case " $* " in
    *' --help '*)
        count=0
        [ ! -f "$state/restore-help.count" ] ||
            IFS= read -r count < "$state/restore-help.count"
        printf '%s\n' $((count + 1)) > "$state/restore-help.count"
        [ "${Z2_RESTORE_WAIT_SUPPORTED:-1}" = 1 ] &&
            echo 'Usage: iptables-restore [ --wait seconds ] [ --test ] [ --noflush ]' ||
            echo 'Usage: iptables-restore [ --test ] [ --noflush ]'
        exit 0
        ;;
esac
payload=$(cat)
count=0
[ ! -f "$state/restore.count" ] || IFS= read -r count < "$state/restore.count"
count=$((count + 1))
printf '%s\n' "$count" > "$state/restore.count"
printf '%s\n' "$*" >> "$state/restore.args"
printf '%s\n' "$payload" > "$state/restore.payload.$count"
if [ -f "$state/lock.remaining" ]; then
    IFS= read -r remaining < "$state/lock.remaining"
    if [ "$remaining" -gt 0 ]; then
        printf '%s\n' $((remaining - 1)) > "$state/lock.remaining"
        echo 'Another app is currently holding the xtables lock.' >&2
        exit 4
    fi
fi
case "$payload" in *Z2R_*) exit 90;; esac
if [ "${Z2_RESTORE_REJECT_CONNBYTES:-0}" = 1 ] &&
   printf '%s\n' "$payload" | grep -q -- '-m connbytes'; then
    echo 'connbytes match is unavailable' >&2
    exit 1
fi
if [ "${Z2_RESTORE_REJECT_MARK:-0}" = 1 ] &&
   printf '%s\n' "$payload" | grep -q -- '-m mark'; then
    echo 'Warning: Extension mark revision 0 not supported, missing kernel module?' >&2
    echo 'iptables-restore v1.8.11 (legacy): unknown option "--mark"' >&2
    exit 2
fi
if [ "${Z2_RESTORE_REJECT_MULTIPORT:-0}" = 2 ] &&
   printf '%s\n' "$payload" | grep -q -- '-m multiport'; then
    # Verbatim from a v2.3.0 field report: iptables 1.8.4 legacy names the
    # extension it could not find and says nothing else. No missing-module
    # warning, no complaint about the port list — the entire signal is one
    # word in one line, worded differently from every newer build.
    echo "iptables-restore v1.8.4 (legacy): Couldn't find match \`multiport'" >&2
    echo 'Error occurred at line: 3' >&2
    echo "Try \`iptables-restore -h' or 'iptables-restore --help' for more information." >&2
    exit 2
fi
if [ "${Z2_RESTORE_REJECT_MULTIPORT:-0}" = 3 ] &&
   printf '%s\n' "$payload" | grep -q -- '-m multiport'; then
    # A build that names nothing at all. Nothing can be read out of this, so
    # only exhausting the capabilities can still publish a ruleset.
    echo 'iptables-restore: line 3 failed' >&2
    exit 2
fi
if [ "${Z2_RESTORE_REJECT_MULTIPORT:-0}" = 1 ] &&
   printf '%s\n' "$payload" | grep -q -- '-m multiport'; then
    # Verbatim from a device whose kernel lacks xt_multiport: the extension
    # asks the kernel for a match revision while the batch is still being
    # parsed, so the failure lands on --test, and the port list it can no
    # longer parse is reported right after the missing-module warnings.
    echo 'Warning: Extension multiport revision 0 not supported, missing kernel module?' >&2
    echo 'Warning: Extension multiport is not supported, missing kernel module?' >&2
    echo "iptables-restore v1.8.11 (legacy): invalid port/service \`443:65535' specified" >&2
    echo 'Error occurred at line: 4' >&2
    exit 2
fi
[ "${Z2_RESTORE_REJECT_ALL:-0}" != 1 ] || {
    printf 'vendor parser rejected ruleset\033[31m\n' >&2
    exit 1
}
case " $* " in *' --test '*) exit 0;; esac
if [ "${Z2_RESTORE_REJECT_CONNBYTES_COMMIT:-0}" = 1 ] &&
   printf '%s\n' "$payload" | grep -q -- '-m connbytes'; then
    echo 'Warning: Extension connbytes revision 0 not supported, missing kernel module?' >&2
    echo 'iptables-restore: line 10 failed' >&2
    exit 1
fi
if [ "${Z2_RESTORE_REJECT_CONNBYTES_COMMIT:-0}" = 2 ] &&
   printf '%s\n' "$payload" | grep -q -- '-m connbytes'; then
    # Verbatim from a v2.2.x field report. The userspace library carries
    # libxt_connbytes, so the batch parses and --test passes; the kernel has
    # no xt_connbytes and refuses the table when it is submitted. All legacy
    # restore knows at that point is the batch line it stopped on — line 10 is
    # the COMMIT of a full connbytes ruleset — so the extension is never named
    # anywhere in the diagnostic.
    echo 'iptables-restore: line 10 failed' >&2
    exit 1
fi
[ "${Z2_RESTORE_FAIL_COMMIT:-0}" != 1 ] || {
    echo 'vendor backend rejected COMMIT' >&2
    exit 1
}
if printf '%s\n' "$payload" | grep -Fx -- '-D OUTPUT -j ZAPRET2_OUT' >/dev/null; then
    rm -f "$state/anchor.out"
fi
if printf '%s\n' "$payload" | grep -Fx -- '-D INPUT -j ZAPRET2_IN' >/dev/null; then
    rm -f "$state/anchor.in"
fi
if printf '%s\n' "$payload" | grep -Fx -- '-D FORWARD -j ZAPRET2_OUT' >/dev/null; then
    rm -f "$state/anchor.fwd.out"
fi
if printf '%s\n' "$payload" | grep -Fx -- '-D FORWARD -j ZAPRET2_IN' >/dev/null; then
    rm -f "$state/anchor.fwd.in"
fi
if printf '%s\n' "$payload" | grep -Fx -- '-X ZAPRET2_OUT' >/dev/null; then
    rm -f "$state/chain.out" "$state/rules.out"
fi
if printf '%s\n' "$payload" | grep -Fx -- '-X ZAPRET2_IN' >/dev/null; then
    rm -f "$state/chain.in" "$state/rules.in"
fi
if printf '%s\n' "$payload" | grep -F -- ':ZAPRET2_OUT ' >/dev/null; then
    : > "$state/chain.out"
    printf '%s\n' "$payload" | grep -F -- '-A ZAPRET2_OUT ' |
        "$Z2_MOCK_RENDER" > "$state/rules.out" || :
elif printf '%s\n' "$payload" | grep -Fx -- '-F ZAPRET2_OUT' >/dev/null; then
    : > "$state/rules.out"
    printf '%s\n' "$payload" | grep -F -- '-A ZAPRET2_OUT ' |
        "$Z2_MOCK_RENDER" > "$state/rules.out" || :
fi
if printf '%s\n' "$payload" | grep -F -- ':ZAPRET2_IN ' >/dev/null; then
    : > "$state/chain.in"
    printf '%s\n' "$payload" | grep -F -- '-A ZAPRET2_IN ' |
        "$Z2_MOCK_RENDER" > "$state/rules.in" || :
elif printf '%s\n' "$payload" | grep -Fx -- '-F ZAPRET2_IN' >/dev/null; then
    : > "$state/rules.in"
    printf '%s\n' "$payload" | grep -F -- '-A ZAPRET2_IN ' |
        "$Z2_MOCK_RENDER" > "$state/rules.in" || :
fi
printf '%s\n' "$payload" | grep -Fx -- '-A OUTPUT -j ZAPRET2_OUT' >/dev/null &&
    : > "$state/anchor.out"
if printf '%s\n' "$payload" | grep -Fx -- '-A INPUT -j ZAPRET2_IN' >/dev/null; then
    : > "$state/anchor.in"
fi
if printf '%s\n' "$payload" | grep -Fx -- '-A FORWARD -j ZAPRET2_OUT' >/dev/null; then
    : > "$state/anchor.fwd.out"
fi
if printf '%s\n' "$payload" | grep -Fx -- '-A FORWARD -j ZAPRET2_IN' >/dev/null; then
    : > "$state/anchor.fwd.in"
fi
if [ "${Z2_CORRUPT_AFTER_COMMIT:-0}" = 1 ] &&
   { printf '%s\n' "$payload" | grep -F -- ':ZAPRET2_OUT ' >/dev/null ||
     printf '%s\n' "$payload" | grep -Fx -- '-F ZAPRET2_OUT' >/dev/null; }; then
    sed '$d' "$state/rules.out" > "$state/rules.out.corrupt"
    mv "$state/rules.out.corrupt" "$state/rules.out"
fi
EOF

# The topology comparison is the module's only proof that a published family
# carries the authored ruleset, and the whole comparison is one awk process.
# This mock stands in for that process not running at all — absent, refused by
# the loader, or killed — which is a different fact from a comparison that ran
# and disagreed, and is reported as one.
Z2_REAL_AWK=$(command -v awk)
cat > "$MOCK/awk" <<EOF
#!/bin/sh
if [ "\${Z2_MOCK_AWK_BROKEN:-0}" = 1 ]; then
    echo 'awk: cannot open shared library' >&2
    exit 2
fi
exec $Z2_REAL_AWK "\$@"
EOF

chmod 0755 "$MOCK/iptables" "$MOCK/iptables-restore" "$MOCK/awk"
PATH="$MOCK:$PATH"
STATE_DIR="$STATE"
Z2_MOCK_FW="$FW"
Z2_MOCK_RENDER="$CASE/render-saved-rules"
export PATH STATE_DIR Z2_MOCK_FW Z2_MOCK_RENDER

state_path_is_managed_file() {
    case "$1" in "$STATE"/*) return 0;; *) return 1;; esac
}

. "$ROOT/zapret2/scripts/firewall-reconciler.sh"

PORTS_TCP=80,443
PORTS_UDP=443,3478,5349,19302
TCP_PKT_OUT=20
TCP_PKT_IN=10
UDP_PKT_OUT=12
UDP_PKT_IN=6
QNUM=200
DESYNC_MARK=0x40000000

z2_fw_reconcile_family iptables || fail "atomic restore reconcile failed"
[ "$Z2_FW_BACKEND:$Z2_FW_CONNBYTES:$Z2_FW_RULES:$Z2_FW_CHAINS:$Z2_FW_ANCHORS" = restore:1:4:2:2 ] ||
    fail "atomic restore result metadata changed"
[ -f "$FW/anchor.out" ] && [ -f "$FW/anchor.in" ] ||
    fail "atomic restore did not publish both anchors"
[ "$(cat "$FW/restore.count")" = 2 ] ||
    fail "atomic restore did not use exactly one test and one commit"
[ "$(cat "$FW/restore-help.count")" = 1 ] ||
    fail "restore wait capability was probed more than once per backend"
grep -Fqx -- '--wait 5 --test --noflush' "$FW/restore.args" ||
    fail "native restore lock wait was not used for validation"
grep -Fqx -- '--wait 5 --noflush' "$FW/restore.args" ||
    fail "native restore lock wait was not used for commit"
: > "$FW/iptables.args"
z2_fw_verify_family iptables 1 || fail "published family did not verify"
[ "$(wc -l < "$FW/iptables.args")" = 1 ] ||
    fail "final family verification used more than one kernel snapshot"
grep -Fqx -- '-t mangle -S' "$FW/iptables.args" ||
    fail "final family verification did not use one complete mangle snapshot"

grep -q -- '--connbytes-mode packets --connbytes-dir original' "$FW/rules.out" ||
    fail "mock backend did not re-render published rules in kernel save order"
cp "$FW/rules.out" "$FW/rules.out.published"
printf '%s\n' '-A ZAPRET2_OUT -p tcp -m multiport --dports 80,443 -j RETURN' >> "$FW/rules.out"
if z2_fw_verify_family iptables 1; then
    fail "foreign rule inside the owned chain was accepted"
fi
case "$Z2_FW_VERIFY_DETAIL" in
    *'reason=FOREIGN_OR_UNEXPECTED_RULE'*) ;;
    *) fail "foreign rule lost its typed reason: $Z2_FW_VERIFY_DETAIL" ;;
esac
mv "$FW/rules.out.published" "$FW/rules.out"
z2_fw_verify_family iptables 1 ||
    fail "restored owned chain did not verify after foreign rule removal"

z2_fw_cleanup_is_unambiguous iptables || fail "published baseline audit failed"
z2_fw_save_audit iptables || fail "published baseline audit was not retained"
PORTS_TCP=443
z2_fw_reconcile_family iptables audited ||
    fail "audited atomic replacement failed"
[ "$(cat "$FW/restore.count")" = 4 ] ||
    fail "atomic replacement did not use one test and one commit"
for command in \
    '-D OUTPUT -j ZAPRET2_OUT' \
    '-D INPUT -j ZAPRET2_IN' \
    '-F ZAPRET2_OUT' \
    '-X ZAPRET2_OUT' \
    ':ZAPRET2_OUT - [0:0]'; do
    grep -Fqx -- "$command" "$FW/restore.payload.4" ||
        fail "atomic replacement batch omitted: $command"
done
PORTS_TCP=80,443

# A running generation changes only its authenticated private chain contents:
# one COMMIT, no test pass, no chain/anchor deletion, and one exact snapshot
# verification after publication.
z2_fw_reconfigure_family iptables 1 1 ||
    fail "in-place topology reconfiguration failed"
[ "$(cat "$FW/restore.count")" = 5 ] ||
    fail "in-place topology reconfiguration did not use exactly one COMMIT"
for command in '-F ZAPRET2_OUT' '-F ZAPRET2_IN'; do
    grep -Fqx -- "$command" "$FW/restore.payload.5" ||
        fail "in-place topology batch omitted: $command"
done
for forbidden in '-D OUTPUT -j ZAPRET2_OUT' '-X ZAPRET2_OUT' ':ZAPRET2_OUT - [0:0]' '-A OUTPUT -j ZAPRET2_OUT'; do
    ! grep -Fqx -- "$forbidden" "$FW/restore.payload.5" ||
        fail "in-place topology batch rebuilt stable ownership: $forbidden"
done
[ -f "$FW/anchor.out" ] && [ -f "$FW/anchor.in" ] ||
    fail "in-place topology reconfiguration disturbed stable anchors"
z2_fw_verify_family iptables 1 1 ||
    fail "in-place topology result did not verify"

# A rejected COMMIT is atomic and leaves the previous chain bytes intact.
cp "$FW/rules.out" "$FW/rules.out.before-reject"
cp "$FW/rules.in" "$FW/rules.in.before-reject"
PORTS_TCP=80,443,6568
Z2_RESTORE_FAIL_COMMIT=1
export Z2_RESTORE_FAIL_COMMIT
if z2_fw_reconfigure_family iptables 1 1; then
    fail "rejected in-place topology COMMIT reported success"
fi
cmp -s "$FW/rules.out" "$FW/rules.out.before-reject" &&
    cmp -s "$FW/rules.in" "$FW/rules.in.before-reject" ||
    fail "rejected in-place topology COMMIT changed published rules"
unset Z2_RESTORE_FAIL_COMMIT
rm -f "$FW/rules.out.before-reject" "$FW/rules.in.before-reject"
PORTS_TCP=80,443

z2_fw_cleanup_family iptables || fail "stable namespace cleanup failed"
z2_fw_cleanup_family iptables || fail "stable namespace cleanup is not idempotent"
z2_fw_family_absent iptables || fail "stable namespace remains after cleanup"

rm -f "$FW"/*
Z2_RESTORE_REJECT_CONNBYTES=1
export Z2_RESTORE_REJECT_CONNBYTES
z2_fw_reconcile_family iptables || fail "connbytes fallback reconcile failed"
[ "$Z2_FW_CONNBYTES:$Z2_FW_RULES:$Z2_FW_CHAINS:$Z2_FW_ANCHORS" = 0:2:1:1 ] ||
    fail "outgoing-only fallback metadata changed"
[ -f "$FW/anchor.out" ] && [ ! -f "$FW/anchor.in" ] ||
    fail "outgoing-only fallback published an input anchor"
case "$Z2_FW_FALLBACK_DETAIL" in
    *'connbytes match is unavailable'*) ;;
    *) fail "connbytes fallback diagnostic was not preserved" ;;
esac
unset Z2_RESTORE_REJECT_CONNBYTES
z2_fw_cleanup_family iptables || fail "fallback cleanup failed"

rm -f "$FW"/*
Z2_RESTORE_REJECT_CONNBYTES_COMMIT=1
export Z2_RESTORE_REJECT_CONNBYTES_COMMIT
z2_fw_reconcile_family iptables ||
    fail "commit-time kernel connbytes rejection did not fall back"
[ "$Z2_FW_CONNBYTES:$Z2_FW_RULES:$Z2_FW_CHAINS:$Z2_FW_ANCHORS" = 0:2:1:1 ] ||
    fail "commit-time connbytes fallback metadata changed"
[ -f "$FW/anchor.out" ] && [ ! -f "$FW/anchor.in" ] ||
    fail "commit-time connbytes fallback published an input anchor"
[ "$(cat "$FW/restore.count")" = 4 ] ||
    fail "commit-time connbytes fallback did not use one extra test and commit"
case "$Z2_FW_FALLBACK_DETAIL" in
    *'commit failed'*'connbytes revision 0 not supported'*) ;;
    *) fail "commit-time connbytes fallback diagnostic was not preserved" ;;
esac
unset Z2_RESTORE_REJECT_CONNBYTES_COMMIT
z2_fw_cleanup_family iptables || fail "commit-time fallback cleanup failed"

rm -f "$FW"/*
# The same kernel gap through a build that names nothing at COMMIT. Reported
# from the field as a refusal to start: the ruleset was called unsupported on
# a device that could have run the outgoing-only one.
Z2_RESTORE_REJECT_CONNBYTES_COMMIT=2
export Z2_RESTORE_REJECT_CONNBYTES_COMMIT
z2_fw_reconcile_family iptables ||
    fail "unnamed commit rejection did not fall back"
[ "$Z2_FW_CONNBYTES:$Z2_FW_RULES:$Z2_FW_CHAINS:$Z2_FW_ANCHORS" = 0:2:1:1 ] ||
    fail "unnamed commit fallback metadata changed"
[ -f "$FW/anchor.out" ] && [ ! -f "$FW/anchor.in" ] ||
    fail "unnamed commit fallback published an input anchor"
[ "$Z2_FW_MULTIPORT" = 1 ] ||
    fail "unnamed commit rejection also spent the multiport latch"
[ "$(cat "$FW/restore.count")" = 4 ] ||
    fail "unnamed commit fallback did not use one extra test and commit"
case "$Z2_FW_FALLBACK_DETAIL" in
    *'commit failed'*'line 10 failed'*) ;;
    *) fail "unnamed commit fallback diagnostic was not preserved" ;;
esac
unset Z2_RESTORE_REJECT_CONNBYTES_COMMIT
z2_fw_cleanup_family iptables || fail "unnamed commit fallback cleanup failed"

rm -f "$FW"/*
# A comparison that cannot run says nothing about the table it was meant to
# inspect, and the two used to be reported as the same failure.
z2_fw_reconcile_family iptables || fail "verifier probe publish failed"
Z2_MOCK_AWK_BROKEN=1
export Z2_MOCK_AWK_BROKEN
if z2_fw_verify_family iptables 1 1; then
    fail "a verification that never ran reported success"
fi
[ "$Z2_FW_VERIFY_CLASS" = VERIFIER_FAILED ] ||
    fail "an unrunnable verification was classed as a topology verdict"
case "$Z2_FW_VERIFY_DETAIL" in
    *'could not run'*'exit=2'*'cannot open shared library'*) ;;
    *) fail "an unrunnable verification discarded the verifier diagnostic" ;;
esac
unset Z2_MOCK_AWK_BROKEN
z2_fw_verify_family iptables 1 1 ||
    fail "verification failed once the verifier was available again"
[ -z "$Z2_FW_VERIFY_CLASS" ] ||
    fail "a reached verdict kept a failure class"
z2_fw_cleanup_family iptables || fail "verifier probe cleanup failed"

rm -f "$FW"/*
# End to end: publication succeeds, the verdict is unreachable, and the
# withdrawal that keeps the device clean needs the same missing verifier. The
# caller is told both facts.
z2_fw_capture_baseline iptables || fail "verifier transition baseline failed"
z2_fw_save_audit iptables || fail "verifier transition baseline was not retained"
Z2_MOCK_AWK_BROKEN=1
export Z2_MOCK_AWK_BROKEN
if z2_fw_reconcile_family iptables audited; then
    fail "a family nobody could verify was published as verified"
fi
[ "$Z2_FW_FAILURE_CLASS" = VERIFIER_FAILED ] ||
    fail "an unrunnable verification lost its failure class"
case "$Z2_FW_ERROR_DETAIL" in
    *'could not run'*'could not be withdrawn'*) ;;
    *) fail "a failed withdrawal after an unrunnable verification was not reported" ;;
esac
unset Z2_MOCK_AWK_BROKEN
z2_fw_cleanup_family iptables || fail "verifier failure cleanup failed"
z2_fw_family_absent iptables || fail "verifier failure left live firewall state"

rm -f "$FW"/*
Z2_RESTORE_WAIT_SUPPORTED=0
export Z2_RESTORE_WAIT_SUPPORTED
z2_fw_reset_restore_wait_capabilities
z2_fw_reconcile_family iptables || fail "legacy restore without --wait failed"
if grep -Fq -- '--wait' "$FW/restore.args"; then
    fail "legacy restore received unsupported --wait option"
fi
[ "$(cat "$FW/restore.count")" = 2 ] ||
    fail "legacy restore did not use one validation and one commit"
z2_fw_cleanup_family iptables || fail "legacy restore cleanup failed"

rm -f "$FW"/*
printf '%s\n' 2 > "$FW/lock.remaining"
z2_fw_lock_retry_pause() { :; }
z2_fw_reconcile_family iptables || fail "legacy xtables lock wait did not recover"
[ "$(cat "$FW/restore.count")" = 4 ] ||
    fail "legacy xtables lock wait did not retry only the two lock failures"
z2_fw_cleanup_family iptables || fail "legacy lock-wait cleanup failed"

rm -f "$FW"/*
printf '%s\n' 20 > "$FW/lock.remaining"
if z2_fw_reconcile_family iptables; then
    fail "exhausted legacy xtables lock wait was accepted"
fi
[ "$Z2_FW_FAILURE_CLASS" = LOCK_TIMEOUT ] ||
    fail "exhausted legacy xtables lock wait lost its failure class"
[ "$(cat "$FW/restore.count")" = 6 ] ||
    fail "legacy xtables lock wait was not bounded to five seconds"
z2_fw_family_absent iptables || fail "lock timeout left live firewall state"
unset Z2_RESTORE_WAIT_SUPPORTED
z2_fw_reset_restore_wait_capabilities

rm -f "$FW"/*
Z2_RESTORE_REJECT_ALL=1
export Z2_RESTORE_REJECT_ALL
if z2_fw_reconcile_family iptables; then
    fail "unsupported baseline ruleset was accepted"
fi
[ "$Z2_FW_FAILURE_CLASS" = RULESET_REJECTED ] ||
    fail "unsupported baseline ruleset lost its failure class"
case "$Z2_FW_ERROR_DETAIL" in
    *'test failed'*'vendor parser rejected ruleset'*)
        case "$Z2_FW_ERROR_DETAIL" in
            *"$(printf '\033')"*) fail "backend control character escaped normalization" ;;
        esac
        ;;
    *) fail "unsupported baseline ruleset diagnostic was discarded" ;;
esac
z2_fw_family_absent iptables || fail "unsupported baseline ruleset left live firewall state"
unset Z2_RESTORE_REJECT_ALL

rm -f "$FW"/*
# A COMMIT refused for a reason that is not a missing extension is
# indistinguishable from one that is: the backend says the same thing either
# way. The capability set is therefore exhausted before the failure is
# reported. The two attempts this costs are transactions the backend has
# already refused, so they cannot change the table, and the alternative is
# refusing to start on a kernel that only needed a poorer ruleset.
Z2_RESTORE_FAIL_COMMIT=1
export Z2_RESTORE_FAIL_COMMIT
if z2_fw_reconcile_family iptables; then
    fail "failed COMMIT was accepted"
fi
[ "$(cat "$FW/restore.count")" = 6 ] ||
    fail "failed COMMIT gave up before the capability set was exhausted"
z2_fw_family_absent iptables || fail "failed COMMIT left live firewall state"
[ "$Z2_FW_FAILURE_CLASS" = PUBLICATION_FAILED ] ||
    fail "failed COMMIT did not retain its failure class"
case "$Z2_FW_ERROR_DETAIL" in
    *'commit failed'*'vendor backend rejected COMMIT'*) ;;
    *) fail "failed COMMIT diagnostic was discarded" ;;
esac
unset Z2_RESTORE_FAIL_COMMIT

rm -f "$FW"/*
Z2_CORRUPT_AFTER_COMMIT=1
export Z2_CORRUPT_AFTER_COMMIT
if z2_fw_reconcile_family iptables; then
    fail "corrupted post-publication topology was accepted"
fi
[ "$Z2_FW_FAILURE_CLASS" = POSTCONDITION_FAILED ] ||
    fail "post-publication mismatch lost its failure class"
case "$Z2_FW_ERROR_DETAIL" in
    *'reason=OUT_RULE_COUNT:1'*) ;;
    *) fail "post-publication mismatch lost its typed reason: $Z2_FW_ERROR_DETAIL" ;;
esac
z2_fw_family_absent iptables ||
    fail "post-publication mismatch did not converge to absent state"
unset Z2_CORRUPT_AFTER_COMMIT

if find "$STATE" -maxdepth 1 -type f -name 'firewall-*' | grep -q .; then
    fail "firewall transaction left private temporary files"
fi

: > "$FW/chain.out"
: > "$FW/rules.out"
: > "$FW/anchor.out"
z2_fw_cleanup_family iptables || fail "interrupted publication did not converge to absent"
z2_fw_family_absent iptables || fail "interrupted publication retained stable state"

: > "$FW/chain.out"
: > "$FW/rules.out"
Z2_FOREIGN_REF=1
export Z2_FOREIGN_REF
if z2_fw_cleanup_family iptables; then
    fail "foreign reference to stable namespace was accepted"
fi
[ -f "$FW/chain.out" ] || fail "foreign-reference preflight partially mutated its chain"
unset Z2_FOREIGN_REF
z2_fw_cleanup_family iptables || fail "stable namespace did not recover after foreign reference disappeared"

# A kernel without xt_multiport rejects the batch while it is still parsing it.
# The port list has no single-rule form there, so each interval becomes its own
# rule, the published record stops claiming an extension that was never used,
# and verification has to accept the wider shape without letting anything
# foreign through.
z2_fw_cleanup_family iptables || fail "could not reset before the multiport case"
PORTS_TCP=80,443
PORTS_UDP=443:65535
Z2_RESTORE_REJECT_MULTIPORT=1
export Z2_RESTORE_REJECT_MULTIPORT
z2_fw_reconcile_family iptables ||
    fail "a kernel without multiport could not publish any ruleset at all"
[ "$Z2_FW_MULTIPORT" = 0 ] || fail "the published record still claims the multiport extension"
[ "$Z2_FW_CONNBYTES" = 1 ] ||
    fail "a multiport rejection spent the connbytes latch its diagnostic never names"
[ "$Z2_FW_RULES" = 6 ] ||
    fail "expected one rule per interval per direction, got $Z2_FW_RULES"
if grep -q -- '-m multiport' "$FW/rules.out"; then
    fail "the published ruleset still uses the extension the kernel rejected"
fi
grep -Fq -- '--dport 80 ' "$FW/rules.out" || fail "the 80 interval got no rule of its own"
grep -Fq -- '--dport 443 ' "$FW/rules.out" || fail "the 443 interval got no rule of its own"
grep -Fq -- '--dport 443:65535 ' "$FW/rules.out" || fail "the UDP range was not published"
z2_fw_verify_family iptables "$Z2_FW_CONNBYTES" "$Z2_FW_MULTIPORT" ||
    fail "the split ruleset did not verify"
cp "$FW/rules.out" "$FW/rules.out.split"
printf '%s\n' '-A ZAPRET2_OUT -p tcp --dport 8080 -j RETURN' >> "$FW/rules.out"
if z2_fw_verify_family iptables "$Z2_FW_CONNBYTES" "$Z2_FW_MULTIPORT"; then
    fail "a foreign rule was accepted once the ruleset was split per interval"
fi
mv "$FW/rules.out.split" "$FW/rules.out"
unset Z2_RESTORE_REJECT_MULTIPORT

# Same kernel gap, different iptables build. 1.8.4 legacy names the extension
# and nothing else, which is what a v2.3.0 device reported as a hard start
# failure: the wording carried no second signal, so the fallback never ran and
# the user was told the ruleset was unsupported.
z2_fw_cleanup_family iptables || fail "could not reset before the 1.8.4 multiport case"
PORTS_TCP=80,443
PORTS_UDP=443:65535
Z2_RESTORE_REJECT_MULTIPORT=2
export Z2_RESTORE_REJECT_MULTIPORT
z2_fw_reconcile_family iptables ||
    fail "a 1.8.4 kernel without multiport could not publish any ruleset"
[ "$Z2_FW_MULTIPORT" = 0 ] || fail "1.8.4 multiport rejection did not retire the extension"
[ "$Z2_FW_CONNBYTES" = 1 ] ||
    fail "the 1.8.4 multiport rejection spent the connbytes latch"
if grep -q -- '-m multiport' "$FW/rules.out"; then
    fail "the published ruleset still uses the extension 1.8.4 could not find"
fi
z2_fw_verify_family iptables "$Z2_FW_CONNBYTES" "$Z2_FW_MULTIPORT" ||
    fail "the 1.8.4 fallback ruleset did not verify"
unset Z2_RESTORE_REJECT_MULTIPORT

# A build that names nothing must still end up with a published ruleset: the
# capability set is small and finite, so it is exhausted rather than guessed at.
z2_fw_cleanup_family iptables || fail "could not reset before the unnamed rejection case"
Z2_RESTORE_REJECT_MULTIPORT=3
export Z2_RESTORE_REJECT_MULTIPORT
z2_fw_reconcile_family iptables ||
    fail "an unnamed multiport rejection could not publish any ruleset"
[ "$Z2_FW_MULTIPORT" = 0 ] || fail "an unnamed rejection kept the extension"
if grep -q -- '-m multiport' "$FW/rules.out"; then
    fail "the published ruleset still uses the extension the backend refused"
fi
z2_fw_verify_family iptables "$Z2_FW_CONNBYTES" "$Z2_FW_MULTIPORT" ||
    fail "the exhausted-capability ruleset did not verify"
unset Z2_RESTORE_REJECT_MULTIPORT

# The 15-value limit is a userspace parser rule, not a kernel capability, so a
# list that cannot fit never reaches the backend as a multiport rule at all —
# there is nothing to reject and nothing to fall back from.
z2_fw_cleanup_family iptables || fail "could not reset before the port limit case"
PORTS_TCP=1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16
PORTS_UDP=443
: > "$FW/restore.count"
printf '0\n' > "$FW/restore.count"
z2_fw_reconcile_family iptables || fail "an oversized port list could not publish"
[ "$Z2_FW_MULTIPORT" = 0 ] || fail "a port list past the limit was still offered to multiport"
[ "$(grep -c -- '-A ZAPRET2_OUT ' "$FW/rules.out")" = 17 ] ||
    fail "an oversized list did not become one rule per interval"
[ "$(cat "$FW/restore.count")" = 2 ] ||
    fail "the limit was discovered by rejection instead of being computed"

# A range spends two of the fifteen. Eight ranges are eight intervals but weigh
# sixteen, so counting intervals instead of values would wrongly keep multiport.
z2_fw_cleanup_family iptables || fail "could not reset before the range weight case"
PORTS_TCP=1:2,3:4,5:6,7:8,9:10,11:12,13:14,15:16
PORTS_UDP=443
z2_fw_reconcile_family iptables || fail "eight ranges could not publish"
[ "$Z2_FW_MULTIPORT" = 0 ] || fail "a range was counted as one value instead of two"

# Some extensions have no alternative. Without the mark match the module would
# re-queue the packets it reinjects itself, so refusing is the only correct
# answer — but the refusal has to say which extension is missing instead of
# handing the user several lines of backend warnings to interpret.
z2_fw_cleanup_family iptables || fail "could not reset before the required extension case"
PORTS_TCP=80,443
PORTS_UDP=443
Z2_RESTORE_REJECT_MARK=1
export Z2_RESTORE_REJECT_MARK
if z2_fw_reconcile_family iptables; then
    fail "a kernel without the mark match still published a ruleset"
fi
case "$Z2_FW_ERROR_DETAIL" in
    *'does not provide the mark extension'*) ;;
    *) fail "the missing extension was not named: $Z2_FW_ERROR_DETAIL" ;;
esac
z2_fw_family_absent iptables ||
    fail "a refused required extension left owned objects behind"
unset Z2_RESTORE_REJECT_MARK

# With the extension present and the list within the limit nothing changes.
z2_fw_cleanup_family iptables || fail "could not reset before the unchanged case"
PORTS_TCP=80,443
PORTS_UDP=443:65535
z2_fw_reconcile_family iptables || fail "a kernel with multiport failed to publish"
[ "$Z2_FW_MULTIPORT" = 1 ] || fail "multiport was abandoned on a kernel that supports it"
[ "$Z2_FW_RULES" = 4 ] || fail "the multiport ruleset changed shape"
grep -q -- '-m multiport' "$FW/rules.out" ||
    fail "the extension was not used where it is available"
z2_fw_cleanup_family iptables || fail "could not tear down after the multiport cases"

# Tethering capture reuses the two owned chains and their rules verbatim: a
# forwarded client request is the same original-direction, destination-port
# match the local one is, and its reply is the same reply-direction,
# source-port match. Only the anchors differ, so the published rule count must
# not move while the anchor count doubles.
PORTS_TCP=80,443
PORTS_UDP=443
TETHERING=1
z2_fw_reconcile_family iptables || fail "tethering capture could not publish"
[ "$Z2_FW_BACKEND:$Z2_FW_CONNBYTES:$Z2_FW_RULES:$Z2_FW_CHAINS:$Z2_FW_ANCHORS" = restore:1:4:2:4 ] ||
    fail "tethering capture changed something other than the anchor count"
[ -f "$FW/anchor.fwd.out" ] && [ -f "$FW/anchor.fwd.in" ] ||
    fail "tethering capture did not anchor both chains into FORWARD"
[ -f "$FW/anchor.out" ] && [ -f "$FW/anchor.in" ] ||
    fail "tethering capture dropped the built-in anchors"
[ "$(grep -c -- '-A ZAPRET2_OUT ' "$FW/rules.out")" = 2 ] ||
    fail "tethering capture authored extra rules instead of extra anchors"
z2_fw_verify_family iptables 1 || fail "the tethered topology did not verify"

# The setting is a published property of the generation, not of the process
# reading it: verifying a tethered generation as an untethered one must fail
# with the anchor reason rather than silently accept the extra anchors.
TETHERING=0
if z2_fw_verify_family iptables 1; then
    fail "a tethered topology verified as an untethered one"
fi
case "$Z2_FW_VERIFY_DETAIL" in
    *'reason=FORWARD_OUT_ANCHOR_COUNT:1'*) ;;
    *) fail "the extra anchor lost its typed reason: $Z2_FW_VERIFY_DETAIL" ;;
esac

# Teardown answers to the baseline it captured, never to the current setting,
# so turning tethering off must still remove the anchors it published.
z2_fw_cleanup_family iptables || fail "tethering anchors could not be torn down"
z2_fw_family_absent iptables || fail "tethering anchors survived teardown"
[ ! -f "$FW/anchor.fwd.out" ] && [ ! -f "$FW/anchor.fwd.in" ] ||
    fail "teardown left a FORWARD anchor behind"

# Anchors are not part of a reconfiguration batch, so a generation whose
# tethering setting changed must not take that path at all.
TETHERING=1
z2_fw_reconcile_family iptables || fail "could not republish the tethered topology"
TETHERING=bogus
set +e
z2_fw_reconfigure_family iptables 1 1
rc=$?
set -e
[ "$rc" = 2 ] || fail "an invalid tethering setting was accepted as a topology"
TETHERING=0
z2_fw_cleanup_family iptables || fail "could not tear down after the tethering cases"
unset TETHERING

z2_fw_restore_command_read() { Z2_FW_RESTORE_COMMAND=missing-iptables-restore; }
set +e
z2_fw_reconcile_family iptables
rc=$?
set -e
[ "$rc" = 3 ] || fail "missing restore backend did not return capability status"
z2_fw_family_absent iptables || fail "missing restore backend mutated firewall state"

echo "Firewall reconciler shell tests passed"
