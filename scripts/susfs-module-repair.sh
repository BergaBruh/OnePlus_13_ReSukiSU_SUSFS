#!/system/bin/sh
# Run with: su -c 'sh /sdcard/Download/susfs-module-repair.sh --repair'
# Default mode only reads device state. No support-marker overrides.
set -eu

BIN_DIR=/data/adb/ksu/bin
MODULE=/data/adb/modules/susfs4ksu
MARKER=/data/adb/ksu/susfs4ksu/logs/susfs_active
BIN="$BIN_DIR/ksu_susfs"
REF=041f69d7fe23a7bd928f9bd90eb3535774d00456
HASH=8a626ce3bae27a7bcaa2e7f5f7b91e786ecc57f8e57d19c7856719a89b54b6fa
URL="https://raw.githubusercontent.com/sidex15/susfs4ksu-binaries/$REF/ksu_susfs_arm64"

fail() { echo "ERROR: $*" >&2; exit 1; }
probe() {
    version=$("$1" show version) || return 1
    echo "Kernel SUSFS version: $version"
    [ "$version" = v2.3.0 ] || return 1
    features=$("$1" show enabled_features) || return 1
    printf '%s\n' "$features"
    printf '%s\n' "$features" | grep -qx 'CONFIG_KSU_SUSFS_SUS_PATH'
}

mode=${1:---diagnose}
case "$mode" in --diagnose|--repair) ;; *) fail 'Use --diagnose or --repair' ;; esac
[ "$(id -u)" = 0 ] || fail 'Run this script through su.'
echo "Kernel: $(uname -r)"
echo "Architecture: $(uname -m)"
echo "Mode: $mode"
if [ -f "$MARKER" ]; then echo 'Module boot marker: present'; else echo 'Module boot marker: missing'; fi
[ -d "$MODULE" ] || fail 'Install the SUSFS module in the root manager first.'
[ ! -f "$MODULE/disable" ] || fail 'Enable the SUSFS module and reboot first.'
[ ! -f "$MODULE/remove" ] || fail 'The SUSFS module is scheduled for removal.'
if [ -f "$BIN" ]; then
    ls -l "$BIN"
    if [ -x "$BIN" ] && probe "$BIN"; then
        echo 'The installed helper already communicates with SUSFS v2.3.0.'
        [ -f "$MARKER" ] || echo 'Boot marker is missing. Reboot to run module initialization; if it persists, collect module boot logs.'
        exit 0
    fi
else
    echo "Missing helper: $BIN"
fi
[ "$mode" = --repair ] || fail 'Helper check failed. --repair downloads and validates a pinned replacement.'
[ "$(uname -m)" = aarch64 ] || fail 'The replacement is for ARM64 only.'
[ -d "$BIN_DIR" ] || fail 'Root-manager bin directory is missing.'

candidate=$(mktemp "$BIN_DIR/.ksu_susfs.XXXXXX")
trap 'rm -f "$candidate"' EXIT HUP INT TERM
if command -v curl >/dev/null 2>&1; then
    curl --fail --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 180 --retry 3 \
        "$URL" -o "$candidate" || fail 'Download failed; installed helper was preserved.'
elif command -v busybox >/dev/null 2>&1; then
    busybox wget -T 60 -O "$candidate" "$URL" || fail 'Download failed; installed helper was preserved.'
else
    fail 'curl or busybox wget is required.'
fi
actual=$(sha256sum "$candidate")
actual=${actual%% *}
[ "$actual" = "$HASH" ] || fail 'SHA256 mismatch; installed helper was preserved.'
chmod 755 "$candidate"
probe "$candidate" || fail 'The verified helper cannot query SUSFS v2.3.0. Installed helper was preserved. Check the flashed kernel and root-manager compatibility.'

backup=
if [ -e "$BIN" ]; then
    backup=$(mktemp "$BIN_DIR/ksu_susfs.backup.XXXXXX")
    cp -p "$BIN" "$backup" || fail 'Backup failed; installed helper was preserved.'
    echo "Previous helper backup: $backup"
fi
mv -f "$candidate" "$BIN"
if ! probe "$BIN"; then
    if [ -n "$backup" ]; then mv -f "$backup" "$BIN"; else rm -f "$BIN"; fi
    fail 'Final API check failed; replacement was rolled back.'
fi
echo 'Helper repaired. Reboot the phone, then reopen the SUSFS WebUI.'
