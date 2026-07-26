#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
if [ -n "${Z2_TEST_WORKDIR:-}" ]; then
    TMP="$Z2_TEST_WORKDIR"
else
    test_tmp_base="${Z2_TEST_TMP:-${TMPDIR:-/tmp}}"
    mkdir -p "$test_tmp_base"
    TMP=$(mktemp -d "$test_tmp_base/zapret2-shell-tests.XXXXXX")
fi
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "$1 unexpectedly contains: $2"; }
assert_fails() { "$@" >/dev/null 2>&1 && fail "command unexpectedly succeeded: $*"; return 0; }

# Android's platform tools are not a GNU userland, while ASH_STANDALONE bypasses
# PATH and makes command mocks ineffective. Run the suite under the root
# manager's ash with its applets exposed as ordinary PATH entries. The marker
# also prevents common.sh from re-executing a test that sources it.
if [ "${Z2_TEST_BUSYBOX_READY:-0}" != 1 ]; then
    test_busybox=""
    for candidate in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox \
        /data/adb/ap/bin/busybox; do
        if [ -x "$candidate" ] && [ ! -L "$candidate" ]; then
            test_busybox="$candidate"
            break
        fi
    done
    if [ -n "$test_busybox" ]; then
        test_busybox_runtime="$TMP/busybox-runtime"
        test_busybox_path="$TMP/busybox-applets"
        mkdir -p "$test_busybox_runtime" "$test_busybox_path"
        cp "$test_busybox" "$test_busybox_runtime/busybox"
        chmod 0755 "$test_busybox_runtime/busybox"
        "$test_busybox_runtime/busybox" --install -s "$test_busybox_path" ||
            fail "could not expose busybox applets for Android tests"
        unset ASH_STANDALONE
        Z2_TEST_BUSYBOX_READY=1 Z2_TEST_WORKDIR="$TMP" Z2_RESHELLED=1 \
            Z2_TEST_BUSYBOX_BINARY="$test_busybox_runtime/busybox" \
            PATH="$test_busybox_path:$PATH" \
            exec "$test_busybox_runtime/busybox" sh "$0" "$@"
    fi
fi
unset ASH_STANDALONE
Z2_RESHELLED=1
export Z2_RESHELLED

# Process-identity fixtures need a normal executable shell. A copied busybox
# multicall binary dispatches on the synthetic "nfqws2" argv[0] and exits
# before the identity checks can run.
if [ -z "${Z2_TEST_EXECUTABLE_SHELL:-}" ]; then
    if [ -x /system/bin/sh ]; then
        Z2_TEST_EXECUTABLE_SHELL=/system/bin/sh
    else
        Z2_TEST_EXECUTABLE_SHELL="$(command -v sh)"
    fi
fi
export Z2_TEST_EXECUTABLE_SHELL
if [ -z "${Z2_TEST_ALTERNATE_BINARY:-}" ] && [ -x /system/bin/toybox ]; then
    Z2_TEST_ALTERNATE_BINARY=/system/bin/toybox
    export Z2_TEST_ALTERNATE_BINARY
fi

assert_unsafe_machine_root() {
    operation="$1" expected="$2" output="" rc=0
    output="$(sh "$ROOT/zapret2/scripts/command-builder.sh" "$operation" relative-root 2>&1)" || rc=$?
    [ "$rc" -eq 2 ] || fail "$operation unsafe-root rejection did not exit 2"
    [ "$output" = "$(printf '%s\tUNSAFE_ROOT' "$expected")" ] ||
        fail "$operation unsafe-root record is not protocol-specific"
}

[ "$(id -u)" = 0 ] || fail "run as root so ownership checks are real"

assert_unsafe_machine_root --scan-presets-machine Z2_PRESET_ERROR
assert_unsafe_machine_root --list-presets-machine Z2_PRESET_ERROR
assert_unsafe_machine_root --validate-preset-machine Z2_PRESET_ERROR
assert_unsafe_machine_root --preflight-preset-machine Z2_PRESET_ERROR
assert_unsafe_machine_root --preview-preset-machine Z2_PRESET_ERROR
assert_unsafe_machine_root --validate-strategies-machine Z2_STRATEGIES_ERROR

