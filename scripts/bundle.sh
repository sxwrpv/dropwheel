#!/bin/zsh
# Builds Dropwheel and assembles build/Dropwheel.app.
#
# Signing: set DROPWHEEL_SIGN_IDENTITY to a code-signing identity in your
# keychain to keep macOS privacy permissions across rebuilds. Without it the
# app is ad-hoc signed, and macOS treats every rebuild as a new app.
#
# Architectures: DROPWHEEL_ARCHS="arm64 x86_64" builds a universal app for
# Intel Macs too. The default is Apple silicon only.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG="${1:-release}"
APP="build/Dropwheel.app"
ARCHS=(${=DROPWHEEL_ARCHS:-arm64})

BINARIES=()
for arch in $ARCHS; do
  swift build -c "$CONFIG" --arch "$arch"
  BINARIES+=("$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)/Dropwheel")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if (( ${#BINARIES} == 1 )); then
  cp "${BINARIES[1]}" "$APP/Contents/MacOS/Dropwheel"
else
  lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Dropwheel"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${DROPWHEEL_SIGN_IDENTITY:--}"
codesign --force --options runtime --entitlements Resources/Dropwheel.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP (signed with: $IDENTITY)"
