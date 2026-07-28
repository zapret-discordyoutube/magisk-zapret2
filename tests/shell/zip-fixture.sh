#!/bin/sh

# Test-only ZIP fixture writer. Android root-manager busybox provides unzip and
# crc32 but no zip applet. Store entries without compression when a host zip
# command is unavailable; installer tests care about exact package contents,
# not the compression method.

z2_test_zip_emit_le() {
    z2_zip_value="$1"
    z2_zip_bytes="$2"
    while [ "$z2_zip_bytes" -gt 0 ]; do
        z2_zip_byte=$((z2_zip_value % 256))
        z2_zip_octal="$(printf '%03o' "$z2_zip_byte")"
        printf "\\$z2_zip_octal"
        z2_zip_value=$((z2_zip_value / 256))
        z2_zip_bytes=$((z2_zip_bytes - 1))
    done
}

z2_test_zip_crc32() {
    if command -v crc32 >/dev/null 2>&1; then
        crc32 "$1"
        return
    fi
    if command -v busybox >/dev/null 2>&1; then
        busybox crc32 "$1"
        return
    fi
    return 1
}

z2_test_create_store_zip() {
    z2_zip_archive="$1"
    shift
    z2_zip_manifest="$z2_zip_archive.manifest.$$"
    z2_zip_central="$z2_zip_archive.central.$$"
    : > "$z2_zip_manifest" || return 1
    : > "$z2_zip_central" || {
        rm -f "$z2_zip_manifest"
        return 1
    }
    for z2_zip_input in "$@"; do
        if [ -f "$z2_zip_input" ] && [ ! -L "$z2_zip_input" ]; then
            printf '%s\n' "$z2_zip_input"
        elif [ -d "$z2_zip_input" ] && [ ! -L "$z2_zip_input" ]; then
            find "$z2_zip_input" -type f ! -type l -print
        else
            rm -f "$z2_zip_manifest" "$z2_zip_central"
            return 1
        fi
    # `find .` yields ./-prefixed paths while zip(1) does not, and the archive
    # names have to match whichever implementation ran.
    done | sed 's|^\./||' | LC_ALL=C sort > "$z2_zip_manifest" || {
        rm -f "$z2_zip_manifest" "$z2_zip_central"
        return 1
    }

    : > "$z2_zip_archive" || {
        rm -f "$z2_zip_manifest" "$z2_zip_central"
        return 1
    }
    z2_zip_offset=0
    z2_zip_count=0
    while IFS= read -r z2_zip_name || [ -n "$z2_zip_name" ]; do
        [ -n "$z2_zip_name" ] || continue
        z2_zip_size="$(wc -c < "$z2_zip_name")" || return 1
        z2_zip_name_size="$(printf '%s' "$z2_zip_name" | wc -c)" || return 1
        z2_zip_crc="$(z2_test_zip_crc32 "$z2_zip_name")" || return 1
        z2_zip_crc="${z2_zip_crc%% *}"
        case "$z2_zip_crc" in
            ""|*[!0-9A-Fa-f]*) return 1 ;;
        esac
        z2_zip_crc_value=$((0x$z2_zip_crc))

        {
            printf '\120\113\003\004'
            z2_test_zip_emit_le 20 2
            z2_test_zip_emit_le 2048 2
            z2_test_zip_emit_le 0 2
            z2_test_zip_emit_le 0 2
            z2_test_zip_emit_le 0 2
            z2_test_zip_emit_le "$z2_zip_crc_value" 4
            z2_test_zip_emit_le "$z2_zip_size" 4
            z2_test_zip_emit_le "$z2_zip_size" 4
            z2_test_zip_emit_le "$z2_zip_name_size" 2
            z2_test_zip_emit_le 0 2
            printf '%s' "$z2_zip_name"
            cat "$z2_zip_name"
        } >> "$z2_zip_archive" || return 1

        {
            printf '\120\113\001\002'
            z2_test_zip_emit_le 20 2
            z2_test_zip_emit_le 20 2
            z2_test_zip_emit_le 2048 2
            z2_test_zip_emit_le 0 2
            z2_test_zip_emit_le 0 2
            z2_test_zip_emit_le 0 2
            z2_test_zip_emit_le "$z2_zip_crc_value" 4
            z2_test_zip_emit_le "$z2_zip_size" 4
            z2_test_zip_emit_le "$z2_zip_size" 4
            z2_test_zip_emit_le "$z2_zip_name_size" 2
            z2_test_zip_emit_le 0 2
            z2_test_zip_emit_le 0 2
            z2_test_zip_emit_le 0 2
            z2_test_zip_emit_le 0 2
            z2_test_zip_emit_le 0 4
            z2_test_zip_emit_le "$z2_zip_offset" 4
            printf '%s' "$z2_zip_name"
        } >> "$z2_zip_central" || return 1

        z2_zip_offset=$((z2_zip_offset + 30 + z2_zip_name_size + z2_zip_size))
        z2_zip_count=$((z2_zip_count + 1))
    done < "$z2_zip_manifest"

    z2_zip_central_size="$(wc -c < "$z2_zip_central")" || return 1
    cat "$z2_zip_central" >> "$z2_zip_archive" || return 1
    {
        printf '\120\113\005\006'
        z2_test_zip_emit_le 0 2
        z2_test_zip_emit_le 0 2
        z2_test_zip_emit_le "$z2_zip_count" 2
        z2_test_zip_emit_le "$z2_zip_count" 2
        z2_test_zip_emit_le "$z2_zip_central_size" 4
        z2_test_zip_emit_le "$z2_zip_offset" 4
        z2_test_zip_emit_le 0 2
    } >> "$z2_zip_archive" || return 1
    rm -f "$z2_zip_manifest" "$z2_zip_central"
}

z2_test_create_zip() {
    z2_zip_archive="$1"
    shift
    if command -v zip >/dev/null 2>&1; then
        zip -qr "$z2_zip_archive" "$@"
    else
        z2_test_create_store_zip "$z2_zip_archive" "$@"
    fi
}
