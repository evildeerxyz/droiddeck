#!/bin/zsh
# Reproducible build of DroidDeck.
#   scripts/build.sh                 Release, universal (Apple Silicon + Intel)
#   scripts/build.sh --install       ...and install to ~/Applications
#   scripts/build.sh --arch arm64    single-architecture build (faster)
set -euo pipefail
cd "${0:A:h}/.."
ARCHS="arm64 x86_64"
INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --arch) ARCHS="$2"; shift ;;
    *) echo "Unknown option $1"; exit 2 ;;
  esac
  shift
done
command -v xcodegen >/dev/null || { echo "XcodeGen is required: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
# Spotlight skips folders named *.noindex (it ignores .metadata_never_index on current macOS), so the
# build copy never shows up as a second DroidDeck in Spotlight or Launchpad.
mkdir -p build
xcodebuild -project DroidDeck.xcodeproj -scheme DroidDeck -configuration Release \
  -derivedDataPath build/DerivedData.noindex ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO build | grep -E "error:|warning:|BUILD" || true
APP=build/DerivedData.noindex/Build/Products/Release/DroidDeck.app
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/DroidDeck"))"
# Do not leave the build copy registered as a second DroidDeck in Launch Services.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
if [[ $INSTALL == 1 ]]; then
  if pgrep -qf "Applications/DroidDeck.app/Contents/MacOS/DroidDeck"; then
    echo "Quit DroidDeck before installing (running devices keep running)."; exit 1
  fi
  mkdir -p ~/Applications
  rm -rf ~/Applications/DroidDeck.app
  ditto "$APP" ~/Applications/DroidDeck.app
  echo "Installed ~/Applications/DroidDeck.app"
fi
