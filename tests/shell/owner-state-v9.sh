#!/bin/sh
set -eu

# The case overrides chmod, so the private state directory can only get its
# mode from the creating umask. A host that leaves group write on new
# directories would otherwise fail the state-security preflight before the
# first record is ever written.
umask 077

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=${Z2_TEST_TMP:?}
CASE="$TMP/owner-state-v9"
MOD="$CASE/module"
STATE="$CASE/state"
MOCK="$CASE/bin"
BOOT_A=11111111-1111-1111-1111-111111111111
BOOT_B=22222222-2222-2222-2222-222222222222

fail() { echo "FAIL: owner-state-v9: $*" >&2; exit 1; }
REAL_CHMOD=$(command -v chmod)
chmod() { :; }
sync() { :; }
sha256sum() { cat >/dev/null; echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
mkdir -p "$MOD/zapret2/scripts" "$STATE" "$MOCK"
chmod 0700 "$STATE"
cp "$ROOT/zapret2/scripts/common.sh" "$MOD/zapret2/scripts/common.sh"
: > "$MOD/zapret2/nfqws2"
cat > "$MOD/zapret2/install-generation.meta" <<EOF
version=1
module_dir=$MOD
generation=owner-v9-install
archive_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
chmod 0600 "$MOD/zapret2/install-generation.meta"
cat > "$MOCK/iptables" <<'EOF'
#!/bin/sh
exit 0
EOF
"$REAL_CHMOD" 0755 "$MOCK/iptables"

export STATE_DIR="$STATE" SCRIPT_DIR="$MOD/zapret2/scripts" ZAPRET_DIR="$MOD/zapret2" MODDIR="$MOD" PATH="$MOCK:$PATH"
. "$SCRIPT_DIR/common.sh"
state_file_is_secure() { [ -f "$1" ]; }
path_mode_is_0600() { :; }
path_uid_is_root() { :; }
path_nlink_is_one() { :; }
state_file_target_is_safe() { [ ! -L "$1" ]; }
Z2_TEST_CURRENT_BOOT="$BOOT_A"
Z2_TEST_PROCESS=dead
Z2_TEST_SCAN=clean
Z2_TEST_FIREWALL=absent
Z2_TEST_LOCKED=0
read_current_boot_id() {
    [ "${Z2_TEST_BOOT_QUERY:-ok}" = ok ] || return 1
    CURRENT_BOOT_ID="$Z2_TEST_CURRENT_BOOT"
}
verify_nfqws_pid() { [ "$Z2_TEST_PROCESS" = live ]; }
scan_exact_owned_nfqws() {
    OWNED_SCAN_PIDS=""
    case "$Z2_TEST_SCAN" in
        clean) return 0 ;;
        live) OWNED_SCAN_PIDS=123; return 0 ;;
        *) return 1 ;;
    esac
}
owned_family_present() {
    case "$Z2_TEST_FIREWALL" in absent) return 1;; present) return 0;; *) return 2;; esac
}
caller_holds_exact_lifecycle_lock() { [ "$Z2_TEST_LOCKED" = 1 ]; }

QNUM=200; PORTS_TCP=80,443; PORTS_UDP=443; TCP_PKT_OUT=20; TCP_PKT_IN=10; UDP_PKT_OUT=20; UDP_PKT_IN=10; PKT_OUT=20; PKT_IN=10; DESYNC_MARK=0x40000000
FIREWALL_TAG=AbCdEf1234; ZAPRET2_OUT=Z2O_AbCdEf1234; ZAPRET2_IN=Z2I_AbCdEf1234; PENDING_OWNER_GENERATION=owner-v9
IPV4_CONNBYTES=1; IPV4_MULTIPORT=1; IPV4_MARK=1; IPV6_CONNBYTES=1; IPV6_MULTIPORT=1; IPV6_MARK=1
ARGV_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
prepare_owner_generation_spec 1 0 || fail "could not prepare canonical owner generation"
write_owner_state 123 456 "$ARGV_SHA256" 200 owner-v9 active || fail "could not write v9 owner"
chmod 0600 "$OWNER_STATE"
cp "$OWNER_STATE" "$CASE/owner.v9"

