#!/bin/bash
# Builds release binaries and assembles:
#   dist/RAMWatcher.app           (menu bar UI, ad-hoc signed, ready to double-click)
#   dist/RAMWatcherDaemon         (privileged daemon binary, NOT installed by this script)
#
# This script does not require sudo and does not touch any system
# location. Installing the daemon as a LaunchDaemon is a separate,
# explicit step: run Scripts/install_daemon.sh yourself.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Building release binaries"
swift build -c release

BUILD_BIN_DIR="$(swift build -c release --show-bin-path)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/RAMWatcher.app"

rm -rf "$DIST_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

echo "==> Assembling RAMWatcher.app"
cp "$BUILD_BIN_DIR/RAMWatcherApp" "$APP_DIR/Contents/MacOS/RAMWatcherApp"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "==> Ad-hoc codesigning the app (personal use, no Developer account needed)"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Staging daemon binary for manual install"
cp "$BUILD_BIN_DIR/RAMWatcherDaemon" "$DIST_DIR/RAMWatcherDaemon"
codesign --force --sign - "$DIST_DIR/RAMWatcherDaemon"

echo ""
echo "Done. Built:"
echo "  $APP_DIR"
echo "  $DIST_DIR/RAMWatcherDaemon"
echo ""
echo "Next steps:"
echo "  1. Open $APP_DIR to run the menu bar UI (it will show 'daemon not running' until step 2)."
echo "  2. Run: sudo ./Scripts/install_daemon.sh    (installs + starts the privileged daemon)"
