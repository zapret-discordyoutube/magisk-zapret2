#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=${Z2_TEST_TMP:?}
CASE="$TMP/preset-save-transaction"
MOD="$CASE/module"
ZAPRET="$MOD/zapret2"
SCRIPTS="$ZAPRET/scripts"
STATE="$CASE/state"
LOG="$CASE/calls"
OUT="$CASE/out"

fail() { echo "FAIL: preset-save-transaction: $*" >&2; exit 1; }

mkdir -p "$MOD"
cp -R "$ROOT/zapret2" "$ZAPRET"
mkdir -p "$STATE"
chmod 0700 "$STATE"
sed 's/^active_preset=.*/active_preset=Alpha.txt/' "$ROOT/zapret2/runtime.ini" > "$ZAPRET/runtime.ini"
chmod 0644 "$ZAPRET/runtime.ini"

cat > "$SCRIPTS/zapret-start.sh" <<'EOF'
#!/bin/sh
printf 'replace:%s\n' "$*" >> "${Z2_SAVE_TEST_LOG:?}"
if [ "${Z2_SAVE_TEST_REPLACE_FAILS:-0}" = 1 ]; then
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
if [ "${Z2_SAVE_TEST_DRY_RUN_FAILS:-0}" = 1 ]; then exit 7; fi
exit 0
EOF
chmod 0755 "$ZAPRET/nfqws2"

preset_body() {
    cat <<EOF
# NFQWS2_TCP_PKT_OUT=20
# NFQWS2_TCP_PKT_IN=10
# NFQWS2_UDP_PKT_OUT=20
# NFQWS2_UDP_PKT_IN=10

--lua-init=@lua/custom_funcs.lua
--blob=zero:0x00

--name=$1
--filter-tcp=80
--lua-desync=pass
EOF
}

write_preset() {
    preset_body "$2" > "$ZAPRET/presets/$1"
    chmod 0644 "$ZAPRET/presets/$1"
}

write_preset 'Alpha.txt' Alpha
write_preset 'Beta.txt' Beta

sed '$d' "$ROOT/zapret2/scripts/zapret-apply-preset.sh" > "$SCRIPTS/zapret-apply-preset-defs.sh"
chmod 0755 "$SCRIPTS/zapret-apply-preset-defs.sh"

cat > "$SCRIPTS/scenario.sh" <<'EOF'
#!/bin/sh
. "$(dirname "$0")/zapret-apply-preset-defs.sh"

if [ "${Z2_SAVE_TEST_RUNNING:-1}" = 1 ]; then
    service_process_is_running() { return 0; }
else
    service_process_is_running() { return 1; }
fi

if [ "${1:-}" = --content-digest ]; then
    preset_canonical_digest "$2" || exit 3
    printf '%s\n' "$PRESET_CANONICAL_DIGEST"
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

content_digest() {
    env STATE_DIR="$STATE" sh "$SCRIPTS/scenario.sh" --content-digest "$1"
}

stage_candidate() {
    printf '%s' "$2" > "$ZAPRET/presets/$1"
    chmod 0644 "$ZAPRET/presets/$1"
}

RUNNING=1
REPLACE_FAILS=0
DRY_RUN_FAILS=0

run_save() {
    : > "$LOG"
    set +e
    env \
        Z2_SAVE_TEST_LOG="$LOG" \
        STATE_DIR="$STATE" \
        Z2_SAVE_TEST_RUNNING="$RUNNING" \
        Z2_SAVE_TEST_REPLACE_FAILS="$REPLACE_FAILS" \
        Z2_SAVE_TEST_DRY_RUN_FAILS="$DRY_RUN_FAILS" \
        sh "$SCRIPTS/scenario.sh" --save-content "$@" > "$OUT" 2>&1
    SAVE_RC=$?
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
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        case "$line" in
            Z2_APPLY_*=*|Z2_ERROR_*=*) ;;
            *) fail "payload contains untyped output: $line" ;;
        esac
    done < "$OUT"
}

