#!/system/bin/sh
##########################################################################################
# Zapret2 root module - post-fs-data script (runs before the framework starts)
##########################################################################################
# The DNS manager's hosts file is published from /data by a bind mount this
# module owns, so it has to be mounted before anything resolves a name. Nothing
# else belongs here: the firewall lifecycle needs a completed boot and stays in
# service.sh.

MODDIR="${0%/*}"
HOSTS_SCRIPT="$MODDIR/zapret2/scripts/hosts-overlay.sh"

[ -f "$HOSTS_SCRIPT" ] && [ ! -L "$HOSTS_SCRIPT" ] || {
    /system/bin/log -p e -t "Zapret2" "Hosts publication helper is unavailable; DNS entries were not mounted" 2>/dev/null
    exit 0
}

# A hosts failure must never hold up the boot: this stage blocks the framework.
/system/bin/sh "$HOSTS_SCRIPT" --boot || exit 0
exit 0
