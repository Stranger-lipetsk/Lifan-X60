#!/system/bin/sh
# Experimental, manually invoked helper. NOT connected to boot or included in firmware.
# Default is dry-run; --install also requires --confirm-desktop.
# The supplied package-to-SHA mapping MUST be verified offline before use.
set -u

usage() {
    echo 'usage: one_apk_install.sh [--install --confirm-desktop] APK PACKAGE SHA256' >&2
    exit 2
}
fail() { echo "ERROR: $*" >&2; exit 1; }

INSTALL=0
CONFIRM=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --install) INSTALL=1; shift ;;
        --confirm-desktop) CONFIRM=1; shift ;;
        --*) usage ;;
        *) break ;;
    esac
done
[ "$#" -eq 3 ] || usage
APK=$1
PACKAGE=$2
EXPECTED=$(printf '%s' "$3" | tr 'A-F' 'a-f')
case "$PACKAGE" in
    ''|*[!A-Za-z0-9_.]*|.*|*..*|*.) fail 'invalid package name' ;;
esac
[ ${#EXPECTED} -eq 64 ] || fail 'SHA-256 must be 64 hex characters'
case "$EXPECTED" in *[!0-9a-f]*) fail 'invalid SHA-256' ;; esac
[ -f "$APK" ] && [ -r "$APK" ] || fail 'APK unavailable'
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum unavailable; do not install'
HASH_LINE=$(sha256sum "$APK") || fail 'hash calculation failed'
ACTUAL=${HASH_LINE%% *}
ACTUAL=$(printf '%s' "$ACTUAL" | tr 'A-F' 'a-f')
[ "$ACTUAL" = "$EXPECTED" ] || fail 'APK hash mismatch'
[ "$(id -u)" = 0 ] || fail 'not running as root'
[ "$(getprop sys.boot_completed)" = 1 ] || fail 'Android boot not marked complete'
PACKAGES=$(pm list packages 2>&1) || fail 'package manager unavailable'
printf '%s\n' "$PACKAGES" | grep -q '^package:' || fail 'unexpected package manager response'
if printf '%s\n' "$PACKAGES" | grep -F -x -q "package:$PACKAGE"; then
    fail 'package already installed; updates and replacement are forbidden'
fi
if [ "$INSTALL" -eq 0 ]; then
    echo "DRY RUN: hash matches, package absent; no installation performed: $PACKAGE"
    exit 0
fi
[ "$CONFIRM" -eq 1 ] || fail 'explicit desktop confirmation required'
# No -r: no update/replacement; no uninstall or clearing of app data.
OUTPUT=$(pm install "$APK" 2>&1) || { echo "$OUTPUT" >&2; fail 'pm install returned an error'; }
printf '%s\n' "$OUTPUT"
printf '%s\n' "$OUTPUT" | grep -q '^Success' || fail 'pm did not report Success'
PATH_OUT=$(pm path "$PACKAGE" 2>&1) || fail 'cannot verify installed package'
printf '%s\n' "$PATH_OUT" | grep -q '^package:' || fail 'expected package not found after install'
echo "Installed package confirmed: $PACKAGE"
