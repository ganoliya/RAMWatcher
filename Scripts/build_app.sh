#!/bin/bash
# Builds release binaries and assembles dist/RAMWatcher.app as a single,
# self-contained app bundle:
#
#   RAMWatcher.app/
#     Contents/MacOS/RAMWatcherApp        (menu bar UI)
#     Contents/MacOS/RAMWatcherDaemon     (privileged daemon, embedded)
#     Contents/Library/LaunchDaemons/com.himanshu.ramwatcher.daemon.plist
#
# The daemon ships INSIDE the app bundle and registers itself via
# SMAppService when the app launches -- there is no separate install step
# for a fresh install. (Scripts/uninstall_daemon.sh still exists only to
# clean up the OLD pre-SMAppService manual installation, for anyone
# upgrading from that version.)
#
# Signing: if a "Developer ID Application" identity is present in the
# keychain, it's used (with the hardened runtime, required for
# notarization). Otherwise this falls back to ad-hoc signing, which is
# enough to run locally but NOT enough for SMAppService registration to
# work for anyone other than the machine that built it -- SMAppService
# requires a real Developer ID (or Mac App Store) signature.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"
if [[ -z "$IDENTITY" ]]; then
    echo "No 'Developer ID Application' identity found -- falling back to ad-hoc signing (-)."
    echo "Ad-hoc signed builds can run locally but SMAppService daemon registration will not work."
    IDENTITY="-"
else
    echo "Signing with: $IDENTITY"
fi

echo "==> Building release binaries"
swift build -c release

BUILD_BIN_DIR="$(swift build -c release --show-bin-path)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/RAMWatcher.app"

rm -rf "$DIST_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Library/LaunchDaemons"

echo "==> Assembling RAMWatcher.app"
cp "$BUILD_BIN_DIR/RAMWatcherApp" "$APP_DIR/Contents/MacOS/RAMWatcherApp"
cp "$BUILD_BIN_DIR/RAMWatcherDaemon" "$APP_DIR/Contents/MacOS/RAMWatcherDaemon"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/com.himanshu.ramwatcher.daemon.plist" "$APP_DIR/Contents/Library/LaunchDaemons/com.himanshu.ramwatcher.daemon.plist"

# Sign inside-out: the embedded daemon binary first (so launchd can
# validate ITS signature independently when SMAppService launches it),
# then seal the outer bundle, which hashes the now-final, already-signed
# daemon binary as a sealed resource.
echo "==> Signing embedded daemon"
codesign --options runtime --sign "$IDENTITY" --force "$APP_DIR/Contents/MacOS/RAMWatcherDaemon"

echo "==> Signing app bundle"
codesign --options runtime --sign "$IDENTITY" --force "$APP_DIR"

echo "==> Verifying signature"
codesign --verify --deep --strict "$APP_DIR"

echo ""
echo "Done. Built: $APP_DIR"
echo ""
echo "Next steps:"
echo "  cp -R \"$APP_DIR\" /Applications/RAMWatcher.app"
echo "  open /Applications/RAMWatcher.app"
echo ""
echo "On first launch the app registers its background daemon automatically."
echo "macOS will ask for a one-time approval in System Settings > General >"
echo "Login Items & Extensions > Allow in the Background."
