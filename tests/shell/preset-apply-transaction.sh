#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=${Z2_TEST_TMP:?}
CASE="$TMP/preset-apply-transaction"
MOD="$CASE/module"
ZAPRET="$MOD/zapret2"
SCRIPTS="$ZAPRET/scripts"
STATE="$CASE/state"
LOG="$CASE/calls"
OUT="$CASE/out"

fail() { echo "FAIL: preset-apply-transaction: $*" >&2; exit 1; }

mkdir -p "$MOD"
cp -R "$ROOT/zapret2" "$ZAPRET"
mkdir -p "$STATE"
chmod 0700 "$STATE"
chmod 0644 "$ZAPRET/runtime.ini"

# The module transaction always reaches the packaged replacement transaction
# through zapret-start.sh --replace. This stub proves the exact invocation and
# the inherited lifecycle ownership without building real firewall state.
cat > "$SCRIPTS/zapret-start.sh" <<'EOF'
#!/bin/sh
printf 'replace:%s\n' "$*" >> "${Z2_APPLY_TEST_LOG:?}"
printf 'replace-token:%s\n' "${ZAPRET2_LIFECYCLE_TOKEN:-none}" >> "$Z2_APPLY_TEST_LOG"
if [ "${Z2_APPLY_TEST_REPLACE_FAILS:-0}" = 1 ]; then
    printf 'Z2_ERROR_SCHEMA=1\n'
    printf 'Z2_ERROR_STATUS=ERROR\n'
    printf 'Z2_ERROR_DOMAIN=PROCESS\n'
    printf 'Z2_ERROR_STAGE=START_LAUNCH\n'
    printf 'Z2_ERROR_CODE=PROCESS_LAUNCH_FAILED\n'
    printf 'Z2_ERROR_DETAIL=nfqws2 launch failed\n'
    printf 'ERROR: nfqws2 launch failed\n'
    exit 1
fi
printf 'Zapret2 restarted (PID: 4321)\n'
exit 0
EOF
chmod 0755 "$SCRIPTS/zapret-start.sh"

cat > "$ZAPRET/nfqws2" <<'EOF'
#!/bin/sh
if [ "${Z2_APPLY_TEST_DRY_RUN_FAILS:-0}" = 1 ]; then exit 7; fi
exit 0
EOF
chmod 0755 "$ZAPRET/nfqws2"

# Fixture presets depend only on packaged assets, so this case reproduces on a
# bare checkout as well as on a fully fetched release tree.
write_preset() {
    cat > "$ZAPRET/presets/$1" <<EOF
# NFQWS2_TCP_PKT_OUT=20
# NFQWS2_TCP_PKT_IN=10
# NFQWS2_UDP_PKT_OUT=20
# NFQWS2_UDP_PKT_IN=10

--lua-init=@lua/custom_funcs.lua
--blob=zero:0x00

--name=$2
$3--filter-tcp=80
--lua-desync=pass
EOF
    chmod 0644 "$ZAPRET/presets/$1"
}

write_preset 'Alpha.txt' Alpha ''
write_preset 'Beta.txt' Beta ''
write_preset 'Forbidden option.txt' Forbidden '--ipcache-hostname
'

sed '$d' "$ROOT/zapret2/scripts/zapret-apply-preset.sh" > "$SCRIPTS/zapret-apply-preset-defs.sh"
chmod 0755 "$SCRIPTS/zapret-apply-preset-defs.sh"

# The "is the service running" answer and a failing rollback publication are the
# two facts a portable test cannot produce for real: the first needs a live
# verified nfqws2 process behind a committed lifecycle receipt, the second needs
# a broken filesystem. Everything else in the transaction runs unmodified.
cat > "$SCRIPTS/scenario.sh" <<'EOF'
#!/bin/sh
. "$(dirname "$0")/zapret-apply-preset-defs.sh"

if [ "${Z2_APPLY_TEST_RUNNING:-1}" = 1 ]; then
    service_process_is_running() { return 0; }
else
    service_process_is_running() { return 1; }
