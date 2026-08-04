#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd -P)"
TMP_ROOT="${Z2_TEST_TMP:-$(mktemp -d)}"
OWN_TMP=0
if [ -z "${Z2_TEST_TMP:-}" ]; then OWN_TMP=1; fi
cleanup() { [ "$OWN_TMP" -eq 0 ] || rm -rf "$TMP_ROOT"; }
trap cleanup EXIT HUP INT TERM

fail() { echo "preset-contract: $*" >&2; exit 1; }
assert_invalid_code() {
    expected="$1"; shift
    output="$TMP_ROOT/preset-contract-output"
    if "$@" > "$output" 2>&1; then fail "accepted invalid preset; expected $expected"; fi
    grep -Fq "$expected" "$output" || fail "wrong validation reason; expected $expected"
}

[ "$(grep -c '^preset-compatible|0644|' "$ROOT/zapret2/runtime-manifest.tsv")" -eq 98 ] || fail "compatible manifest count"
[ "$(grep -c '^preset-quarantined|0644|' "$ROOT/zapret2/runtime-manifest.tsv")" -eq 0 ] || fail "quarantined manifest count"
if grep -R -q -- '--lua-init=@lua/custom_diag.lua' "$ROOT/zapret2/presets"; then fail "custom_diag reference remains"; fi
[ "$(grep -Rl -- '--lua-init=@lua/fakemultisplit.lua' "$ROOT/zapret2/presets" | grep -v '/_' | wc -l)" -eq 98 ] || fail "fakemultisplit missing from a preset"
[ "$(grep -Rl -- '--lua-init=@lua/fakemultidisorder.lua' "$ROOT/zapret2/presets" | grep -v '/_' | wc -l)" -eq 98 ] || fail "fakemultidisorder missing from a preset"
if grep -R -q -- '^--wf-' "$ROOT/zapret2/presets"; then fail "WinDivert filter option remains"; fi
if grep -R -q -- '^--in-range=' "$ROOT/zapret2/presets"; then fail "inbound range remains"; fi
if grep -R -q -- '^--lua-desync=circular:' "$ROOT/zapret2/presets"; then fail "circular strategy remains"; fi
if grep -R -q -- '--ipcache' "$ROOT/zapret2/presets"; then fail "forbidden ipcache option remains"; fi
if grep -R -q -- '^--filter-tcp=.*-' "$ROOT/zapret2/presets"; then
    fail "packaged preset contains a broad TCP port range"
fi
if grep -R -q -- 'russia-youtube-ipset.txt' "$ROOT/zapret2/presets"; then fail "stale russia-youtube ipset name remains"; fi
for preset in "$ROOT"/zapret2/presets/*.txt; do
    case "${preset##*/}" in
        _*) ;;
        *)
            awk '
                /^--new$/ {
                    if (names != 1) exit 1
                    names=0
                    next
                }
                /^--name=/ {
                    if ($0 == "--name=") exit 1
                    names++
                }
                END { if (names != 1) exit 1 }
            ' "$preset" || fail "profile without exactly one name: $preset"
            ;;
    esac
    awk '
        /^[[:space:]]*$/ { blanks++; if (blanks > 1) exit 1; next }
        { blanks=0 }
    ' "$preset" || fail "consecutive blank lines: $preset"
done
grep -Fxq -- '--name=youtube.com (интерфейс)' \
    "$ROOT/zapret2/presets/Default v1 (game filter).txt" || fail "default profile names not restored"
common_blob_hash=
for preset in "$ROOT"/zapret2/presets/*.txt; do
    case "${preset##*/}" in _*) continue ;; esac
    [ "$(grep -c '^--blob=' "$preset")" -eq 68 ] || fail "incomplete common blob block: $preset"
    blob_hash="$(grep '^--blob=' "$preset" | sha256sum | awk '{print $1}')"
    if [ -z "$common_blob_hash" ]; then
        common_blob_hash="$blob_hash"
    else
        [ "$blob_hash" = "$common_blob_hash" ] || fail "different common blob block: $preset"
    fi
