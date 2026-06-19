#!/bin/bash
# Stops and removes the RAMWatcher LaunchDaemon. Requires sudo.
#
#   sudo ./Scripts/uninstall_daemon.sh
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "This script must be run with sudo: sudo ./Scripts/uninstall_daemon.sh" >&2
    exit 1
fi

PLIST_DEST="/Library/LaunchDaemons/com.himanshu.ramwatcher.daemon.plist"
INSTALL_DIR="/usr/local/libexec/ramwatcher"
LABEL="com.himanshu.ramwatcher.daemon"

echo "==> Stopping daemon"
launchctl bootout system "$PLIST_DEST" 2>/dev/null || true

echo "==> Removing files"
rm -f "$PLIST_DEST"
rm -rf "$INSTALL_DIR"
rm -f /var/run/ramwatcher.sock
rm -f /var/log/ramwatcher-daemon.log

echo "Done. RAMWatcher daemon removed."
