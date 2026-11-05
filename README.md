# DroidDeck

A native macOS app for creating, running and managing Android virtual devices. DroidDeck drives Google's official **Android Emulator** through the Android SDK: real devices, real Android, shown inside DroidDeck with an official device frame.

## Requirements

- macOS 15 or later. Apple Silicon is verified; Intel builds compile and pass unit tests under Rosetta but have not been run on Intel hardware.
- Android SDK with the Android Emulator and Platform-Tools. Installing Android Studio provides both, in `~/Library/Android/sdk`.
- Android SDK Command-line Tools and a Java 17+ runtime to create devices and download images. Android Studio's bundled runtime is detected automatically.
- To build: Xcode 26+ (verified with Xcode 27.1 / Swift 6.4) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Build and install

```sh
scripts/build.sh --install          # universal Release build → ~/Applications/DroidDeck.app
scripts/build.sh --arch arm64       # faster single-architecture build
```

The Xcode project is generated from `project.yml`. Builds are ad-hoc signed with the hardened runtime. For distribution, see [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

## Test

```sh
scripts/test.sh                     # unit tests
scripts/test.sh integration         # boots real emulators in a temporary AVD folder
scripts/test.sh intel               # unit tests as x86_64 under Rosetta
```

Details: [docs/TESTING.md](docs/TESTING.md).

## What it does

DroidDeck is deliberately small: one window with your devices, a phone window per device, and Settings.

| Area | Summary |
|---|---|
| Devices | One list: each device with its colored tags, Android version, status and CPU use, and Start / Open / Stop on the row. The ⋯ menu has Pause, Tags, Rename, Settings, Wipe Data and Delete. A toolbar menu shows only one tag's devices. |
| New Device | One page: name, phone, Android version (Android 14 recommended: it runs on the Mac's graphics chip), tag and how many. Memory, cores and storage are chosen for you; a missing Android version downloads from here. |
| Device settings | Name, tags, screen-off when hidden, phone frame, and the facts that matter for battery (graphics, memory and CPU, screen size, disk use with Free Up). |
| Phone window | The emulator screen streamed over gRPC inside the SDK's official skin, with touch, multi-touch (Option-drag), scrolling and keyboard input, and a rail with Back, Home, Recents, volume, power, rotate, screenshot, Add Files (APKs install; photos and videos go to the Gallery; other files to Downloads) and paste. Files can also be dragged onto the screen. |
| Settings | General (screen-off for hidden devices, quit behavior, screenshots folder), Android Versions (downloaded versions and SDK updates), Troubleshooting (setup checks, SDK location, redacted diagnostics export, logs). |
| Battery | Hidden devices turn their screens off and drop to background priority, display streams stop when windows are hidden, Pause freezes idle devices, refresh slows on battery or in Low Power Mode. |

The full verified/unsupported list is in [docs/CAPABILITIES.md](docs/CAPABILITIES.md). Verified runtime facts and the integration strategy are in [docs/RUNTIME.md](docs/RUNTIME.md); module structure is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Data and privacy

- Devices live in the standard AVD folder (`~/.android/avd`, or `ANDROID_AVD_HOME`), so Android Studio sees them too. DroidDeck's own metadata (groups, notes, preferences, history) is stored separately in `~/Library/Application Support/DroidDeck`.
- Logs are in `~/Library/Logs/DroidDeck`. Tokens, passwords and JWTs are removed before anything is logged; exported diagnostics also remove email addresses and your home path.
- DroidDeck sends no analytics. Emulators start with `-no-metrics -crash-report-mode never`. Public-IP checks contact a third-party echo service only when you enable them.
- DroidDeck never accepts SDK licenses for you and does not bundle Google components; Play images are downloaded from Google through `sdkmanager`.

## Responsible use

Emulated devices identify themselves as emulators, and DroidDeck does not disguise devices or alter their identifiers. Running many accounts or automated activity on third-party services (for example social networks) is governed by those services' terms. DroidDeck cannot prevent a service from limiting or banning accounts.

## License

[MIT](LICENSE)
