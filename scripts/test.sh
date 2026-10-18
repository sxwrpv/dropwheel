#!/bin/zsh
# Runs the unit tests. With only the Command Line Tools installed (no Xcode),
# swift-testing lives outside the default search paths, and its Foundation
# overlay ships without module files, so cross-import overlays are disabled.
set -euo pipefail
cd "${0:A:h}/.."

FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ -d "$FRAMEWORKS/Testing.framework" ]] && ! xcode-select -p | grep -q Xcode.app; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    "$@"
fi
exec swift test "$@"
