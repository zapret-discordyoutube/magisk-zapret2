#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
CASE="${Z2_TEST_TMP:?}/status-snapshot-fast-path"
STATE="$CASE/state"
MODULE="$CASE/module"
OUTPUT="$CASE/status.out"

fail() { echo "FAIL: status-snapshot-fast-path: $*" >&2; exit 1; }

mkdir -p "$STATE" "$MODULE"
chmod 0700 "$STATE"
cp "$ROOT/zapret2/runtime.ini" "$MODULE/runtime.ini"
cp "$(command -v sleep)" "$MODULE/nfqws2"
chmod 0755 "$MODULE/nfqws2"

"$MODULE/nfqws2" 30 &
NFQWS_PID=$!
trap 'kill "$NFQWS_PID" 2>/dev/null || true; wait "$NFQWS_PID" 2>/dev/null || true' EXIT

NFQWS_START=$(awk '{print $22}' "/proc/$NFQWS_PID/stat")
NFQWS_ARGV_SHA=$(sha256sum "/proc/$NFQWS_PID/cmdline")
NFQWS_ARGV_SHA=${NFQWS_ARGV_SHA%% *}
printf '%s\n' "$NFQWS_PID" > "$STATE/nfqws2.pid"
chmod 0600 "$STATE/nfqws2.pid"

write_snapshot() {
    argv_sha="$1"
    cat > "$STATE/status.snapshot" <<EOF
status=ok
boot_id=$(cat /proc/sys/kernel/random/boot_id)
rules_total=2
own_pid=$NFQWS_PID
own_pid_starttime=$NFQWS_START
own_argv_sha256=$argv_sha
owner_generation=status-fast-path
owner_metadata_verified=1
ruleset_verified=1
rules_expected=2
qnum=200
ipv4_active=1
ipv6_active=0
ipv4_rules=2
ipv6_rules=0
chains=1
anchors=1
nfqueue_supported=1
queue_bypass_supported=1
connbytes_supported=0
multiport_supported=1
mark_supported=1
error_schema=1
error_status=OK
error_domain=NONE
error_code=NONE
error_stage=NONE
error_detail=
EOF
    chmod 0600 "$STATE/status.snapshot"
}

run_status() {
    rc=0
    STATE_DIR="$STATE" MODDIR="$CASE" ZAPRET_DIR="$MODULE" \
        sh "$ROOT/zapret2/scripts/zapret-status.sh" --machine-v6 > "$OUTPUT" 2>&1 || rc=$?
}

write_snapshot "$NFQWS_ARGV_SHA"
run_status
[ "$rc" -eq 0 ] || fail "valid snapshot returned $rc"
grep -Fxq 'Z2_STATUS=ok' "$OUTPUT" || fail "valid snapshot was not accepted"
grep -Fxq 'Z2_PID_VERIFIED=1' "$OUTPUT" || fail "live process identity was not verified"
grep -Fxq 'Z2_CHAINS=1' "$OUTPUT" || fail "published chain count was not projected"

write_snapshot 0000000000000000000000000000000000000000000000000000000000000000
run_status
[ "$rc" -eq 2 ] || fail "mismatched command digest returned $rc instead of degraded"
grep -Fxq 'Z2_STATUS=degraded' "$OUTPUT" ||
    fail "mismatched command digest did not fail closed"
grep -Fxq 'Z2_PID_VERIFIED=0' "$OUTPUT" ||
    fail "mismatched command digest retained verified process state"

# A snapshot describes processes and netfilter objects that a reboot destroys,
# so one stamped with another boot must be rejected whole: no facts from it may
# reach the projection, not even the capability flags or the queue number.
write_snapshot "$NFQWS_ARGV_SHA"
sed 's/^boot_id=.*/boot_id=11111111-1111-1111-1111-111111111111/' \
    "$STATE/status.snapshot" > "$STATE/status.snapshot.foreign"
mv "$STATE/status.snapshot.foreign" "$STATE/status.snapshot"
chmod 0600 "$STATE/status.snapshot"
run_status
grep -Fxq 'Z2_STATUS=ok' "$OUTPUT" && fail "a snapshot from another boot was accepted"
grep -Fxq 'Z2_QNUM=200' "$OUTPUT" || fail "queue number leaked from the rejected snapshot"
grep -Fxq 'Z2_EXPECTED_RULES=0' "$OUTPUT" ||
    fail "expected rule count leaked from the rejected snapshot"
grep -Fxq 'Z2_NFQUEUE=0' "$OUTPUT" ||
    fail "capability facts leaked from the rejected snapshot"

# The pre-2.2.0 format carries no boot binding at all and is equally stale.
grep -v '^boot_id=' "$STATE/status.snapshot" > "$STATE/status.snapshot.legacy"
mv "$STATE/status.snapshot.legacy" "$STATE/status.snapshot"
chmod 0600 "$STATE/status.snapshot"
run_status
grep -Fxq 'Z2_STATUS=ok' "$OUTPUT" && fail "an unbound legacy snapshot was accepted"

echo "Status snapshot fast-path tests passed"
