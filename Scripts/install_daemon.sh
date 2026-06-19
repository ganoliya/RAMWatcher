#!/bin/bash
# Installs and starts the privileged RAMWatcher daemon as a LaunchDaemon.
# Requires sudo. Run this yourself after Scripts/build_app.sh:
#
#   sudo ./Scripts/install_daemon.sh
#
# This is the only step in the whole project that touches system state
# (a LaunchDaemon under root, reading other users' process memory, and
# being able to send signals to other users'/system processes). It is
# intentionally not run automatically by any other script or by Claude.
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "This script must be run with sudo: sudo ./Scripts/install_daemon.sh" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
DAEMON_BIN_SRC="$DIST_DIR/RAMWatcherDaemon"
INSTALL_DIR="/usr/local/libexec/ramwatcher"
PLIST_SRC="$ROOT_DIR/Resources/com.himanshu.ramwatcher.daemon.plist"
PLIST_DEST="/Library/LaunchDaemons/com.himanshu.ramwatcher.daemon.plist"
LABEL="com.himanshu.ramwatcher.daemon"

if [[ ! -f "$DAEMON_BIN_SRC" ]]; then
    echo "Daemon binary not found at $DAEMON_BIN_SRC — run ./Scripts/build_app.sh first (without sudo)." >&2
    exit 1
fi

echo "==> Unloading any previous version of the daemon (ignore errors if not installed yet)"
launchctl bootout system "$PLIST_DEST" 2>/dev/null || true

echo "==> Installing daemon binary to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp "$DAEMON_BIN_SRC" "$INSTALL_DIR/RAMWatcherDaemon"
chown root:wheel "$INSTALL_DIR/RAMWatcherDaemon"
chmod 755 "$INSTALL_DIR/RAMWatcherDaemon"

echo "==> Installing LaunchDaemon plist to $PLIST_DEST"
cp "$PLIST_SRC" "$PLIST_DEST"
chown root:wheel "$PLIST_DEST"
chmod 644 "$PLIST_DEST"

echo "==> Bootstrapping the daemon via launchd"
launchctl bootstrap system "$PLIST_DEST"

sleep 1
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo ""
    echo "Daemon installed and running. Socket: /var/run/ramwatcher.sock"
    echo "Logs: /var/log/ramwatcher-daemon.log"
    echo "Open RAMWatcher.app (or relaunch it) to connect."
else
    echo ""
    echo "Daemon did not start — check /var/log/ramwatcher-daemon.log for details." >&2
    exit 1
fi