for script in "$ROOT"/*.sh "$ROOT"/zapret2/scripts/*.sh \
    "$ROOT"/zapret2/scripts/lifecycle/*.sh "$ROOT"/tests/shell/*.sh; do
    case "$(sed -n '1p' "$script")" in
        *bash*)
            if command -v bash >/dev/null 2>&1; then
                bash -n "$script" || fail "syntax: $script"
            elif [ "$script" != "$ROOT/build.sh" ]; then
                fail "bash is required for syntax check: $script"
            fi
            ;;
        *) sh -n "$script" || fail "syntax: $script" ;;
    esac
done

# Process, firewall, owner, status, and recovery evidence in STATE_DIR is
# boot-local. A global sync here flushes unrelated Android filesystems and
# turns the number of firewall journal transitions into boot latency.
for script in "$ROOT/zapret2/scripts/common.sh" "$ROOT/zapret2/scripts/zapret-start.sh"; do
    if sed '/^[[:space:]]*#/d' "$script" |
       grep -Eq '(^|[;&|[:space:]])sync([;&|[:space:]]|$)'; then
        fail "boot-local lifecycle script invokes global sync: $script"
    fi
done

for retired in \
    "$ROOT/zapret2/config.sh" \
    "$ROOT/zapret2/categories.ini" \
    "$ROOT/zapret2/strategies-tcp.ini" \
    "$ROOT/zapret2/strategies-udp.ini" \
    "$ROOT/zapret2/strategies-stun.ini" \
    "$ROOT/zapret2/blobs.txt" \
    "$ROOT/zapret2/scripts/runtime-migrate.sh"; do
    [ ! -e "$retired" ] && [ ! -L "$retired" ] || fail "retired file remains: $retired"
done

for text_file in "$ROOT"/zapret2/presets/*.txt \
    "$ROOT"/zapret2/strategy-catalogs/*.txt; do
    if grep -n -- '--ipcache' "$text_file" >/dev/null; then
        fail "forbidden Android ipcache option remains: $text_file"
    fi
done

STRATEGY_OUTPUT="$(sh "$ROOT/zapret2/scripts/command-builder.sh" \
    --validate-strategies-machine "$ROOT/zapret2")" || fail "strategy catalogs were rejected"
[ "$STRATEGY_OUTPUT" = "$(printf 'Z2_STRATEGIES\tOK')" ] || fail "strategy output is not exact"

BAD_STRATEGIES="$TMP/bad-strategies"
cp -R "$ROOT/zapret2" "$BAD_STRATEGIES"
printf '%s\n' 'name = duplicate metadata must fail' >> "$BAD_STRATEGIES/strategy-catalogs/http80.txt"
assert_fails sh "$ROOT/zapret2/scripts/command-builder.sh" \
    --validate-strategies-machine "$BAD_STRATEGIES"

PRESET_SCAN="$TMP/presets.scan"
sh "$ROOT/zapret2/scripts/command-builder.sh" --scan-presets-machine "$ROOT/zapret2" > "$PRESET_SCAN" ||
    fail "preset catalog was rejected"
PRESET_TOTAL="$(find "$ROOT/zapret2/presets" -maxdepth 1 -type f -name '*.txt' | wc -l)"
grep -Fxq "Z2_PRESET_SUMMARY$(printf '\t')1$(printf '\t')valid=$PRESET_TOTAL$(printf '\t')quarantined=0$(printf '\t')total=$PRESET_TOTAL" "$PRESET_SCAN" ||
    fail "preset summary does not match the packaged catalog"

PRESET_LIST="$TMP/presets.list"
sh "$ROOT/zapret2/scripts/command-builder.sh" --list-presets-machine "$ROOT/zapret2" > "$PRESET_LIST" ||
    fail "trusted preset catalog could not be listed"
grep -Fxq "Z2_PRESET_SUMMARY$(printf '\t')2$(printf '\t')ready=$PRESET_TOTAL$(printf '\t')quarantined=0$(printf '\t')total=$PRESET_TOTAL" "$PRESET_LIST" ||
    fail "trusted preset list does not match the packaged catalog"

# These read-only commands run while the app's shared root-command gate is
# occupied. They must remain shell-builtin parsers rather than spawning one
# grep process for every catalog section, preset name, or dependency.
NO_GREP_BIN="$TMP/no-grep-bin"
mkdir -p "$NO_GREP_BIN"
printf '%s\n' '#!/bin/sh' 'exit 99' > "$NO_GREP_BIN/grep"
chmod 0755 "$NO_GREP_BIN/grep"
NO_GREP_STRATEGY_OUTPUT="$(PATH="$NO_GREP_BIN:$PATH" sh \
    "$ROOT/zapret2/scripts/command-builder.sh" --validate-strategies-machine "$ROOT/zapret2")" ||
    fail "strategy validation still depends on per-section grep processes"
[ "$NO_GREP_STRATEGY_OUTPUT" = "$STRATEGY_OUTPUT" ] || fail "fork-free strategy output changed"
NO_GREP_SCAN="$TMP/presets.no-grep.scan"
PATH="$NO_GREP_BIN:$PATH" sh "$ROOT/zapret2/scripts/command-builder.sh" \
    --scan-presets-machine "$ROOT/zapret2" > "$NO_GREP_SCAN" ||
    fail "preset scan still depends on per-preset grep processes"
cmp "$PRESET_SCAN" "$NO_GREP_SCAN" >/dev/null || fail "fork-free preset scan output changed"
NO_GREP_LIST="$TMP/presets.no-grep.list"
PATH="$NO_GREP_BIN:$PATH" sh "$ROOT/zapret2/scripts/command-builder.sh" \
    --list-presets-machine "$ROOT/zapret2" > "$NO_GREP_LIST" ||
    fail "trusted preset list depends on deep validation tools"
cmp "$PRESET_LIST" "$NO_GREP_LIST" >/dev/null || fail "fork-free preset list output changed"

FIXTURE="$TMP/compiler"
cp -R "$ROOT/zapret2" "$FIXTURE"
cat > "$FIXTURE/nfqws2" <<'EOF'
#!/bin/sh
# Preview is a pure compiler operation. Binary capability checks and dry-runs
# belong to the separate preflight/start boundary.
exit 97
EOF
chmod 0755 "$FIXTURE/nfqws2"
cat > "$FIXTURE/presets/TCP only.txt" <<'EOF'
# NFQWS2_TCP_PKT_OUT=20
# NFQWS2_TCP_PKT_IN=10
# NFQWS2_UDP_PKT_OUT=20
# NFQWS2_UDP_PKT_IN=10

--lua-init=@lua/zapret-lib.lua
--blob=zero:0x00

--name=TCP only
--filter-tcp=80
--lua-desync=pass
EOF
cat > "$FIXTURE/presets/UDP only.txt" <<'EOF'
# NFQWS2_TCP_PKT_OUT=20
# NFQWS2_TCP_PKT_IN=10
# NFQWS2_UDP_PKT_OUT=7
# NFQWS2_UDP_PKT_IN=3

--lua-init=@lua/zapret-lib.lua
--blob=zero:0x00

--name=Discord voice
--filter-udp=443
--filter-l7=stun,discord
--lua-desync=pass
EOF

SCRIPT_DIR="$FIXTURE/scripts"
ZAPRET_DIR="$FIXTURE"
MODDIR="$TMP"
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"
. "$FIXTURE/scripts/common.sh"
. "$FIXTURE/scripts/command-builder.sh"
QNUM=200 DESYNC_MARK=0x40000000 NFQWS_UID=0:0 LOG_MODE=none

compile_preset_artifact "$FIXTURE/presets/TCP only.txt" "TCP only.txt" "$TMP/tcp.argv" ||
    fail "TCP-only preset did not compile"
read_compiled_artifact_metadata "$TMP/tcp.argv" || fail "TCP artifact metadata is invalid"
[ "$COMPILED_TCP_PORTS" = 80 ] && [ -z "$COMPILED_UDP_PORTS" ] &&
    [ "$COMPILED_TCP_PKT_OUT:$COMPILED_TCP_PKT_IN:$COMPILED_UDP_PKT_OUT:$COMPILED_UDP_PKT_IN" = 20:10:20:10 ] ||
    fail "TCP-only preset opened unexpected ports"
cat > "$FIXTURE/install-generation.meta" <<EOF
version=1
module_dir=$MODDIR
generation=receipt-test
archive_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
chmod 0600 "$FIXTURE/install-generation.meta"
INSTALL_META_CACHED_PATH=""
compile_preset_artifact "$FIXTURE/presets/TCP only.txt" "TCP only.txt" "$TMP/tcp.argv" ||
    fail "installed-generation artifact did not compile"
[ "$COMPILED_INSTALL_GENERATION" = receipt-test ] &&
    [ "$COMPILED_INSTALL_ARCHIVE_SHA256" = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ] ||
    fail "compiled artifact is not bound to the install generation"
(
    compile_preset_artifact() { return 97; }
    ensure_compiled_artifact "$FIXTURE/presets/TCP only.txt" "TCP only.txt" "$TMP/tcp.argv"
) || fail "unchanged generation-bound preset was rebuilt instead of reused"
write_compiled_validation_receipt "$TMP/tcp.argv" ||
    fail "validated compiled preset receipt was not published"
compiled_validation_receipt_current "$TMP/tcp.argv" ||
    fail "unchanged validated compiled preset receipt was not reused"
sed 's/generation=receipt-test/generation=next-generation/' \
    "$FIXTURE/install-generation.meta" > "$FIXTURE/install-generation.meta.next"
chmod 0600 "$FIXTURE/install-generation.meta.next"
mv "$FIXTURE/install-generation.meta.next" "$FIXTURE/install-generation.meta"
# The generation record only ever changes between transactions (module
# promotion at reboot); a new transaction starts with an empty meta cache.
INSTALL_META_CACHED_PATH=""
assert_fails compiled_validation_receipt_current "$TMP/tcp.argv"
assert_fails compiled_artifact_binding_current \
    "$TMP/tcp.argv" "$FIXTURE/presets/TCP only.txt" "TCP only.txt"
sed 's/generation=next-generation/generation=receipt-test/' \
    "$FIXTURE/install-generation.meta" > "$FIXTURE/install-generation.meta.next"
chmod 0600 "$FIXTURE/install-generation.meta.next"
mv "$FIXTURE/install-generation.meta.next" "$FIXTURE/install-generation.meta"
INSTALL_META_CACHED_PATH=""
printf '%s\n' '# receipt input changed' >> "$TMP/tcp.argv"
assert_fails compiled_validation_receipt_current "$TMP/tcp.argv"
compile_preset_artifact "$FIXTURE/presets/TCP only.txt" "TCP only.txt" "$TMP/tcp.argv" ||
    fail "TCP-only preset did not recompile after receipt invalidation"

sed '/--filter-tcp=80/a --filter-tcp=443' "$FIXTURE/presets/TCP only.txt" > "$FIXTURE/presets/Multi filter.txt"
compile_preset_artifact "$FIXTURE/presets/Multi filter.txt" "Multi filter.txt" "$TMP/multi-filter.argv" ||
    fail "multiple filters in one profile did not compile"
read_compiled_artifact_metadata "$TMP/multi-filter.argv" || fail "multi-filter metadata is invalid"
[ "$COMPILED_TCP_PORTS" = 80,443 ] && [ -z "$COMPILED_UDP_PORTS" ] ||
    fail "fork-free capture parser dropped a repeated protocol filter"
cp "$TMP/tcp.argv" "$TMP/tampered-ipcache.argv"
printf '%s\n' '--ipcache-hostname=1' >> "$TMP/tampered-ipcache.argv"
read_compiled_artifact_metadata "$TMP/tampered-ipcache.argv" || fail "tampered artifact fixture is structurally invalid"
assert_fails run_compiled_artifact "$TMP/tampered-ipcache.argv" dry-run

compile_preset_artifact "$FIXTURE/presets/UDP only.txt" "UDP only.txt" "$TMP/udp.argv" ||
    fail "UDP-only preset did not compile"
read_compiled_artifact_metadata "$TMP/udp.argv" || fail "UDP artifact metadata is invalid"
[ -z "$COMPILED_TCP_PORTS" ] && [ "$COMPILED_UDP_PORTS" = 443,3478,5349,19302 ] ||
    fail "voice UDP union is not exact"
[ "$COMPILED_TCP_PKT_OUT:$COMPILED_TCP_PKT_IN:$COMPILED_UDP_PKT_OUT:$COMPILED_UDP_PKT_IN" = 20:10:7:3 ] ||
    fail "protocol-specific capture policy was not preserved"
grep -Fxq -- '--name=Discord voice' "$TMP/udp.argv" || fail "argument with spaces was split"

PREVIEW_OUTPUT="$TMP/preview.out"
if ! STATE_DIR="$STATE_DIR" sh "$FIXTURE/scripts/command-builder.sh" \
    --preview-preset-machine "$FIXTURE" "$FIXTURE/presets/TCP only.txt" "TCP only.txt" \
    > "$PREVIEW_OUTPUT" 2>&1; then
    sed -n '1,80p' "$PREVIEW_OUTPUT" >&2
    fail "command preview rejected a valid unsaved candidate"
fi
grep -Fxq "Z2_COMMAND_PREVIEW$(printf '\t')2$(printf '\t')TCP only.txt$(printf '\t')TCP=80$(printf '\t')UDP=$(printf '\t')TCP_OUT=20$(printf '\t')TCP_IN=10$(printf '\t')UDP_OUT=20$(printf '\t')UDP_IN=10" \
    "$PREVIEW_OUTPUT" || fail "command preview port metadata is not exact"
grep -Fxq "Z2_COMMAND_EXECUTABLE$(printf '\t')$FIXTURE/nfqws2" "$PREVIEW_OUTPUT" ||
    fail "command preview executable is not exact"
grep -Fxq "Z2_COMMAND_ARGUMENT$(printf '\t')--daemon" "$PREVIEW_OUTPUT" ||
    fail "command preview omitted launcher daemon mode"
grep -Fxq "Z2_COMMAND_ARGUMENT$(printf '\t')--pidfile=$STATE_DIR/nfqws2.pid" "$PREVIEW_OUTPUT" ||
    fail "command preview omitted launcher pidfile"
grep -Fxq "Z2_COMMAND_ARGUMENT$(printf '\t')--name=TCP only" "$PREVIEW_OUTPUT" ||
    fail "command preview split an argument containing spaces"
grep -Eq "^Z2_COMMAND_SUMMARY$(printf '\t')1$(printf '\t')count=[0-9][0-9]*$" "$PREVIEW_OUTPUT" ||
    fail "command preview summary is missing"
PREVIEW_COUNT="$(sed -n 's/^Z2_COMMAND_SUMMARY[[:space:]]1[[:space:]]count=//p' "$PREVIEW_OUTPUT")"
PREVIEW_ARGUMENTS="$(grep -c "^Z2_COMMAND_ARGUMENT$(printf '\t')" "$PREVIEW_OUTPUT")"
[ "$PREVIEW_COUNT" = "$PREVIEW_ARGUMENTS" ] && [ "$PREVIEW_COUNT" -gt 3 ] ||
    fail "command preview argument count is not exact"

sed '/--name=TCP only/a --skip' "$FIXTURE/presets/TCP only.txt" > "$TMP/disabled.txt"
assert_fails compile_preset_artifact "$TMP/disabled.txt" "TCP only.txt" "$TMP/disabled.argv"
sed '/--name=TCP only/a --ipcache-hostname' "$FIXTURE/presets/TCP only.txt" > "$FIXTURE/presets/IPCache.txt"
assert_fails validate_preset_file "$FIXTURE/presets/IPCache.txt" "IPCache.txt"
[ "$PRESET_VALIDATION_CODE" = FORBIDDEN_IPCACHE_OPTION ] || fail "ipcache rejection is not typed"

RUNTIME_TARGET="$TMP/runtime.ini"
sh "$ROOT/zapret2/scripts/runtime-init.sh" "$RUNTIME_TARGET" || fail "runtime initialization failed"
grep -Fxq 'active_preset=Default v1 (game filter).txt' "$RUNTIME_TARGET" ||
    fail "runtime default preset is not Default v1"
assert_not_contains "$RUNTIME_TARGET" 'preset_mode='
assert_not_contains "$RUNTIME_TARGET" 'strategy_preset='
assert_not_contains "$RUNTIME_TARGET" 'ports_tcp='
assert_not_contains "$RUNTIME_TARGET" 'ports_udp='

assert_contains "$ROOT/zapret2/scripts/zapret-start.sh" 'ensure_compiled_artifact'
assert_contains "$ROOT/zapret2/scripts/zapret-start.sh" 'run_compiled_artifact'
# The Android app renders this mirror on its logs screen; the module must
# keep publishing it even though no shell code reads it back.
assert_contains "$ROOT/zapret2/scripts/zapret-start.sh" '"$CMDLINE_FILE.tmp.$$"'
assert_not_contains "$ROOT/zapret2/scripts/zapret-start.sh" '@config'
assert_not_contains "$ROOT/zapret2/scripts/command-builder.sh" 'eval '

Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/full-rollback.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/error-contract.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/purge-contract.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/lifecycle-safety.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/owner-generation.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/owner-state-v8.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/boot-recovery.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/lifecycle-lock-owner.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/lifecycle-status-v4.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/lifecycle-status-v5.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/lifecycle-status-v6.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/status-snapshot-fast-path.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/package-owner-protocol.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/runtime-config-contract.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/release-generation.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/transactional-start.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/firewall-reconciler.sh"

run_android_storage_test() {
    storage_test_script="$1"
    storage_test_name="$2"
    if [ -z "${Z2_TEST_BUSYBOX_BINARY:-}" ] || [ ! -d /data/adb ]; then
        Z2_TEST_TMP="$TMP" sh "$storage_test_script"
        return
    fi
    # This test must exercise the literal root-manager paths required by the
    # installer contract. Hide the phone's real module storage behind a
    # private bind mount; the namespace disappears with the child process.
    test_data_adb="$TMP/android-data-adb-$storage_test_name"
    mkdir -p "$test_data_adb/modules" "$test_data_adb/modules_update"
    "$Z2_TEST_BUSYBOX_BINARY" unshare -m "$Z2_TEST_BUSYBOX_BINARY" sh -c '
        test_data_adb="$1"
        test_tmp="$2"
        test_script="$3"
        "$Z2_TEST_BUSYBOX_BINARY" mount --make-rprivate / || exit 1
        "$Z2_TEST_BUSYBOX_BINARY" mount --bind "$test_data_adb" /data/adb ||
            exit 1
        Z2_TEST_TMP="$test_tmp" sh "$test_script"
    ' sh "$test_data_adb" "$TMP" "$storage_test_script"
}

run_android_storage_test "$ROOT/tests/shell/magisk-boot-installer.sh" magisk-installer
run_android_storage_test "$ROOT/tests/shell/packaging-recovery-flow.sh" packaging-recovery
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/preset-contract.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/preset-apply-transaction.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/preset-save-transaction.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/daemon-replace-transaction.sh"
Z2_TEST_TMP="$TMP" sh "$ROOT/tests/shell/topology-replace-transaction.sh"

echo "Shell integration tests passed"