fi
if [ "${Z2_APPLY_TEST_BREAK_ROLLBACK:-0}" = 1 ]; then
    rollback_runtime_config() { return 1; }
fi

if [ "${1:-}" = --canonical-digest ]; then
    read_runtime_generations "$RUNTIME_CONFIG" "unused.txt" || exit 3
    runtime_canonical_digest "$RUNTIME_CANONICAL_TEXT" || exit 3
    printf '%s\n' "$RUNTIME_CANONICAL_DIGEST"
    exit 0
fi

main "$@"
EOF
chmod 0755 "$SCRIPTS/scenario.sh"

active_preset() {
    sed -n 's/^active_preset=//p' "$ZAPRET/runtime.ini"
}

payload() {
    sed -n "s/^$1=//p" "$OUT"
}

RUNNING=1
REPLACE_FAILS=0
DRY_RUN_FAILS=0
BREAK_ROLLBACK=0

run_apply() {
    : > "$LOG"
    set +e
    env \
        Z2_APPLY_TEST_LOG="$LOG" \
        STATE_DIR="$STATE" \
        Z2_APPLY_TEST_RUNNING="$RUNNING" \
        Z2_APPLY_TEST_REPLACE_FAILS="$REPLACE_FAILS" \
        Z2_APPLY_TEST_DRY_RUN_FAILS="$DRY_RUN_FAILS" \
        Z2_APPLY_TEST_BREAK_ROLLBACK="$BREAK_ROLLBACK" \
        sh "$SCRIPTS/scenario.sh" "$@" > "$OUT" 2>&1
    APPLY_RC=$?
    set -e
}

expect_payload() {
    actual="$(payload "$1")"
    [ "$actual" = "$2" ] || fail "$1 was '$actual', expected '$2'"
}

expect_complete_payload() {
    grep -Fxq 'Z2_APPLY_COMPLETE=1' "$OUT" || fail "payload is not terminated: $(cat "$OUT")"
    grep -Fxq 'Z2_APPLY_SCHEMA=1' "$OUT" || fail "payload omits its schema"
    grep -Fxq 'Z2_ERROR_SCHEMA=1' "$OUT" || fail "payload omits the shared error schema"
    # No free-text-only reporting: every emitted line belongs to the contract.
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        case "$line" in
            Z2_APPLY_*=*|Z2_ERROR_*=*) ;;
            *) fail "payload contains untyped output: $line" ;;
        esac
    done < "$OUT"
}

expect_no_candidate() {
    [ -z "$(find "$ZAPRET" -maxdepth 1 -name 'runtime.ini.candidate.*' -print -quit)" ] ||
        fail "a runtime candidate survived the transaction"
}

# The canonical runtime identity this transaction computes in-process must be
# byte-for-byte the identity the commit boundary compares against. If the two
# ever diverge the compare-and-swap fails closed instead of publishing a wrong
# generation, so pin them together here.
run_apply --canonical-digest
[ "$APPLY_RC" = 0 ] || fail "canonical digest probe failed: $(cat "$OUT")"
SCRIPT_DIGEST="$(cat "$OUT")"
sh "$ROOT/zapret2/scripts/runtime-config.sh" --inspect-machine "$ZAPRET/runtime.ini" \
    > "$CASE/inspect.out" || fail "runtime inspection failed"
INSPECT_DIGEST="$(sed -n "s/^Z2_RUNTIME_SHA256$(printf '\t')//p" "$CASE/inspect.out")"
[ -n "$INSPECT_DIGEST" ] || fail "runtime inspection omitted the content identity"
[ "$SCRIPT_DIGEST" = "$INSPECT_DIGEST" ] ||
    fail "canonical runtime identity diverged from the commit boundary"

BEFORE="$(active_preset)"
[ -n "$BEFORE" ] || fail "fixture runtime.ini has no selection"

