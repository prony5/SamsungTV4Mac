#!/bin/bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode),
# swift-testing lives outside the default search paths, so point the build at it.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
if [[ "$DEV" == *CommandLineTools* ]]; then
    F="$DEV/Library/Developer/Frameworks"
    L="$DEV/Library/Developer/usr/lib"
    exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" \
        -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