expect_no_staging_residue() {
    [ -z "$(find "$ZAPRET/presets" -maxdepth 1 -name '_*' -print -quit)" ] ||
        fail "a staged candidate survived the transaction"
    [ -z "$(find "$STATE/tmp" -maxdepth 1 -name 'preset-save*' -print -quit 2>/dev/null)" ] ||
        fail "a save scratch file survived the transaction"
}

NEW_ALPHA="$(preset_body AlphaEdited)"
ALPHA_DIGEST="$(content_digest "$ZAPRET/presets/Alpha.txt")"

# 1. Content save on the active preset replaces the daemon and keeps the
# selection: one transaction, outcome APPLIED, no runtime.ini commit.
stage_candidate '_Alpha.candidate.1.txt' "$NEW_ALPHA"
run_save '_Alpha.candidate.1.txt' "$ALPHA_DIGEST" 'Alpha.txt' auto
[ "$SAVE_RC" -eq 0 ] || fail "active-content save failed: $(cat "$OUT")"
expect_complete_payload
expect_payload Z2_APPLY_OUTCOME APPLIED
expect_payload Z2_APPLY_CONFIG_COMMITTED 0
grep -q '^replace:--replace$' "$LOG" || fail "the replacement transaction was not invoked"
[ "$(active_preset)" = 'Alpha.txt' ] || fail "the selection changed on a content-only save"
grep -q 'name=AlphaEdited' "$ZAPRET/presets/Alpha.txt" || fail "the saved content was not published"
expect_no_staging_residue

# 2. Editing an inactive preset publishes the file and never touches the
# daemon or the selection.
ALPHA_DIGEST="$(content_digest "$ZAPRET/presets/Alpha.txt")"
BETA_DIGEST="$(content_digest "$ZAPRET/presets/Beta.txt")"
stage_candidate '_Beta.candidate.2.txt' "$(preset_body BetaEdited)"
run_save '_Beta.candidate.2.txt' "$BETA_DIGEST" 'Beta.txt' auto
[ "$SAVE_RC" -eq 0 ] || fail "inactive-content save failed: $(cat "$OUT")"
expect_payload Z2_APPLY_OUTCOME SAVED
[ ! -s "$LOG" ] || fail "an inactive save replaced the daemon"
grep -q 'name=BetaEdited' "$ZAPRET/presets/Beta.txt" || fail "the inactive content was not published"
expect_no_staging_residue

# 3. Save-and-apply onto an inactive preset commits the selection and
# replaces the daemon: outcome SAVED_AND_APPLIED with the commit recorded.
BETA_DIGEST="$(content_digest "$ZAPRET/presets/Beta.txt")"
stage_candidate '_Beta.candidate.3.txt' "$(preset_body BetaPromoted)"
run_save '_Beta.candidate.3.txt' "$BETA_DIGEST" 'Beta.txt' apply
[ "$SAVE_RC" -eq 0 ] || fail "save-and-apply failed: $(cat "$OUT")"
expect_payload Z2_APPLY_OUTCOME SAVED_AND_APPLIED
expect_payload Z2_APPLY_CONFIG_COMMITTED 1
[ "$(active_preset)" = 'Beta.txt' ] || fail "save-and-apply did not commit the selection"
grep -q '^replace:--replace$' "$LOG" || fail "save-and-apply did not replace the daemon"
expect_no_staging_residue

# 4. A stale expected digest is refused before anything is written.
stage_candidate '_Beta.candidate.4.txt' "$(preset_body BetaStale)"
run_save '_Beta.candidate.4.txt' "$ALPHA_DIGEST" 'Beta.txt' auto
[ "$SAVE_RC" -ne 0 ] || fail "a stale digest was accepted"
expect_payload Z2_APPLY_OUTCOME SOURCE_CHANGED
grep -q 'name=BetaPromoted' "$ZAPRET/presets/Beta.txt" || fail "a refused save mutated the target"
expect_no_staging_residue