[ "$(sed -n '1p' "$CASE/owner.v9")" = version=9 ] || fail "writer did not publish v9"
# Android's awk rejects a bare conditional as a printf argument.
[ "$(awk -F= '{ printf "%s%s", (NR==1?"":"|"), $1 }' "$CASE/owner.v9")" = "$OWNER_STATE_V9_FIELD_SEQUENCE" ] || fail "v9 field order is not canonical"
grep -Fqx "boot_id=$BOOT_A" "$CASE/owner.v9" || fail "writer did not bind current boot"
grep -Fqx "argv_sha256=$ARGV_SHA256" "$CASE/owner.v9" || fail "writer did not publish the command digest"
[ "$(wc -c < "$CASE/owner.v9")" -lt 4096 ] || fail "v9 owner metadata is not compact"
OWNER_WRITE_QNUM=""; OWNER_WRITE_PORTS_TCP=""; OWNER_WRITE_PORTS_UDP=""; OWNER_WRITE_STUN_PORTS=""
OWNER_WRITE_TCP_PKT_OUT=""; OWNER_WRITE_TCP_PKT_IN=""; OWNER_WRITE_UDP_PKT_OUT=""; OWNER_WRITE_UDP_PKT_IN=""; OWNER_WRITE_DESYNC_MARK=""; OWNER_WRITE_READY=0
read_owner_state && owner_state_is_current_boot || fail "v9 write/read round trip failed"
# Reload every generation field from the parsed owner state so the rewrite
# below must reproduce the committed record byte for byte.
OWNER_WRITE_QNUM="$OWNER_STATE_QNUM"; OWNER_WRITE_PORTS_TCP="$OWNER_STATE_PORTS_TCP"; OWNER_WRITE_PORTS_UDP="$OWNER_STATE_PORTS_UDP"; OWNER_WRITE_STUN_PORTS="$OWNER_STATE_STUN_PORTS"
OWNER_WRITE_FIREWALL_TAG="$OWNER_STATE_FIREWALL_TAG"; OWNER_WRITE_OUT_CHAIN="$OWNER_STATE_OUT_CHAIN"; OWNER_WRITE_IN_CHAIN="$OWNER_STATE_IN_CHAIN"
OWNER_WRITE_TETHERING="$OWNER_STATE_TETHERING"
FIREWALL_TAG="$OWNER_STATE_FIREWALL_TAG"; ZAPRET2_OUT="$OWNER_STATE_OUT_CHAIN"; ZAPRET2_IN="$OWNER_STATE_IN_CHAIN"
OWNER_WRITE_TCP_PKT_OUT="$OWNER_STATE_TCP_PKT_OUT"; OWNER_WRITE_TCP_PKT_IN="$OWNER_STATE_TCP_PKT_IN"
OWNER_WRITE_UDP_PKT_OUT="$OWNER_STATE_UDP_PKT_OUT"; OWNER_WRITE_UDP_PKT_IN="$OWNER_STATE_UDP_PKT_IN"
OWNER_WRITE_DESYNC_MARK="$OWNER_STATE_DESYNC_MARK"
OWNER_WRITE_IPV4_ACTIVE="$OWNER_STATE_IPV4_ACTIVE"; OWNER_WRITE_IPV6_ACTIVE="$OWNER_STATE_IPV6_ACTIVE"
OWNER_WRITE_IPV4_CONNBYTES="$OWNER_STATE_IPV4_CONNBYTES"; OWNER_WRITE_IPV4_MULTIPORT="$OWNER_STATE_IPV4_MULTIPORT"; OWNER_WRITE_IPV4_MARK="$OWNER_STATE_IPV4_MARK"
OWNER_WRITE_IPV6_CONNBYTES="$OWNER_STATE_IPV6_CONNBYTES"; OWNER_WRITE_IPV6_MULTIPORT="$OWNER_STATE_IPV6_MULTIPORT"; OWNER_WRITE_IPV6_MARK="$OWNER_STATE_IPV6_MARK"
OWNER_WRITE_IPV4_RULES="$OWNER_STATE_IPV4_RULES"; OWNER_WRITE_IPV6_RULES="$OWNER_STATE_IPV6_RULES"; OWNER_WRITE_IPV4_SPEC="$OWNER_STATE_IPV4_SPEC"; OWNER_WRITE_IPV6_SPEC="$OWNER_STATE_IPV6_SPEC"
OWNER_WRITE_FIREWALL_FINGERPRINT="$OWNER_STATE_FIREWALL_FINGERPRINT"; OWNER_WRITE_INSTALL_GENERATION="$OWNER_STATE_INSTALL_GENERATION"; OWNER_WRITE_INSTALL_ARCHIVE_SHA256="$OWNER_STATE_INSTALL_ARCHIVE_SHA256"; OWNER_WRITE_SOURCE_GENERATION="$OWNER_STATE_GENERATION"; OWNER_WRITE_READY=1
write_owner_state 123 456 "$ARGV_SHA256" 200 owner-v9 active || fail "canonical owner rewrite failed"
cmp -s "$CASE/owner.v9" "$OWNER_STATE" || fail "v9 byte-for-byte round trip changed"
oversized_generation="$(awk 'BEGIN { for (i=0; i<65536; i++) printf "a" }')"
if write_owner_state 123 456 "$ARGV_SHA256" 200 "$oversized_generation" active; then
    fail "oversized v9 owner metadata was published"
