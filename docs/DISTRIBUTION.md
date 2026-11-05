# Signing and notarization

DroidDeck is not sandboxed. It runs SDK tools, reads `~/.android` and the SDK, and connects to emulators on localhost. It is built with the **hardened runtime** and needs no special entitlements: child processes such as the emulator are Google-signed binaries started with `Process`.

## Local builds

`scripts/build.sh` signs ad-hoc (`CODE_SIGN_IDENTITY = "-"`). That is enough to run on the Mac that built it.

## Distribution outside the App Store

Requirements:

1. A **Developer ID Application** certificate. This Mac currently has only "Apple Development" and "Apple Distribution" identities; Apple Distribution is for the App Store and cannot be used for Developer ID notarization.
2. notarytool credentials:
   ```sh
   xcrun notarytool store-credentials droiddeck --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
   ```
3. Then:
   ```sh
   scripts/notarize.sh "Developer ID Application: <Name> (<TEAMID>)" droiddeck
   ```
   This builds a universal Release, signs with `--options runtime --timestamp`, submits with `notarytool --wait`, staples, verifies with `spctl`, and writes `build/DroidDeck-notarized.zip`.

## Mac App Store

Not targeted. The App Store requires the App Sandbox, which cannot launch SDK binaries from the user's SDK folder.
