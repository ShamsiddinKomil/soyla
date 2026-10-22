#!/usr/bin/env bash
# Run `swift test` on a Mac with either full Xcode or only the Command Line Tools.
# Under CLT, swift-testing ships with the tools but SwiftPM doesn't add its framework/rpath paths, so we do.
# Under full Xcode, plain `swift test` just works.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p 2>/dev/null || true)"
# Throwaway test suites leave empty plists: cfprefsd can rewrite one after the test's own cleanup deleted it.
sweep() {
  sleep 1
  find "$HOME/Library/Preferences" -maxdepth 1 -type f -size -100c \( -name 'ai.soyla.test.*.plist' -o -name 'ai.soyla.tests.*.plist' \
    -o -name 'test.ondevice.*.plist' -o -name 'soyla.test.*.plist' \) -delete 2>/dev/null || true
}
trap sweep EXIT
case "$DEV" in
  *Xcode*.app/Contents/Developer) swift test "$@"; exit ;;
esac
F="$DEV/Library/Developer/Frameworks"
L="$DEV/Library/Developer/usr/lib"
[ -d "$F" ] || { F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib; }
swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
