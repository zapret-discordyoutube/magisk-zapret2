#!/bin/sh
set -eu

# The compiled-argv cache is keyed by the preset's source digest, so a slot the
# launcher refuses is not a transient disagreement: every later start restores
# the same slot and hits the same refusal. Restoring from cache must therefore
# apply exactly the binding zapret-start.sh re-checks before launch.
#
# Regression: compiled_cache_restore screened a slot on logical name, source
# digest and config signature only, while compiled_artifact_binding_current
# additionally requires the installation generation. Installing a new module
# generation left the previous generation's slot in place, cache restore adopted
# it, and the launch refused it with "compiled preset source binding changed
# before launch" — the service could not be started at all until the cache was
# deleted by hand.

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=${Z2_TEST_TMP:?}
CASE="$TMP/compiled-argv-cache"
SCRIPTS="$CASE/module/zapret2/scripts"
STATE="$CASE/state"

fail() { echo "FAIL: compiled-argv-cache: $*" >&2; exit 1; }

rm -rf "$CASE"
mkdir -p "$SCRIPTS" "$STATE"
chmod 0700 "$STATE"
cp "$ROOT/zapret2/scripts/common.sh" "$SCRIPTS/common.sh"
cp "$ROOT/zapret2/scripts/command-builder.sh" "$SCRIPTS/command-builder.sh"

cat > "$SCRIPTS/scenario.sh" <<'EOF'
#!/bin/sh
set -eu
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
Z2_RESHELLED=1
export Z2_RESHELLED
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/command-builder.sh"

STATE_DIR=${Z2_CACHE_TEST_STATE:?}
PRESET_FILE=${Z2_CACHE_TEST_PRESET:?}

# The slot's own protection is not what this case is about, and the harness
# cannot reproduce the installed tree's ownership under an ordinary test user.
state_file_is_secure() { [ -f "$1" ] && [ ! -L "$1" ]; }
current_config_signature() { CONFIG_SIG_CURRENT='qnum=200;mark=0x40000000;uid=0:0;log=none'; }

Z2_TEST_GENERATION=${Z2_TEST_GENERATION:?}
read_install_generation_meta() {
    INSTALL_META_GENERATION="$Z2_TEST_GENERATION"
    INSTALL_META_ARCHIVE_SHA256="$Z2_TEST_GENERATION"
    return 0
}

write_slot() {
    local generation="$1" source_sha slot
    source_sha="$(sha256sum "$PRESET_FILE")"
    source_sha="${source_sha%% *}"
    slot="$STATE_DIR/argv-cache.$source_sha.argv"
    current_config_signature
    {
        printf 'Z2_ARGV\t4\n'
        printf 'PRESET\t%s\nSHA256\t%s\nCONFIG_SIG\t%s\nINSTALL_GENERATION\t%s\nINSTALL_ARCHIVE_SHA256\t%s\nTCP\t%s\nUDP\t%s\n' \
            'Cached.txt' "$source_sha" "$CONFIG_SIG_CURRENT" "$generation" "$generation" '443' '443'
        printf 'TCP_PKT_OUT\t%s\nTCP_PKT_IN\t%s\nUDP_PKT_OUT\t%s\nUDP_PKT_IN\t%s\nARGS\n' 20 10 20 10
        printf '%s\n' '--qnum=200' '--filter-tcp=443' '--lua-desync=pass'
    } > "$slot"
    chmod 0600 "$slot"
}

case "$1" in
    restore)
        write_slot "$2"
        if compiled_cache_restore "$PRESET_FILE" 'Cached.txt'; then
            echo restored
        else
            echo refused
        fi
        ;;
    agrees-with-launch)
        # Whatever cache restore adopts, the launcher must also accept: it is
        # the same artifact and the same question, one moment apart.
        write_slot "$2"
        if compiled_cache_restore "$PRESET_FILE" 'Cached.txt'; then
            if compiled_artifact_binding_current \
                "$COMPILED_ARGV_FILE" "$PRESET_FILE" 'Cached.txt'; then
                echo agrees
            else
                echo diverges
            fi
        else
            echo refused
        fi
        ;;
    *) exit 2 ;;
esac
EOF

PRESET="$CASE/Cached.txt"
printf '%s\n' '--filter-tcp=443' '--lua-desync=pass' > "$PRESET"

run_case() {
    Z2_CACHE_TEST_STATE="$STATE" Z2_CACHE_TEST_PRESET="$PRESET" \
        Z2_TEST_GENERATION="$2" sh "$SCRIPTS/scenario.sh" "$1" "$3"
}

current=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
previous=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

[ "$(run_case restore "$current" "$current")" = restored ] ||
    fail "a slot compiled by the installed generation must be reusable"
[ "$(run_case restore "$current" "$previous")" = refused ] ||
    fail "a slot compiled by a previous installation generation was adopted"
[ "$(run_case agrees-with-launch "$current" "$current")" = agrees ] ||
    fail "cache restore and the launch binding check disagree"

echo "Compiled argv cache tests passed"
