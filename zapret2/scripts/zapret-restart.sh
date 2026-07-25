#!/system/bin/sh
# start --replace owns the single lifecycle lock and performs the transaction.

# The wrappers invoke this script by an absolute, already-canonical path, so
# resolving it costs two forks (dirname plus the cd/pwd subshell) to return the
# string we were handed. Take the cheap route when the path is already clean
# and keep the canonicalizing fallback for every other invocation.
case "$0" in
    /*//*|/*/./*|/*/../*|*/..|*/.) SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" ;;
    /*/*) SCRIPT_DIR="${0%/*}" ;;
    *) SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" ;;
esac
exec "$SCRIPT_DIR/zapret-start.sh" --replace "$@"
