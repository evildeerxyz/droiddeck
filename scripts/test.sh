#!/bin/zsh
# DroidDeck tests.
#   scripts/test.sh               unit tests (no emulator needed, ~1 s)
#   scripts/test.sh integration   also boots real emulators (~2 min, needs the Android SDK and an arm64/x86_64 image)
#   scripts/test.sh intel         unit tests built for x86_64, run under Rosetta
set -euo pipefail
cd "${0:A:h}/../Packages/DroidDeckKit"
case "${1:-unit}" in
  unit) swift test ;;
  integration) DROIDDECK_INTEGRATION=1 swift test ;;
  intel) xcodebuild test -scheme DroidDeckKit -destination 'platform=macOS,arch=x86_64' -derivedDataPath ../../build/x86-tests | grep -E "TEST (SUCCEEDED|FAILED)|error:" ;;
  *) echo "usage: scripts/test.sh [unit|integration|intel]"; exit 2 ;;
esac