fi
cmp -s "$CASE/owner.v9" "$OWNER_STATE" || fail "rejected oversized owner changed the committed record"

# xt_connbytes is optional on Android kernels. The authenticated v9 owner
# contract represents upstream's outgoing-only KEEPALIVE topology with
# connbytes=0 and exactly one direction worth of payload rules.
IPV4_CONNBYTES=0
prepare_owner_generation_spec 1 0 || fail "could not prepare connbytes fallback owner generation"
[ "$OWNER_WRITE_IPV4_RULES" = 2 ] || fail "connbytes fallback owner rule count is not outgoing-only"
write_owner_state 123 456 "$ARGV_SHA256" 200 owner-v9-fallback active ||
    fail "could not write connbytes fallback owner"
chmod 0600 "$OWNER_STATE"
read_owner_state && owner_state_is_current_boot || fail "connbytes fallback owner round trip failed"
[ "$OWNER_STATE_IPV4_CONNBYTES:$OWNER_STATE_IPV4_RULES" = 0:2 ] ||
    fail "connbytes fallback owner topology changed after read"
IPV4_CONNBYTES=1
cp "$CASE/owner.v9" "$OWNER_STATE"; chmod 0600 "$OWNER_STATE"
read_owner_state && owner_state_is_current_boot || fail "canonical owner was not restored after fallback test"

# Tethering capture is a published property of the generation, so it travels in
# the record and in both family specs. The specs are what the fingerprint is
# taken over, so two capture topologies must not produce the same pair. (The
# digest itself is stubbed in this case, so the specs are compared directly.)
untethered_ipv4_spec="$OWNER_STATE_IPV4_SPEC"
untethered_ipv6_spec="$OWNER_STATE_IPV6_SPEC"
TETHERING=1
prepare_owner_generation_spec 1 0 || fail "could not prepare a tethered owner generation"
[ "$OWNER_WRITE_TETHERING" = 1 ] || fail "the tethered generation did not record its topology"
case "$OWNER_WRITE_IPV4_SPEC" in
    *';tethering:1;'*) ;;
    *) fail "the family spec omitted the capture topology" ;;
esac
[ "$OWNER_WRITE_IPV4_SPEC" != "$untethered_ipv4_spec" ] &&
    [ "$OWNER_WRITE_IPV6_SPEC" != "$untethered_ipv6_spec" ] ||
    fail "two different capture topologies share one family specification"
write_owner_state 123 456 "$ARGV_SHA256" 200 owner-v9-tethered active ||
    fail "could not write a tethered owner"
chmod 0600 "$OWNER_STATE"
read_owner_state && owner_state_is_current_boot || fail "tethered owner round trip failed"
[ "$OWNER_STATE_TETHERING" = 1 ] || fail "tethered topology changed after read"
TETHERING=0
cp "$CASE/owner.v9" "$OWNER_STATE"; chmod 0600 "$OWNER_STATE"
read_owner_state && owner_state_is_current_boot || fail "canonical owner was not restored after the tethering test"

