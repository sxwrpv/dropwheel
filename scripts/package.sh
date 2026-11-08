#!/bin/zsh
# Builds a universal release of Dropwheel and packs what the installer
# downloads into dist/: Dropwheel.zip, its SHA-256 and install.sh. Attach all
# three to a GitHub release; scripts/install.sh says how they are used.
set -euo pipefail
cd "${0:A:h}/.."

DROPWHEEL_ARCHS="arm64 x86_64" scripts/bundle.sh release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Dropwheel.app/Contents/Info.plist)"

rm -rf dist
mkdir -p dist
ditto -c -k --keepParent build/Dropwheel.app dist/Dropwheel.zip
(cd dist && shasum -a 256 Dropwheel.zip > Dropwheel.zip.sha256)
cp scripts/install.sh dist/install.sh

echo "Packed Dropwheel $VERSION ($(lipo -archs build/Dropwheel.app/Contents/MacOS/Dropwheel)) in dist/"