# An unsafe request is refused before the name can reach the payload and before
# any part of the live configuration is read or written.
run_apply '../escape.txt'
[ "$APPLY_RC" = 1 ] || fail "unsafe preset name did not fail"
expect_complete_payload
expect_payload Z2_APPLY_OUTCOME REJECTED
expect_payload Z2_APPLY_ISSUE UNSAFE_PRESET_NAME
expect_payload Z2_APPLY_PRESET ''
expect_payload Z2_APPLY_CONFIG_COMMITTED 0
expect_payload Z2_ERROR_STATUS ERROR
[ "$(active_preset)" = "$BEFORE" ] || fail "unsafe preset name changed the live selection"
[ ! -s "$LOG" ] || fail "unsafe preset name reached the replacement transaction"

# An incompatible preset is refused with the live selection untouched, instead
# of being published, failed and rolled back.
run_apply 'Forbidden option.txt'
[ "$APPLY_RC" = 1 ] || fail "incompatible preset did not fail"
expect_complete_payload
expect_payload Z2_APPLY_OUTCOME REJECTED
expect_payload Z2_APPLY_ISSUE FORBIDDEN_IPCACHE_OPTION
expect_payload Z2_APPLY_PRESET 'Forbidden option.txt'
expect_payload Z2_APPLY_PREVIOUS_PRESET "$BEFORE"
expect_payload Z2_APPLY_CONFIG_COMMITTED 0
expect_payload Z2_ERROR_CODE FORBIDDEN_IPCACHE_OPTION
[ "$(active_preset)" = "$BEFORE" ] || fail "incompatible preset changed the live selection"
[ ! -s "$LOG" ] || fail "incompatible preset reached the replacement transaction"
expect_no_candidate

# A preset the packaged launcher itself refuses is the same refusal, reported
# with the launcher's own typed reason.
DRY_RUN_FAILS=1
run_apply 'Alpha.txt'
DRY_RUN_FAILS=0
[ "$APPLY_RC" = 1 ] || fail "packaged launcher rejection did not fail"
expect_complete_payload
expect_payload Z2_APPLY_OUTCOME REJECTED
expect_payload Z2_APPLY_ISSUE NFQWS_DRY_RUN_FAILED
expect_payload Z2_APPLY_CONFIG_COMMITTED 0
[ "$(active_preset)" = "$BEFORE" ] || fail "launcher rejection changed the live selection"
[ ! -s "$LOG" ] || fail "launcher rejection reached the replacement transaction"

# Happy path: one transaction validates, publishes and replaces.
run_apply 'Alpha.txt'
[ "$APPLY_RC" = 0 ] || fail "valid preset application failed: $(cat "$OUT")"
expect_complete_payload
expect_payload Z2_APPLY_OUTCOME APPLIED
expect_payload Z2_APPLY_ISSUE NONE
expect_payload Z2_APPLY_PRESET 'Alpha.txt'
expect_payload Z2_APPLY_PREVIOUS_PRESET "$BEFORE"
expect_payload Z2_APPLY_CONFIG_COMMITTED 1
expect_payload Z2_APPLY_SERVICE_WAS_RUNNING 1
expect_payload Z2_ERROR_STATUS OK
[ "$(active_preset)" = 'Alpha.txt' ] || fail "the selection was not published"
grep -Fxq 'replace:--replace' "$LOG" ||
    fail "the packaged replacement transaction was not invoked"
[ "$(grep -c '^replace:' "$LOG")" = 1 ] ||
    fail "the replacement transaction was invoked more than once"
! grep -Fxq 'replace-token:none' "$LOG" ||
    fail "the replacement transaction ran without inherited lifecycle ownership"
grep -Eq '^replace-token:[A-Za-z0-9._-]+$' "$LOG" ||
    fail "the replacement transaction did not inherit a usable lifecycle token"
grep -Fxq '[core]' "$ZAPRET/runtime.ini" || fail "runtime.ini lost its core section"
expect_no_candidate