done

if command -v python3 >/dev/null 2>&1; then
    import_source="$TMP_ROOT/import-source"
    import_destination="$TMP_ROOT/import-package/presets"
    mkdir -p "$import_source"
    cp -R "$ROOT/zapret2" "$TMP_ROOT/import-package"
    printf '%s\n' \
        '--lua-init=@lua/fakemultisplit.lua' \
        '--lua-init=@lua/fakemultidisorder.lua' \
        '--name=Профиль с пробелом' \
        '--skip' \
        '--comment=portable marker' \
        '--ipcache-hostname=0' \
        '--filter-tcp=443' \
        '--filter-l7=tls' \
        '--in-range=-d10' \
        '--ipset=lists/russia-youtube-rtmps.txt' \
        '--lua-desync=pass' > "$import_source/Fixture.txt"
    printf '%s\n' \
        '--lua-init=@lua/fakemultisplit.lua' \
        '--blob=a:0x00' \
        '--name=Blob A' \
        '--filter-tcp=443' \
        '--lua-desync=fake:blob=a' > "$import_source/BlobA.txt"
    printf '%s\n' \
        '--lua-init=@lua/fakemultisplit.lua' \
        '--blob=b:0x01' \
        '--name=Blob B' \
        '--filter-udp=443' \
        '--lua-desync=fake:blob=b' > "$import_source/BlobB.txt"
    python3 "$ROOT/zapret2/scripts/sync-winws2-presets.py" \
        "$import_source" --destination "$import_destination" >/dev/null
    grep -Fxq -- '--name=Профиль с пробелом' "$import_destination/Fixture.txt" || fail "importer removed profile name"
    grep -Fxq -- '--skip' "$import_destination/Fixture.txt" || fail "importer removed profile skip"
    grep -Fxq -- '--comment=portable marker' "$import_destination/Fixture.txt" || fail "importer removed nfqws2 comment"
    grep -Fxq -- '--filter-l7=tls' "$import_destination/Fixture.txt" || fail "importer removed TLS L7 filter"
    grep -Fxq -- '--in-range=-d10' "$import_destination/Fixture.txt" || fail "importer removed portable inbound range"
    grep -Fxq -- '--lua-init=@lua/fakemultisplit.lua' "$import_destination/Fixture.txt" || fail "importer removed Android fakemultisplit"
    grep -Fxq -- '--lua-init=@lua/fakemultidisorder.lua' "$import_destination/Fixture.txt" || fail "importer removed Android fakemultidisorder"
    if grep -Fq -- '--ipcache' "$import_destination/Fixture.txt"; then fail "importer preserved ipcache"; fi
    grep -Fxq -- '--ipset=lists/ipset-russia-youtube-rtmps.txt' \
        "$import_destination/Fixture.txt" || fail "importer did not normalize Android list name"
    for imported_preset in "$import_destination"/*.txt; do
        grep -Fxq -- '--blob=a:0x00' "$imported_preset" || fail "importer did not propagate common blob a"
        grep -Fxq -- '--blob=b:0x01' "$imported_preset" || fail "importer did not propagate common blob b"
    done
    invalid_source="$TMP_ROOT/import-runtime-invalid"
    mkdir -p "$invalid_source"
    printf '%s\n' \
        '--lua-init=@lua/fakemultisplit.lua' \
        '--blob=x:0x00' \
        '--name=Rejected by runtime validator' \
        '--filter-tcp=443' \
        '--definitely-not-an-nfqws2-option=1' \
        '--lua-desync=pass' > "$invalid_source/Rejected.txt"
    if python3 "$ROOT/zapret2/scripts/sync-winws2-presets.py" \
        "$invalid_source" --destination "$import_destination" >/dev/null 2>&1; then
        fail "importer published a preset rejected by the runtime validator"
    fi
    [ ! -e "$import_destination/Rejected.txt" ] || fail "rejected import reached the published catalog"
    if find "$import_destination" -maxdepth 1 -name '_import-validation-*' -print -quit | grep -q .; then
        fail "importer left a validation candidate behind"
    fi
    conflict_source="$TMP_ROOT/import-conflict"
    conflict_destination="$TMP_ROOT/import-conflict-package/presets"
    mkdir -p "$conflict_source" "$conflict_destination"
    printf '%s\n' '--lua-init=@lua/fakemultisplit.lua' '--blob=same:0x00' '--name=One' '--filter-tcp=443' '--lua-desync=pass' > "$conflict_source/One.txt"
    printf '%s\n' '--lua-init=@lua/fakemultisplit.lua' '--blob=same:0x01' '--name=Two' '--filter-tcp=443' '--lua-desync=pass' > "$conflict_source/Two.txt"
    if python3 "$ROOT/zapret2/scripts/sync-winws2-presets.py" \
        "$conflict_source" --destination "$conflict_destination" >/dev/null 2>&1; then
        fail "importer accepted conflicting common blob definitions"
    fi
elif [ -x /system/bin/getprop ]; then
    echo "Preset importer contract skipped on Android (python3 host tool)"
else
    fail "python3 is required for the preset importer contract"
fi

scan="$TMP_ROOT/repository-preset-scan"
sh "$ROOT/zapret2/scripts/command-builder.sh" --scan-presets-machine "$ROOT/zapret2" > "$scan"
[ "$(awk -F '\t' '$1 == "Z2_PRESET" && $2 == "VALID" { n++ } END { print n+0 }' "$scan")" -eq 98 ] || fail "scanner valid count"
[ "$(awk -F '\t' '$1 == "Z2_PRESET" && $2 == "QUARANTINED" { n++ } END { print n+0 }' "$scan")" -eq 0 ] || fail "scanner quarantined count"
grep -Fq 'valid=98' "$scan" || fail "scanner summary valid count"
grep -Fq 'quarantined=0' "$scan" || fail "scanner summary quarantined count"
grep -Fq 'total=98' "$scan" || fail "scanner summary total count"

. "$ROOT/zapret2/scripts/package-contract.sh"
package_contract_validate_manifest "$ROOT" || fail "manifest invalid: $PACKAGE_CONTRACT_CODE $PACKAGE_CONTRACT_DETAIL"
# The checkout belongs to the CI runner, while machine catalog validation
# intentionally accepts only root-owned installed files. The complete catalog
# is therefore validated below against the assembled root-owned package tree,
# not against source-control ownership metadata.
utf8_two_byte="$(printf '\303\251')"
utf8_safe_name=
utf8_name_index=0
while [ "$utf8_name_index" -lt 125 ]; do
    utf8_safe_name="${utf8_safe_name}${utf8_two_byte}"
    utf8_name_index=$((utf8_name_index + 1))
done
package_contract_safe_preset_name "a${utf8_safe_name}.txt" || fail "255-byte preset name rejected"
for unsafe_preset_name in \
    "${utf8_safe_name}${utf8_two_byte}.txt" 'UPPER.TXT' '_internal.txt' 'bad"name.txt' "bad'name.txt"
do
    if package_contract_safe_preset_name "$unsafe_preset_name"; then
        fail "unsafe package preset name accepted: $unsafe_preset_name"
    fi
done
if package_contract_safe_relative_path "zapret2/${utf8_safe_name}${utf8_two_byte}xxxx"; then
    fail "overlong manifest path component accepted"
fi

candidate_root="$TMP_ROOT/preset-candidate-root"
mkdir -p "$candidate_root/presets" "$candidate_root/lua" "$candidate_root/bin" "$candidate_root/lists"
printf 'lua\n' > "$candidate_root/lua/core.lua"
printf 'blob\n' > "$candidate_root/bin/blob.bin"
printf 'example.com\n' > "$candidate_root/lists/list.txt"
candidate="$candidate_root/presets/_Safe.candidate.1.txt"
write_valid_candidate() {
    printf '%s\n' \
        '# NFQWS2_TCP_PKT_OUT=20' \
        '# NFQWS2_TCP_PKT_IN=10' \
        '# NFQWS2_UDP_PKT_OUT=20' \
        '# NFQWS2_UDP_PKT_IN=10' \
        '--lua-init=@lua/core.lua' \
        '--blob=x:@bin/blob.bin' \
        '--name=Safe profile' \
        '--filter-tcp=443' \
        '--hostlist=lists/list.txt' \
        '--lua-desync=pass' > "$candidate"
}
validate_candidate() {
    sh "$ROOT/zapret2/scripts/command-builder.sh" --validate-preset-machine "$candidate_root" "$candidate" 'Safe.txt'
}
write_valid_candidate
validate_candidate | grep -Fq 'Z2_PRESET_VALIDATION' || fail "valid candidate rejected"

# These are native nfqws2 options, not editor metadata.  A custom TXT must be
# accepted without deleting or rewriting them merely because the built-in
# catalog happened to use a smaller L7 subset.
write_valid_candidate
sed -i \
    -e '/^--lua-init=/i --comment=Imported nfqws2 strategy' \
    -e '/^--filter-tcp=/a --filter-l7=tls\n--in-range=-d10\n--comment' \
    "$candidate"
validate_candidate >/dev/null || fail "nfqws2 comment/TLS strategy was rejected"

# Upstream does not require blob declarations when the selected Lua strategy
# does not reference one.
write_valid_candidate
sed -i '/^--blob=/d' "$candidate"
validate_candidate >/dev/null || fail "blob-free native nfqws2 strategy was rejected"

# A file copied directly from native/legacy nfqws2 has neither Android packet
# metadata nor mandatory profile names. Runtime compilation supplies only the
# wrapper packet-budget default and leaves native arguments unchanged.
printf '%s\n' \
    '--lua-init=@lua/core.lua' \
    '--filter-tcp=443' \
    '--filter-l7=tls' \
    '--comment=legacy profile' \
    '--lua-desync=pass' \
    '--new=Native UDP' \
    '--filter-udp=443' \
    '--lua-desync=pass' > "$candidate"
validate_candidate >/dev/null || fail "unnamed legacy/native nfqws2 preset was rejected"

write_valid_candidate
sed -i '/^--filter-tcp=/a --filter-l7=all,unknown,known,http,tls,dtls,quic,wireguard,dht,discord,stun,xmpp,dns,mtproto,bt,utp_bt' \
    "$candidate"
validate_candidate >/dev/null || fail "reviewed upstream L7 protocol set was rejected"

write_valid_candidate
sed -i 's/--filter-tcp=443/--filter-tcp=~443/' "$candidate"
validate_candidate >/dev/null || fail "upstream negated port filter was rejected"
capture_output="$({
    ZAPRET_DIR="$candidate_root"
    export ZAPRET_DIR
    . "$ROOT/zapret2/scripts/command-builder.sh"
    collect_capture_ports "$candidate"
    printf 'TCP=%s\nUDP=%s\n' "$COMPILED_TCP_PORTS" "$COMPILED_UDP_PORTS"
} 2>&1)" || fail "negated port capture could not be derived: $capture_output"
printf '%s\n' "$capture_output" | grep -Fxq 'TCP=1:442,444:65535' ||
    fail "negated port capture was not the exact complement: $capture_output"

write_valid_candidate
sed -i '/^--filter-tcp=/a --filter-l7=not-an-upstream-protocol' "$candidate"
assert_invalid_code INVALID_FILTER validate_candidate
write_valid_candidate
sed -i 's/--filter-tcp=443/--filter-tcp=80:443/' "$candidate"
assert_invalid_code INVALID_FILTER validate_candidate

printf '%s\n' '--ipcache-hostname=0' > "$candidate"
assert_invalid_code FORBIDDEN_IPCACHE_OPTION validate_candidate
printf '%s\n' '--ipcache-lifetime=1' > "$candidate"
assert_invalid_code FORBIDDEN_IPCACHE_OPTION validate_candidate
write_valid_candidate
sed -i 's/--lua-desync=pass/--lua-desync=fake:blob=missing/' "$candidate"
assert_invalid_code BLOB_REFERENCE_MISSING validate_candidate
write_valid_candidate
sed -i 's/--lua-desync=pass/--lua-desync=fake:blob=fake_default_tls/' "$candidate"
validate_candidate >/dev/null || fail "built-in nfqws blob was rejected"
printf '%s\n' '--lua-init=@lua/../core.lua' > "$candidate"
assert_invalid_code UNSAFE_DEPENDENCY_PATH validate_candidate
printf '%s\n' '--lua-init=@/absolute.lua' > "$candidate"
assert_invalid_code UNSAFE_DEPENDENCY_PATH validate_candidate
printf '%s\n' '--lua-init=@lua/missing.lua' > "$candidate"
assert_invalid_code DEPENDENCY_MISSING validate_candidate
: > "$candidate_root/lua/empty.lua"
printf '%s\n' '--lua-init=@lua/empty.lua' > "$candidate"
assert_invalid_code DEPENDENCY_EMPTY validate_candidate
rm -f "$candidate_root/lua/empty.lua"
ln -s core.lua "$candidate_root/lua/link.lua"
printf '%s\n' '--lua-init=@lua/link.lua' > "$candidate"
assert_invalid_code DEPENDENCY_SYMLINK validate_candidate
rm -f "$candidate_root/lua/link.lua"
cp "$candidate_root/lua/core.lua" "$candidate_root/lua/unreadable.lua"
chmod 000 "$candidate_root/lua/unreadable.lua"
if [ ! -r "$candidate_root/lua/unreadable.lua" ]; then
    printf '%s\n' '--lua-init=@lua/unreadable.lua' > "$candidate"
    assert_invalid_code DEPENDENCY_UNREADABLE validate_candidate
fi
chmod 0644 "$candidate_root/lua/unreadable.lua"
: > "$candidate"
assert_invalid_code PRESET_EMPTY validate_candidate
write_valid_candidate
assert_invalid_code PRESET_NOT_DIRECT_CHILD sh "$ROOT/zapret2/scripts/command-builder.sh" \
    --validate-preset-machine "$candidate_root" "$candidate_root/nested/Safe.txt" 'Safe.txt'
assert_invalid_code UNSAFE_PRESET_NAME sh "$ROOT/zapret2/scripts/command-builder.sh" \
    --validate-preset-machine "$candidate_root" "$candidate" '../Safe.txt'
assert_invalid_code UNSAFE_PRESET_NAME sh "$ROOT/zapret2/scripts/command-builder.sh" \
    --validate-preset-machine "$candidate_root" "$candidate" "${utf8_safe_name}${utf8_two_byte}.txt"

declared="$TMP_ROOT/declared-dependencies"
printf '%s\n' 'zapret2/lua/core.lua' > "$declared"
write_valid_candidate
PRESET_ALLOWED_DEPENDENCIES_FILE="$declared"
export PRESET_ALLOWED_DEPENDENCIES_FILE
assert_invalid_code DEPENDENCY_NOT_DECLARED validate_candidate
unset PRESET_ALLOWED_DEPENDENCIES_FILE

source_root="$TMP_ROOT/manifest-source"
package_root="$TMP_ROOT/manifest-package"
mkdir -p "$source_root" "$package_root"
cp "$ROOT/module.prop" "$ROOT/customize.sh" "$ROOT/service.sh" "$ROOT/post-fs-data.sh" \
    "$ROOT/uninstall.sh" "$ROOT/action.sh" "$source_root/"
cp -R "$ROOT/system" "$ROOT/zapret2" "$source_root/"
printf '%064d\n' 0 > "$source_root/zapret2/upstream-zapret2.commit"
printf '%s\n' v0.0.0 > "$source_root/zapret2/upstream-zapret2.release"
printf '%064d\n' 0 > "$source_root/zapret2/upstream-zapret2.archive.sha256"
mkdir -p "$source_root/zapret2/bin/arm64-v8a" "$source_root/zapret2/bin/armeabi-v7a"
cp /bin/true "$source_root/zapret2/bin/arm64-v8a/nfqws2"
cp /bin/true "$source_root/zapret2/bin/armeabi-v7a/nfqws2"
package_contract_assemble_package "$source_root" "$package_root" || fail "fixture assembly: $PACKAGE_CONTRACT_CODE $PACKAGE_CONTRACT_DETAIL"
package_contract_validate_release_all "$package_root" package || fail "fixture package: $PACKAGE_CONTRACT_CODE $PACKAGE_CONTRACT_DETAIL"
package_contract_validate_exact_tree "$package_root" package || fail "fixture exact tree: $PACKAGE_CONTRACT_CODE $PACKAGE_CONTRACT_DETAIL"
package_contract_validate_modes "$package_root" package || fail "fixture modes: $PACKAGE_CONTRACT_CODE $PACKAGE_CONTRACT_DETAIL"
cp "$package_root/zapret2/runtime-manifest.tsv" "$TMP_ROOT/runtime-manifest.good"
printf '%s\n' 'immutable-file|0644|zapret2' >> "$package_root/zapret2/runtime-manifest.tsv"
if package_contract_validate_manifest "$package_root"; then fail "manifest file/child collision accepted"; fi
[ "$PACKAGE_CONTRACT_CODE" = MANIFEST_PATH_COLLISION ] || fail "wrong manifest collision failure: $PACKAGE_CONTRACT_CODE"
cp "$TMP_ROOT/runtime-manifest.good" "$package_root/zapret2/runtime-manifest.tsv"

installed_root="$TMP_ROOT/installed-runtime-selection"
cp -R "$package_root" "$installed_root"
rm -f "$installed_root/customize.sh"
cp "$installed_root/zapret2/bin/arm64-v8a/nfqws2" "$installed_root/zapret2/nfqws2"
chmod 0755 "$installed_root/zapret2/nfqws2"
custom_preset="$installed_root/zapret2/presets/My custom.txt"
cp "$installed_root/zapret2/presets/Default v1 (game filter).txt" "$custom_preset"
printf '%s\n' '# user-owned preset' >> "$custom_preset"
chmod 0644 "$custom_preset"
sed -i 's/^active_preset=.*/active_preset=My custom.txt/' "$installed_root/zapret2/runtime.ini"
package_contract_validate_tree "$installed_root" installed || fail "configured custom preset rejected: $PACKAGE_CONTRACT_CODE $PACKAGE_CONTRACT_DETAIL"
package_contract_validate_catalog "$installed_root" || fail "valid custom preset rejected: $PACKAGE_CONTRACT_CODE $PACKAGE_CONTRACT_DETAIL"
package_contract_validate_exact_tree "$installed_root" installed || fail "custom preset omitted from installed closure: $PACKAGE_CONTRACT_CODE $PACKAGE_CONTRACT_DETAIL"
cp "$custom_preset" "$TMP_ROOT/custom-preset.good"
printf '%s\n' '--ipcache-hostname=1' > "$custom_preset"
if package_contract_validate_catalog "$installed_root"; then fail "invalid custom preset accepted"; fi
[ "$PACKAGE_CONTRACT_CODE" = PRESET_INVALID ] || fail "wrong custom preset failure: $PACKAGE_CONTRACT_CODE"
cp "$TMP_ROOT/custom-preset.good" "$custom_preset"
rm -f "$custom_preset"
if package_contract_validate_tree "$installed_root" installed; then fail "missing active preset accepted"; fi
[ "$PACKAGE_CONTRACT_CODE" = RUNTIME_PRESET_UNSAFE ] || fail "wrong active preset failure: $PACKAGE_CONTRACT_CODE"
cp "$package_root/zapret2/scripts/command-builder.sh" "$TMP_ROOT/command-builder.good"
printf '\r\n' >> "$package_root/zapret2/scripts/command-builder.sh"
if package_contract_validate_release_all "$package_root" package; then fail "CRLF shell executable accepted"; fi
[ "$PACKAGE_CONTRACT_CODE" = SHELL_EXEC_CR ] || fail "wrong shell executable failure: $PACKAGE_CONTRACT_CODE"
cp "$TMP_ROOT/command-builder.good" "$package_root/zapret2/scripts/command-builder.sh"

