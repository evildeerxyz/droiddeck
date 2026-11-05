# Runtime integration

DroidDeck uses Google's Android Emulator, the only runtime currently implemented, behind the `RuntimeAdapter` protocol (`Packages/DroidDeckKit/Sources/DDRuntime`). Every fact below was measured on this project's development Mac (Apple M4 Pro, macOS 27.0.1) and is covered by `RuntimeIntegrationTests` unless noted.

## Tools and versions

| Tool | Used for | Verified versions |
|---|---|---|
| `emulator` | launching devices | 36.6.11, 37.2.12 |
| `adb` (SDK platform-tools) | device list (`track-devices`), shell, install, files, logcat, screenshots, console (`adb emu`) | 37.0.0, 37.0.1 |
| `avdmanager` | create/delete/rename AVDs | cmdline-tools 20.0, 23.0 |
| `sdkmanager` | image catalog, downloads, SDK updates | cmdline-tools 20.0, 23.0 |
| `aapt2` (build-tools) | APK inspection before install | 37.0.0 |
| Emulator gRPC (`emulator_controller.proto`) | display stream, touch/keys, GPS, battery, sensors, clipboard, VM state | 36.6.11, 37.2.12 |

DroidDeck always uses the SDK's own `adb`. A different adb version on `PATH` (for example Homebrew's) restarts the adb server and disconnects devices; onboarding warns about it.

## Launch

```
emulator -avd <name> -ports <console>,<adb> -grpc <port> -grpc-use-token -no-metrics -crash-report-mode never
         [-qt-hide-window | -no-window] [-no-snapshot-load] [-wipe-data] [-no-snapshot-save]
         [-netspeed …] [-netdelay …] [-dns-server …]
```

- **Display modes.** In DroidDeck uses `-qt-hide-window`, which keeps host-GPU rendering (`gles_mode_selected:host`). `-no-window` falls back to software rendering (`swangle`) and is used only for headless devices. The emulator window mode passes neither flag.
- **GPU.** `hw.gpu.mode` decides; DroidDeck passes no `-gpu` override. With Automatic the emulator (37.2.12) uses the Mac GPU for Android 14 and older and software rendering (`swangle`, SwiftShader) for Android 15+: "API level 35 requires GLES 3.1, forcing software rendering for GLES" (same message with 36 and 37). Tested per level on 2026-10-28: 34 → host; 35, 36, 37 → swangle. The Mac GPU path (gfxstream translator on Apple OpenGL 4.1) offers OpenGL ES 3.0 only. Forcing it on Android 15+ (tried on Android 17, 2026-10-28) cut CPU about 10× (idle 281%→23%, scrolling 365%→42%) but broke Chrome/WebView ("GFXSTREAM: EGL_BAD_CONFIG: no ES 3.1 support", so the Google sign-in screen closed itself) and TikTok video (static). Software rendering on Android 15+ is correct but costs several cores while the screen is on (Android 15 measured 183% idle and 402% scrolling, Android 16 301%/623%). Android 14 on the Mac GPU measured 62% idle, 97% scrolling, with Google sign-in and H.264/H.265 playback working; for the lowest battery use create devices with Android 14 or older. Device Studio badges images "Mac GPU" or "CPU rendering" (`SystemImage.rendersOnMacGPU`). Not viable on this Mac: ANGLE on MoltenVK/KosmicKrisp (`-gpu swangle` pins SwiftShader) and `-feature GuestAngle` (SurfaceFlinger aborts: "Could not initialize Vulkan RenderEngine!"). Hardware video decoding (`c2.goldfish.*`) is on in all modes.
- **Screen streaming.** DroidDeck requests RGBA frames at the window's pixel size with the MMAP image transport (`ImageFormat.transport = {MMAP, "file:///…"}`): the emulator writes each frame into a private file mapped by DroidDeck and the gRPC stream carries only metadata. Benchmark (`DROIDDECK_STREAM_BENCH`, 860×1920, continuous scrolling, ~60 fps): DroidDeck 10–13% → 6% CPU, emulator 80–94% → 77–82%. Reads check the file size first (reading past the end of a mapping is SIGBUS); if the emulator never fills the buffer DroidDeck falls back to in-band frames.
- **Video on the Mac GPU (Android 15+ forced to `host`).** Most video plays, but TikTok HEVC videos showed magenta/green static (the macOS OpenGL driver logged "texture unloadable … using zero texture"). Not the hardware decoder (same with `-feature -HardwareDecoder`) or DroidDeck's transport; `-feature -YUVCache` is not an option (the Android 17 gralloc mapper asserts `!rcEnc->hasYUVCache()` and the codec service crashes). Resolved by not forcing the Mac GPU on Android 15+.
- **Audio.** CoreAudio output buffers `QEMU_COREAUDIO_BUFFER_SIZE` × `QEMU_COREAUDIO_BUFFER_COUNT` frames. The default 512 × 4 (~45 ms) underruns (crackles) when the emulator is busy. DroidDeck sets 1024 × 4 unless the user's environment sets them. Audio reached the Mac on cold boot, snapshot restore and with two devices playing at once.
- **Ports.** DroidDeck allocates an even console port in 5554–5682 (adb = console + 1) and a gRPC port in 8554–8999. It checks that the ports are bindable, that they aren't used by running emulators, and that they aren't held by adb serials of other emulators (third-party players such as MuMu register `emulator-5554`). Concurrent starts reserve ports atomically. Two devices starting at once used to receive the same ports, which the integration test caught.
- **Discovery.** Each emulator writes `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini` with `avd.name`, `avd.dir`, `port.serial`, `port.adb`, `grpc.port` and `grpc.token`. Values may contain `=` (base64 tokens), so only the first `=` splits a line. This file binds a process to its gRPC endpoint and lets DroidDeck reattach to devices after a relaunch.
- **Crash dialog.** Without `-crash-report-mode never`, an earlier crash makes the emulator show a consent dialog, which crashes (SIGSEGV) when the window is hidden.
- **Boot.** Boot is complete when `sys.boot_completed` is 1 and `/sdcard/Download` exists. Shared storage mounts slightly after boot completes; pushes made before that failed.
- **Unusable Quick Boot snapshot.** Observed on real devices: "Missing section footer for 0000:00:0b.0/goldfish_address_space", "Error -22 while loading VM state", "Failed to load snapshot". The emulator then runs a half-restored machine that either segfaults (`pipe_dev_write_v2`, exit status 11) or hangs with adb offline, and a normal stop saves that broken state as the new snapshot. A snapshot saved in software mode is also not restorable on the GPU. DroidDeck watches the log during a Quick Boot start; on failure it SIGKILLs the process (so nothing is saved), deletes `snapshots/default_boot` and relaunches with `-no-snapshot-load`. Apps and accounts live on the data disk and are kept. A new device logs "Failed to load snapshot" after "does not have the requested snapshot"; that is a normal first boot and is ignored.
- **Failures.** Launch failures are explained from the emulator log: RAM above the limit, unknown AVD, AVD already running, Hypervisor.framework errors, disk space, missing image, unknown skin, and port conflicts.