# 5. A candidate the dry run refuses never reaches the target.
BETA_DIGEST="$(content_digest "$ZAPRET/presets/Beta.txt")"
DRY_RUN_FAILS=1
stage_candidate '_Beta.candidate.5.txt' "$(preset_body BetaBroken)"
run_save '_Beta.candidate.5.txt' "$BETA_DIGEST" 'Beta.txt' apply
DRY_RUN_FAILS=0
[ "$SAVE_RC" -ne 0 ] || fail "a refused candidate was accepted"
expect_payload Z2_APPLY_OUTCOME REJECTED
expect_payload Z2_APPLY_ISSUE NFQWS_DRY_RUN_FAILED
grep -q 'name=BetaPromoted' "$ZAPRET/presets/Beta.txt" || fail "a rejected candidate mutated the target"
expect_no_staging_residue

# 6. A failed replacement rolls the content and the selection back.
[ "$(active_preset)" = 'Beta.txt' ] || fail "precondition: Beta must be active"
ALPHA_DIGEST="$(content_digest "$ZAPRET/presets/Alpha.txt")"
REPLACE_FAILS=1
stage_candidate '_Alpha.candidate.6.txt' "$(preset_body AlphaDoomed)"
run_save '_Alpha.candidate.6.txt' "$ALPHA_DIGEST" 'Alpha.txt' apply
REPLACE_FAILS=0
[ "$SAVE_RC" -ne 0 ] || fail "a failed replacement reported success"
expect_payload Z2_APPLY_OUTCOME RESTART_FAILED_ROLLED_BACK
[ "$(active_preset)" = 'Beta.txt' ] || fail "the selection was not rolled back"
grep -q 'name=AlphaEdited' "$ZAPRET/presets/Alpha.txt" || fail "the content was not rolled back"
expect_no_staging_residue

# 7. Creating a new preset from scratch: the missing sentinel is the expected
# identity, and auto mode never applies a preset that is not selected.
stage_candidate '_Gamma.candidate.7.txt' "$(preset_body Gamma)"
run_save '_Gamma.candidate.7.txt' missing 'Gamma.txt' auto
[ "$SAVE_RC" -eq 0 ] || fail "fresh-file save failed: $(cat "$OUT")"
expect_payload Z2_APPLY_OUTCOME SAVED
grep -q 'name=Gamma' "$ZAPRET/presets/Gamma.txt" || fail "the fresh preset was not created"
expect_no_staging_residue

# 8. The missing sentinel is refused when the target already exists.
stage_candidate '_Gamma.candidate.8.txt' "$(preset_body GammaAgain)"
run_save '_Gamma.candidate.8.txt' missing 'Gamma.txt' auto
[ "$SAVE_RC" -ne 0 ] || fail "an existing target passed the missing sentinel"
expect_payload Z2_APPLY_OUTCOME SOURCE_CHANGED
expect_no_staging_residue

# 9. When the service is stopped, an active-preset save publishes the content
# without inventing a start.
RUNNING=0
ALPHA_DIGEST="$(content_digest "$ZAPRET/presets/Alpha.txt")"
stage_candidate '_Alpha.candidate.9.txt' "$(preset_body AlphaQuiet)"
run_save '_Alpha.candidate.9.txt' "$ALPHA_DIGEST" 'Alpha.txt' auto
RUNNING=1
[ "$SAVE_RC" -eq 0 ] || fail "stopped-service save failed: $(cat "$OUT")"
expect_payload Z2_APPLY_OUTCOME SAVED
expect_payload Z2_APPLY_SERVICE_WAS_RUNNING 0
[ ! -s "$LOG" ] || fail "a stopped service was replaced"
expect_no_staging_residue

# 10. An unsafe candidate name is refused as a client protocol error.
run_save 'no-underscore.txt' missing 'Gamma.txt' auto
[ "$SAVE_RC" -ne 0 ] || fail "an unsafe candidate name was accepted"
expect_payload Z2_APPLY_OUTCOME IO_FAILED
expect_payload Z2_ERROR_CODE INVALID_ARGUMENTS

echo "preset-save-transaction: OK"
