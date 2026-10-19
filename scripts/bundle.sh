#!/bin/zsh
# Builds Dropwheel and assembles build/Dropwheel.app.
#
# Signing: set DROPWHEEL_SIGN_IDENTITY to a code-signing identity in your
# keychain to keep macOS privacy permissions across rebuilds. Without it the
# app is ad-hoc signed, and macOS treats every rebuild as a new app.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG="${1:-release}"
APP="build/Dropwheel.app"

swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Dropwheel" "$APP/Contents/MacOS/Dropwheel"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${DROPWHEEL_SIGN_IDENTITY:--}"
codesign --force --options runtime --entitlements Resources/Dropwheel.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP (signed with: $IDENTITY)"
