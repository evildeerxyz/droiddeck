# Capabilities

Status key:

- ✅ **Verified:** exercised against real emulators on Apple Silicon (integration test or measured probe).
- ☑️ **Implemented:** implemented and unit-tested; not exercised end-to-end.
- ❌ **Not supported.**

The app disables unavailable actions and shows the runtime's reason in a tooltip (`CapabilityReport`).

## Android Emulator devices

| Capability | Status | Notes |
|---|---|---|
| SDK, emulator, adb, cmdline-tools, Java and acceleration detection | ✅ | Warns about conflicting adb versions |
| Official device profiles | ✅ | 90 profiles from Android Studio + cmdline-tools sdklib, newest Pixels first |
| Installed image scan + repository catalog | ✅ | Filesystem is authoritative; catalog via `sdkmanager --list` |
| Image download with license consent | ☑️ | Prompt format verified; downloads verified with already-accepted licenses |
| Create (avdmanager + config.ini) | ✅ | RAM, CPU, `/data` size verified inside the guest |
| Batch create | ☑️ | Sequential creation of N identical devices |
| Edit hardware (stopped device) | ☑️ | |
| Start / boot detection / graceful stop / force stop | ✅ | Including launch-failure diagnosis |
| Multi-instance with conflict-free ports | ✅ | Two devices booted concurrently |
| Duplicate (configuration only or with data) | ✅ | Data copy keeps app data; cold-boots once |
| Delete | ✅ | |
| Pause / Resume | ✅ | VM state verified over gRPC |
| Display inside DroidDeck | ✅ | gRPC frames, host GPU (`-qt-hide-window`) |
| Official skin frame (portrait + rotated) | ✅ | Geometry unit-tested; composited render checked |
| Touch, multi-touch, scroll, all four rotations | ✅ | Landing position measured with "show touches" |
| Keyboard text and special keys | ☑️ | W3C keys per proto; Home key verified |
| Hardware buttons (Back/Home/Overview/Power/Volume) | ✅ | Via adb keyevent |
| Rotation | ✅ | Console `rotate` |
| Screenshots | ✅ | |
| Clipboard (Mac → device) | ✅ | gRPC set/get |
| Emulator window mode, headless mode | ✅ | |
| APK install + failure diagnosis | ✅ | Real install, update and uninstall; invalid-APK diagnosis |
| XAPK | ☑️ | Extracted and installed with install-multiple |
| `.apks` (bundletool) | ❌ | Rejected with guidance |
| App launch / stop / clear data | ☑️ | |
| File browser, push/pull/delete | ✅ | |
| Shared folder → Gallery/Files | ✅ (push + MediaStore) / ☑️ (watcher engine) | |
| Logcat streaming + export | ☑️ | |
| GPS | ✅ | gRPC and console |
| Battery | ☑️ | `getBattery` verified |
| Light / proximity / temperature | ☑️ | RPC accepted; in-app effect not measured |
| Network speed / latency shaping | ✅ | Console |
| Snapshots save / list / delete | ✅ | Restore (`load`) ☑️ |
| Network & VPN diagnostics | ☑️ | Device commands verified individually |
| Google Play sign-in diagnostics | ☑️ | Commands verified on a device; Play detection fixed for the LicenseChecker stub |
| Streamline (disable preinstalled apps, animations off) | ✅ | |
| Keyboard-to-touch mapping (taps, WASD joystick) | ☑️ | |
| Automation workflows with approval | ☑️ | Approval logic unit-tested |
| Diagnostics export (redacted) | ☑️ | |
| RAM-format and skin repair for existing AVDs | ✅ / ☑️ | RAM behavior measured |

Since the 2026-10-29 redesign the app keeps a minimal interface, so several engine features above have no screen any more: the file browser, logcat, location and sensors, network shaping and VPN diagnostics, snapshots, Google sign-in diagnostics, Streamline, key mapping, automation workflows, groups, notes, shared folders and physical phones. They remain in DroidDeckKit with their tests. The previous interface is archived in `~/Developer/DroidDeck-backups/ui-before-redesign-2026-10-29.tar.gz`.

## Physical phones and unmanaged emulators (adb only)

Supported: apps, files, logcat, screenshots, hardware buttons, shared-folder copies, workflows.

Not supported: lifecycle, display inside DroidDeck, snapshots, simulation, and anything else that needs the emulator runtime. Each is shown as unavailable with a reason.

## Not supported

- Per-device VPN isolation as a guarantee. DroidDeck reports measured VPN state, DNS and public IPs at test time and nothing more.
- Disguising emulators as physical phones or altering device identifiers, and any feature aimed at avoiding a service's account limits or bans.
- Bundling Google apps. Google Play comes only from Google's Play system images.
- Wear OS, TV, Automotive and XR images are creatable but not exercised.
- Intel Macs are compiled and unit-tested under Rosetta, not run on Intel hardware.
- App self-updates are not configured. SDK components update in Settings › Android Versions.