# The service the user stopped is not started by a configuration change.
RUNNING=0
run_apply 'Beta.txt'
RUNNING=1
[ "$APPLY_RC" = 0 ] || fail "saved-only application failed: $(cat "$OUT")"
expect_complete_payload
expect_payload Z2_APPLY_OUTCOME SAVED
expect_payload Z2_APPLY_SERVICE_WAS_RUNNING 0
expect_payload Z2_APPLY_CONFIG_COMMITTED 1
expect_payload Z2_APPLY_PREVIOUS_PRESET 'Alpha.txt'
expect_payload Z2_ERROR_STATUS OK
[ "$(active_preset)" = 'Beta.txt' ] || fail "saved-only application did not persist the selection"
[ ! -s "$LOG" ] || fail "saved-only application invoked the replacement transaction"
expect_no_candidate

# A failed replacement restores the previous selection and says so, carrying the
# exact typed identity the replacement transaction published.
REPLACE_FAILS=1
run_apply 'Alpha.txt'
REPLACE_FAILS=0
[ "$APPLY_RC" = 1 ] || fail "failed replacement did not fail the transaction"
expect_complete_payload
expect_payload Z2_APPLY_OUTCOME RESTART_FAILED_ROLLED_BACK
expect_payload Z2_APPLY_ISSUE NONE
expect_payload Z2_APPLY_CONFIG_COMMITTED 0
expect_payload Z2_ERROR_DOMAIN PROCESS
expect_payload Z2_ERROR_CODE PROCESS_LAUNCH_FAILED
expect_payload Z2_ERROR_STAGE START_LAUNCH
[ "$(active_preset)" = 'Beta.txt' ] ||
    fail "a failed replacement left the new selection published"
expect_no_candidate

# A rollback that cannot restore the previous selection is reported as such and
# never as a plain restart failure.
REPLACE_FAILS=1
BREAK_ROLLBACK=1
run_apply 'Alpha.txt'
REPLACE_FAILS=0
BREAK_ROLLBACK=0
[ "$APPLY_RC" = 1 ] || fail "unrestorable rollback did not fail the transaction"
expect_complete_payload
expect_payload Z2_APPLY_OUTCOME ROLLBACK_FAILED
expect_payload Z2_APPLY_CONFIG_COMMITTED 1
[ "$(active_preset)" = 'Alpha.txt' ] ||
    fail "the unrestorable rollback fixture did not leave the new selection published"

# runtime.ini sections the core contract does not own survive the transaction.
printf '\n[dns_manager]\nselected_dns=cloudflare|google\n' >> "$ZAPRET/runtime.ini"
run_apply 'Beta.txt'
[ "$APPLY_RC" = 0 ] || fail "application over a non-core section failed: $(cat "$OUT")"
expect_payload Z2_APPLY_OUTCOME APPLIED
grep -Fxq '[dns_manager]' "$ZAPRET/runtime.ini" ||
    fail "the transaction discarded a non-core runtime section"
grep -Fxq 'selected_dns=cloudflare|google' "$ZAPRET/runtime.ini" ||
    fail "the transaction discarded a non-core runtime value"
[ "$(active_preset)" = 'Beta.txt' ] ||
    fail "the selection was not published alongside a non-core section"
[ "$(grep -c '^active_preset=' "$ZAPRET/runtime.ini")" = 1 ] ||
    fail "the transaction duplicated the selection key"
expect_no_candidate

# The packaged entry point reuses the owning boundaries instead of
# reimplementing them, and is declared exactly once as a packaged executable.
grep -Fq 'zapret-start.sh" --replace' "$ROOT/zapret2/scripts/zapret-apply-preset.sh" ||
    fail "the apply transaction does not reuse zapret-start.sh --replace"
grep -Fq -- '--commit-candidate' "$ROOT/zapret2/scripts/zapret-apply-preset.sh" ||
    fail "the apply transaction does not reuse the runtime.ini commit boundary"
[ "$(grep -c 'immutable-exec|0755|zapret2/scripts/zapret-apply-preset.sh' \
    "$ROOT/zapret2/runtime-manifest.tsv")" = 1 ] ||
    fail "the apply transaction is not declared exactly once in the runtime manifest"
[ "$(stat -c %a "$ROOT/zapret2/scripts/zapret-apply-preset.sh")" = 755 ] ||
    fail "the apply transaction is not packaged as an executable"

echo "Preset apply transaction shell tests passed"
