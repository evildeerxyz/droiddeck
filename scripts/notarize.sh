#!/bin/zsh
# Signs, notarizes and staples a distributable DroidDeck build.
# Requirements (not present on this Mac at the time of writing):
#   - a "Developer ID Application" certificate in the login keychain
#   - notarytool credentials: xcrun notarytool store-credentials droiddeck --apple-id … --team-id … --password <app-specific>
# Usage: scripts/notarize.sh "Developer ID Application: Name (TEAMID)" [keychain-profile]
set -euo pipefail
cd "${0:A:h}/.."
IDENTITY="${1:?Developer ID Application identity required}"
PROFILE="${2:-droiddeck}"
scripts/build.sh
APP=build/DerivedData.noindex/Build/Products/Release/DroidDeck.app
codesign --force --deep --options runtime --timestamp --entitlements App/DroidDeck.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
ZIP=build/DroidDeck.zip
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
ditto -c -k --keepParent "$APP" build/DroidDeck-notarized.zip
echo "Notarized: build/DroidDeck-notarized.zip"
