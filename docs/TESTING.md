# Testing

## Unit tests (no emulator)

```sh
scripts/test.sh            # or: cd Packages/DroidDeckKit && swift test
```

About 90 tests across 7 suites, covering:

- **HPACK:** RFC 7541 Appendix C vectors.
- **Protobuf and gRPC framing.**
- **Configuration validation:** presets, the 31 GB ceiling, host headroom, ABI mismatch, emulator version, CPU, disk, multi-device memory.
- **Platform parsing:** every SDK platform-string form.
- **Redaction:** including the bearer token the emulator echoes in errors.
- **INI editing.**
- **Process runner:** timeouts, cancellation, streaming.
- **Ports, safe deletion, sdkmanager listing, license prompts.**
- **Device profiles, skins, AVD apply/clone safety.**
- **adb parsing:** devices, track-devices, ls, logcat, install codes, aapt2 badging.
- **Display geometry:** all rotations.
- **Refresh policy, shared-folder routing, workflow approval, network interpretation, persistence, Play Store detection.**

## Integration tests (real emulators)

```sh
scripts/test.sh integration     # DROIDDECK_INTEGRATION=1 swift test
```

Requirements: an Android SDK with the emulator and platform-tools, Command-line Tools, and at least one installed phone image for this Mac's ABI. The test creates AVDs in `/tmp/droiddeck-it-<pid>/avd` and never touches `~/.android/avd`. It stops anything it started, even when it fails.

It runs the full lifecycle in about 2 minutes:

1. Detection.
2. Profile + image selection and validation.
3. Creation, with config.ini checked against the guest's MemTotal, `nproc` and `/data` size.
4. Boot with phases.
5. Capabilities.
6. adb screenshot; gRPC status, frames, touch, multi-touch, GPS and clipboard.
7. Hardware key.
8. Push, MediaStore indexing and pull.
9. A real APK update install and uninstall; invalid-APK diagnosis.
10. Streamline apply and restore.
11. Console rotate, network and geo.
12. Pause/Resume.
13. Landscape touch landing (via Android's show-touches dot).
14. Snapshot save and delete.
15. Refusal to delete or clone while running.
16. Graceful stop.
17. Duplicate with data; two devices booted concurrently on distinct ports, with the data present in the copy.
18. Delete.

Last verified with emulator 37.2.12, platform-tools 37.0.1, cmdline-tools 23.0, and an Android 14 Google APIs arm64 image.

## Intel build under Rosetta

```sh
scripts/test.sh intel
```

Builds the test bundles for x86_64 and runs them under Rosetta (43 core/platform tests). This checks, among other things, that an Intel build on Apple Silicon still detects the real hardware.

## UI checks without taking over the screen

Both hooks are honored only when `DROIDDECK_SUPPORT_DIR` is set, so they cannot act on a normal install:

```sh
APP=build/DerivedData.noindex/Build/Products/Release/DroidDeck.app/Contents/MacOS/DroidDeck
# Render the official skin around a screenshot (rotation 0–3) to a PNG:
DROIDDECK_SUPPORT_DIR=/tmp/dd-ui $APP --render-frame-preview ~/Library/Android/sdk/skins/pixel_10_pro shot.png out.png 0
# Snapshot the device list, New Device, a device's Settings and a tag-filtered list into a folder, then quit:
DROIDDECK_SUPPORT_DIR=/tmp/dd-ui ANDROID_AVD_HOME=/tmp/dd-ui/avd $APP --ui-snapshot /tmp/dd-ui/snaps
# Start a device and open its live window:
DROIDDECK_SUPPORT_DIR=/tmp/dd-ui ANDROID_AVD_HOME=/tmp/dd-ui/avd $APP --ui-test-open <avd>
```

Run the binary directly rather than with `open`, so Launch Services does not register a second copy of DroidDeck.