## Hardware configuration (config.ini)

Keys are checked against `emulator/lib/hardware-properties.ini`. Measured behavior:

| Setting | Finding |
|---|---|
| `hw.ramSize` | Must be **plain megabytes**. `3072` gives 3 GB to the guest; `3072M`, `4G` and `2G` are **ignored**, and the emulator falls back to its minimum (about 2.5 GB for 1080×2400, 4 GB for 1280×2856). `avdmanager` writes `2G`, so DroidDeck flags such AVDs and offers a one-click fix. |
| RAM ceiling (arm64) | QEMU `mach-virt` accepts at most 31 GB: 31744 MB boots, 32768 MB fails with "cannot model more than 31GB RAM" and the process hangs. DroidDeck rejects larger values. |
| RAM vs host use | A guest configured for 16 GB used about 3.4 GB of host memory after boot. DroidDeck shows both. |
| `disk.dataPartition.size` | `8G` gives an 8 GB `/data`. Requests below 6 GB become 6 GB (Android 14 image). |
| CPU | `hw.cpu.ncore` is honored (`nproc` matches). |
| `skin.name` | Needs a valid `skin.path`, or the emulator exits with "unknown skin name". DroidDeck writes both and can repair AVDs that lack the path. |

## Display and input

- **Frames.** Frames come from `streamScreenshot` (RGBA8888, scaled by the emulator to the view's pixel size). A hand-written HTTP/2 + HPACK + gRPC client (`DDEmulatorGRPC`) delivered about 58 fps at 540×1200. HPACK is tested against the RFC 7541 Appendix C vectors.
- **Rotation.** `Image.format.rotation` reports the physical rotation. One console `rotate` gives `reverseLandscape`, while Android may stay at `ROTATION_0` if the app doesn't rotate. Touch coordinates are panel coordinates; `DisplayGeometry` maps them for all four rotations, verified by measuring Android's "show touches" dot in streamed frames.
- **Input.** `sendTouch` and `sendKey` (unary) are applied. **`streamInputEvent` accepts events but does not apply them** in 36.6.11, so DroidDeck serializes unary calls per device, coalescing pointer moves.
- **Hardware buttons.** gRPC `GoHome` and evdev 580 (Overview) work. Power and Volume sent through gRPC had no effect, while `adb shell input keyevent` worked, so all hardware buttons use adb keyevents. This also works for physical phones.
- **Scrolling.** Scroll is converted into a drag that starts at least 12% inside the screen edges, because Android treats edge drags as the Back gesture.
- **Device frame.** The frame is composited like the emulator: display first, hidden where `mask.webp` is opaque (rounded corners, camera cut-out), then `back.webp` on top. Landscape rotates the artwork and the display opening (`DeviceFrameGeometry`, unit-tested).

## State and data

- **Snapshots.** `adb emu avd snapshot save|load|delete`. A saved snapshot of an Android 14 device took about 2.6 GB (`ram.bin`).
- **Pause/Resume.** `adb emu avd pause|resume` (gRPC `getVmState` reports `PAUSED`).
- **Screen off when not on screen.** A device with no visible DroidDeck window has its display turned off (`KEYCODE_SLEEP`) after 30 s; video apps stop rendering and the emulator drops to a few percent CPU (measured 2–3%). Showing the window wakes it (`KEYCODE_WAKEUP`, `wm dismiss-keyguard`); a window's first appearance checks `mWakefulness` so devices slept in an earlier session wake too. Opt out per device or in Settings.
- **Background priority.** When DroidDeck turns a device's screen off it also sets the emulator process to Darwin background priority (`setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`, shown as `pri 4` by `ps`): lowest CPU priority, throttled I/O, efficiency cores. Android runs maintenance (dexopt, updates) when idle, screen off and "charging", which an emulator always is; this keeps that off the performance cores. Normal priority is restored before the wake key is sent.
- **Cloning.** A clone is a directory copy (APFS clone) of a stopped AVD; qcow2 overlays reference backing files by relative path. Lock and transient files are removed. `qemu-version.txt` and `version_num.cache` must be **kept**: removing them made the emulator re-initialize userdata and lose the copied data. Snapshots are dropped, because the emulator refuses to load a snapshot copied to another AVD ("The emulator hardware cannot load snapshot"). Copies cold-boot once and keep their data.
- **Graceful stop.** `adb shell sync`, then `adb emu kill` (Quick Boot saves state), escalating to SIGTERM and then SIGKILL.

## Files and media

`adb push` into `/sdcard/Pictures|Movies|Music|Download/DroidDeck/…` is indexed by MediaStore. A `MEDIA_SCANNER_SCAN_FILE` broadcast fills in size and dimensions immediately (verified with `content query`). The shared-folder sync uses this: a recursive FSEvents watcher on the Mac folder, stability checks for files still being copied, and a per-device index that is reconciled with the device after a data wipe.

## Google Play

- Play Store availability depends only on the image (`google_apis_playstore*`). It cannot be added to an existing Google APIs device.
- On Google APIs images, `pm path com.android.vending` returns `LicenseChecker.apk`, a licensing stub that is **not** the Play Store. Detection looks for the real package.
- `/proc/uptime` survives Quick Boot (it read 35 hours on a freshly started device), so the "recently booted" check uses the host-side start time.

## Network diagnostics

Inside Android DroidDeck reads `dumpsys connectivity` (VPN transport, owner UID, DNS), `ip -o link` (tun/wg interfaces), the private DNS setting, and ping and `nc` reachability. On the Mac it reads `route -n get default`, `scutil --nc list` and `scutil --dns`. Public IPs come from toybox `nc` on the device and URLSession on the Mac, only with consent. Distinct public IPs are reported as a point-in-time observation, never as proof of isolation.

## Not verified

- Intel hardware. The x86_64 build passes unit tests under Rosetta; launching emulators on an Intel Mac hasn't been tested. Intel RAM limits fall back to a host-memory policy and are labeled unverified.
- Wear OS, TV, Automotive and XR images: listed and creatable, but not exercised by the integration test.
- Light, proximity and temperature changes via `setPhysicalModel`: the RPC succeeds, but the effect inside apps was not measured.