assert_owner_rejected() {
    candidate="$1"
    cp "$candidate" "$OWNER_STATE"; chmod 0600 "$OWNER_STATE"
    if read_owner_state; then fail "malformed owner was accepted: $candidate"; fi
}
sed '/^firewall_tag=/d' "$CASE/owner.v9" > "$CASE/missing"
sed 's/^firewall_tag=.*/firewall_tag=unsafe!/' "$CASE/owner.v9" > "$CASE/malformed"
sed 's/^out_chain=.*/out_chain=Z2O_wrongchain/' "$CASE/owner.v9" > "$CASE/bad-out-chain"
sed 's/^in_chain=.*/in_chain=Z2I_wrongchain/' "$CASE/owner.v9" > "$CASE/bad-in-chain"
sed 's/^tethering=.*/tethering=2/' "$CASE/owner.v9" > "$CASE/bad-tethering"
sed 's/^argv_sha256=.*/argv_sha256=ABCDEF/' "$CASE/owner.v9" > "$CASE/bad-argv-digest"
sed '/^firewall_tag=/p' "$CASE/owner.v9" > "$CASE/duplicate"
cp "$CASE/owner.v9" "$CASE/unknown"; printf 'future=value\n' >> "$CASE/unknown"
for candidate in "$CASE/missing" "$CASE/malformed" "$CASE/bad-out-chain" "$CASE/bad-in-chain" "$CASE/bad-tethering" "$CASE/bad-argv-digest" "$CASE/duplicate" "$CASE/unknown"; do
    chmod 0600 "$candidate"; assert_owner_rejected "$candidate"
done

reset_case() {
    cp "$1" "$OWNER_STATE"; chmod 0600 "$OWNER_STATE"
    rm -f "$PIDFILE"
    Z2_TEST_PROCESS=dead; Z2_TEST_SCAN=clean; Z2_TEST_FIREWALL=absent
    Z2_TEST_LOCKED=0; Z2_TEST_BOOT_QUERY=ok; Z2_TEST_CURRENT_BOOT="$BOOT_A"
}
assert_preserved_failure() {
    if recover_stale_owner_publication; then fail "$1 unexpectedly succeeded"; fi
    [ -f "$OWNER_STATE" ] || fail "$1 retired owner evidence"
}

reset_case "$CASE/owner.v9"; Z2_TEST_PROCESS=live
recover_stale_owner_publication || fail "same-boot live v9 was not recognized"
[ -f "$OWNER_STATE" ] || fail "same-boot live owner was retired"

# A modules_update installer loads helpers from a candidate path while owner v9
# still names the canonical live binary.  The audit-local override authenticates
# that live publication without mutating the staged NFQWS2 global on either
# success or failure.
reset_case "$CASE/owner.v9"; Z2_TEST_PROCESS=live
live_nfqws="$MOD/zapret2/nfqws2"; staged_nfqws="$CASE/staged/zapret2/nfqws2"
NFQWS2="$staged_nfqws"
audit_recovery_artifacts install "$live_nfqws" || fail "live-path install audit rejected exact running owner"
[ "$NFQWS2" = "$staged_nfqws" ] || fail "successful live-path audit leaked its override"
Z2_TEST_PROCESS=dead
if audit_recovery_artifacts install "$live_nfqws"; then fail "live-path audit accepted same-boot dead owner"; fi
[ "$NFQWS2" = "$staged_nfqws" ] || fail "failed live-path audit leaked its override"
NFQWS2="$live_nfqws"

reset_case "$CASE/owner.v9"
assert_preserved_failure "same-boot dead v9"
reset_case "$CASE/owner.v9"; Z2_TEST_CURRENT_BOOT="$BOOT_B"; Z2_TEST_SCAN=live
assert_preserved_failure "cross-boot live v9"
reset_case "$CASE/owner.v9"; Z2_TEST_CURRENT_BOOT="$BOOT_B"; Z2_TEST_LOCKED=1
printf 'status=ok\n' > "$STATUS_SNAPSHOT"; chmod 0600 "$STATUS_SNAPSHOT"
BOOT_STALE_RUNTIME_RECOVERY=1
recover_stale_owner_publication || fail "locked clean cross-boot retirement failed"
[ ! -e "$OWNER_STATE" ] || fail "locked clean cross-boot owner was retained"
[ ! -e "$STATUS_SNAPSHOT" ] || fail "locked clean cross-boot status was retained"
[ "$STALE_OWNER_PUBLICATION_RETIRED" = 1 ] || fail "cross-boot retirement was not reported"
BOOT_STALE_RUNTIME_RECOVERY=0
echo "Owner state v9 shell tests passed"