if command -v zip >/dev/null 2>&1 && command -v zipinfo >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    archive="$TMP_ROOT/manifest-package.zip"
    (cd "$package_root" && zip -qr "$archive" .)
    names="$TMP_ROOT/manifest-package.names"
    zipinfo -1 "$archive" > "$names"
    package_contract_validate_zip_names "$package_root" "$names" || fail "fixture ZIP names: $PACKAGE_CONTRACT_CODE $PACKAGE_CONTRACT_DETAIL"
    printf '%s\n' 'META-INF' 'META-INF/child' >> "$names"
    if package_contract_validate_zip_names "$package_root" "$names"; then fail "ZIP file/child collision accepted"; fi
    [ "$PACKAGE_CONTRACT_CODE" = ZIP_PATH_COLLISION ] || fail "wrong ZIP collision failure: $PACKAGE_CONTRACT_CODE"
    zipinfo -1 "$archive" > "$names"
    printf '%s\n' 'META-INF/child' 'META-INF' >> "$names"
    if package_contract_validate_zip_names "$package_root" "$names"; then fail "reverse-order ZIP file/child collision accepted"; fi
    [ "$PACKAGE_CONTRACT_CODE" = ZIP_PATH_COLLISION ] || fail "wrong reverse ZIP collision failure: $PACKAGE_CONTRACT_CODE"
    zipinfo -1 "$archive" > "$names"
    printf '%s\n' 'META-INF/' 'META-INF/' >> "$names"
    if package_contract_validate_zip_names "$package_root" "$names"; then fail "duplicate ZIP directory accepted"; fi
    [ "$PACKAGE_CONTRACT_CODE" = ZIP_DUPLICATE_ENTRY ] || fail "wrong duplicate ZIP failure: $PACKAGE_CONTRACT_CODE"
    zipinfo -1 "$archive" > "$names"
    printf '%s\n' rogue > "$package_root/undeclared.txt"
    (cd "$package_root" && zip -q "$archive" undeclared.txt)
    zipinfo -1 "$archive" > "$names"
    if package_contract_validate_zip_names "$package_root" "$names"; then fail "undeclared ZIP entry accepted"; fi
    zip -qd "$archive" undeclared.txt
    rm -f "$package_root/undeclared.txt"
    zipinfo -1 "$archive" > "$names"
    extracted="$TMP_ROOT/manifest-package-extracted"
    mkdir -p "$extracted"
    unzip -q "$archive" -d "$extracted"
    package_contract_validate_release_all "$extracted" package || fail "fixture ZIP content: $PACKAGE_CONTRACT_CODE $PACKAGE_CONTRACT_DETAIL"
    package_contract_validate_exact_tree "$extracted" package || fail "fixture ZIP exact tree: $PACKAGE_CONTRACT_CODE $PACKAGE_CONTRACT_DETAIL"
    printf '%s\n' rogue > "$extracted/zapret2/undeclared.txt"
    if package_contract_validate_exact_tree "$extracted" package; then fail "undeclared extracted entry accepted"; fi
    rm -f "$extracted/zapret2/undeclared.txt"
    package_contract_validate_modes "$extracted" package || fail "fixture ZIP modes: $PACKAGE_CONTRACT_CODE $PACKAGE_CONTRACT_DETAIL"
fi

rm -f "$package_root/zapret2/lua/zapret-auto.lua"
if package_contract_validate_tree "$package_root" package; then fail "missing zapret-auto accepted"; fi

echo "Preset and runtime manifest contract tests passed"
