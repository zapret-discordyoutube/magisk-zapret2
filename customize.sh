#!/system/bin/sh
SKIPUNZIP=1

# The active root manager owns publication in modules_update. This installer
# creates one fresh release generation and never reads, merges, stops, or
# replaces the live tree.

umask 077

[ "${BOOTMODE:-false}" = true ] ||
    abort "! Zapret2 must be installed from a running root manager"
case "${MODPATH:-}" in
    /*/modules_update/zapret2) ;;
    *) abort "! Unexpected module staging path: ${MODPATH:-missing}" ;;
esac
case "$MODPATH" in
    *//*|*/./*|*/../*) abort "! Unsafe module staging path: $MODPATH" ;;
esac
[ -d "$MODPATH" ] && [ ! -L "$MODPATH" ] ||
    abort "! Module staging directory is missing or unsafe"
[ -f "$ZIPFILE" ] && [ ! -L "$ZIPFILE" ] ||
    abort "! Module archive is missing or unsafe"

MODULE_STORAGE="${MODPATH%/modules_update/zapret2}"
[ "$MODULE_STORAGE" = /data/adb ] ||
    abort "! Unsupported root-manager module storage: $MODULE_STORAGE"
LIVE_MODPATH="$MODULE_STORAGE/modules/zapret2"
case "${APATCH:-false}:${KSU:-false}" in
    true:*) ROOT_MANAGER="APatch" ;;
    *:true) ROOT_MANAGER="KernelSU" ;;
    *) ROOT_MANAGER="Magisk" ;;
esac

# SKIPUNZIP leaves extraction to this script. Start with an empty, exact pending
# directory so a successful generation cannot inherit files from an earlier one.
find "$MODPATH" -mindepth 1 -maxdepth 1 -exec rm -rf {} + ||
    abort "! Cannot clear the module staging directory"
ui_print "- Extracting a fresh Zapret2 generation for $ROOT_MANAGER"
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2 ||
    abort "! Cannot extract module files"

# Surface anything that is neither a directory nor a regular file, then
# normalize canonical modes. Every find stays a single flat expression:
# Magisk's busybox find silently drops `-exec … +` actions that sit inside
# grouped `-o` alternations — it exits 0 having chmod'ed nothing.
UNSUPPORTED_ENTRY="$(find "$MODPATH" ! -type d ! -type f -print)" ||
    abort "! Cannot inspect the extracted module"
if [ -n "$UNSUPPORTED_ENTRY" ]; then
    # find uses lstat and the shell's -d/-f follow symlinks, so ask -L first:
    # a symlink to a directory or file is still a symlink, and reporting it as
    # a special file would send the packager hunting for something that does
    # not exist.
    UNSUPPORTED_FIRST="${UNSUPPORTED_ENTRY%%
*}"
    if [ -L "$UNSUPPORTED_FIRST" ]; then
        abort "! Extracted module contains a link: ${UNSUPPORTED_FIRST#"$MODPATH"/}"
    fi
    abort "! Extracted module contains a special file: ${UNSUPPORTED_FIRST#"$MODPATH"/}"
fi
find "$MODPATH" -type d -exec chmod 0755 {} + ||
    abort "! Cannot apply directory permissions"
find "$MODPATH" -type f -exec chmod 0644 {} + ||
    abort "! Cannot apply file permissions"
# The published-file contract (0644 files, 0755 directories) is what the app
# verifies before it reads catalogs and presets, so prove the modes landed
# instead of trusting the find implementation's exit status.
WRONG_MODE_ENTRY="$(find "$MODPATH" -type d ! -perm 0755 -print; find "$MODPATH" -type f ! -perm 0644 -print)" ||
    abort "! Cannot verify package permissions"
if [ -n "$WRONG_MODE_ENTRY" ]; then
    WRONG_MODE_FIRST="${WRONG_MODE_ENTRY%%
*}"
    abort "! Cannot apply package permissions to ${WRONG_MODE_FIRST#"$MODPATH"/}"
fi
[ "$(grep -c '^id=zapret2$' "$MODPATH/module.prop" 2>/dev/null)" = 1 ] ||
    abort "! Refusing package with unexpected module identity"

case "${ARCH:-}" in
    arm64) ARCH_DIR="arm64-v8a" ;;
    arm) ARCH_DIR="armeabi-v7a" ;;
    *) abort "! Unsupported architecture: ${ARCH:-unknown}" ;;
esac

ZAPRET_DIR="$MODPATH/zapret2"
SCRIPT_DIR="$ZAPRET_DIR/scripts"
NFQWS_SOURCE="$ZAPRET_DIR/bin/$ARCH_DIR/nfqws2"
NFQWS_TARGET="$ZAPRET_DIR/nfqws2"
NFQWS_TEMP="$ZAPRET_DIR/.nfqws2.install.$$"

for required in \
    "$MODPATH/module.prop" \
    "$MODPATH/service.sh" \
    "$MODPATH/post-fs-data.sh" \
    "$MODPATH/uninstall.sh" \
    "$MODPATH/action.sh" \
    "$ZAPRET_DIR/runtime-manifest.tsv" \
    "$ZAPRET_DIR/lifecycle-contract.version" \
    "$ZAPRET_DIR/upstream-zapret2.commit" \
    "$ZAPRET_DIR/upstream-zapret2.release" \
    "$ZAPRET_DIR/upstream-zapret2.archive.sha256" \
    "$ZAPRET_DIR/runtime.ini" \
    "$ZAPRET_DIR/hosts.ini" \
    "$SCRIPT_DIR/common.sh" \
    "$SCRIPT_DIR/command-builder.sh" \
    "$SCRIPT_DIR/hosts-overlay.sh" \
    "$SCRIPT_DIR/package-contract.sh" \
    "$SCRIPT_DIR/zapret-start.sh" \
    "$SCRIPT_DIR/zapret-stop.sh" \
    "$SCRIPT_DIR/zapret-status.sh" \
    "$NFQWS_SOURCE"; do
    [ -f "$required" ] && [ ! -L "$required" ] && [ -s "$required" ] ||
        abort "! Extracted module is incomplete: ${required#"$MODPATH"/}"
done

# Release CI owns exhaustive package validation; canonical modes were already
# normalized in the single traversal above.
chmod 0755 \
    "$MODPATH/customize.sh" \
    "$MODPATH/service.sh" \
    "$MODPATH/post-fs-data.sh" \
    "$MODPATH/uninstall.sh" \
    "$MODPATH/action.sh" \
    "$ZAPRET_DIR/bin/arm64-v8a/nfqws2" \
    "$ZAPRET_DIR/bin/armeabi-v7a/nfqws2" \
    "$SCRIPT_DIR/"*.sh \
    "$SCRIPT_DIR/lifecycle/"*.sh \
    "$MODPATH/system/bin/zapret2-"* ||
    abort "! Cannot apply executable permissions"

cp "$NFQWS_SOURCE" "$NFQWS_TEMP" &&
    chmod 0755 "$NFQWS_TEMP" &&
    mv "$NFQWS_TEMP" "$NFQWS_TARGET" || {
        rm -f "$NFQWS_TEMP"
        abort "! Cannot select the $ARCH_DIR nfqws2 binary"
    }

ARCHIVE_SHA256="$(sha256sum "$ZIPFILE" 2>/dev/null | awk 'NR == 1 { print $1 }')" ||
    abort "! Cannot identify the module archive"
case "$ARCHIVE_SHA256" in
    *[!0-9a-f]*|"") abort "! Module archive identity is invalid" ;;
esac
[ "${#ARCHIVE_SHA256}" -eq 64 ] 2>/dev/null ||
    abort "! Module archive identity is invalid"

GENERATION_FILE="$ZAPRET_DIR/install-generation.meta"
GENERATION_TEMP="$ZAPRET_DIR/.install-generation.meta.$$"
[ ! -e "$GENERATION_FILE" ] && [ ! -L "$GENERATION_FILE" ] ||
    abort "! Release unexpectedly contains installation state"
{
    printf 'version=1\n'
    printf 'module_dir=%s\n' "$LIVE_MODPATH"
    printf 'generation=%s\n' "$ARCHIVE_SHA256"
    printf 'archive_sha256=%s\n' "$ARCHIVE_SHA256"
} > "$GENERATION_TEMP" &&
    chmod 0600 "$GENERATION_TEMP" &&
    mv "$GENERATION_TEMP" "$GENERATION_FILE" ||
    abort "! Cannot publish installation generation"

# Every other executable was verified by the required-file loop and the
# explicit chmod above; only the arch-selected binary was created afterwards.
[ -f "$NFQWS_TARGET" ] && [ ! -L "$NFQWS_TARGET" ] &&
    [ -s "$NFQWS_TARGET" ] && [ -x "$NFQWS_TARGET" ] ||
    abort "! Prepared module is incomplete: ${NFQWS_TARGET#"$MODPATH"/}"

# Releases up to v2.2.5 published the DNS manager's hosts file inside the live
# module tree, which the root manager replaces wholesale on the next boot. This
# is the last moment that file still exists, so carry the user's selection over
# to the storage the new release publishes from. It is a rescue of user data
# out of a location that no longer holds it — the staged generation itself
# still inherits nothing from the live tree.
LEGACY_HOSTS="$LIVE_MODPATH/system/etc/hosts"
HOSTS_OVERLAY_DIR="/data/adb/zapret2-hosts"
HOSTS_OVERLAY_FILE="$HOSTS_OVERLAY_DIR/hosts"
if [ -f "$LEGACY_HOSTS" ] && [ ! -L "$LEGACY_HOSTS" ] &&
   [ ! -e "$HOSTS_OVERLAY_FILE" ] && [ ! -L "$HOSTS_OVERLAY_FILE" ] &&
   [ "$(stat -c %u "$LEGACY_HOSTS" 2>/dev/null)" = 0 ]; then
    LEGACY_HOSTS_BYTES="$(stat -c %s "$LEGACY_HOSTS" 2>/dev/null)"
    case "$LEGACY_HOSTS_BYTES" in
        ''|*[!0-9]*) LEGACY_HOSTS_BYTES=0 ;;
    esac
    if [ "$LEGACY_HOSTS_BYTES" -gt 0 ] && [ "$LEGACY_HOSTS_BYTES" -le 1048576 ]; then
        HOSTS_MIGRATION_TEMP="$HOSTS_OVERLAY_DIR/.hosts.migrate.$$"
        if mkdir -p "$HOSTS_OVERLAY_DIR" 2>/dev/null &&
            chmod 0755 "$HOSTS_OVERLAY_DIR" 2>/dev/null &&
            cp "$LEGACY_HOSTS" "$HOSTS_MIGRATION_TEMP" 2>/dev/null &&
            chmod 0644 "$HOSTS_MIGRATION_TEMP" 2>/dev/null &&
            mv -f "$HOSTS_MIGRATION_TEMP" "$HOSTS_OVERLAY_FILE" 2>/dev/null; then
            ui_print "- Carried the existing DNS hosts selection over to $HOSTS_OVERLAY_FILE"
        else
            rm -f "$HOSTS_MIGRATION_TEMP" 2>/dev/null
            ui_print "! Existing DNS hosts selection could not be carried over; re-apply it in the app"
        fi
    fi
fi

ui_print "- Fresh Zapret2 generation staged by $ROOT_MANAGER; reboot to activate it"
