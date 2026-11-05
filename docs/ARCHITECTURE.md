# Architecture

DroidDeck is an Xcode app target (`App/`, SwiftUI) on top of a Swift package (`Packages/DroidDeckKit`). Every layer below the UI is a separate Swift module, so access control enforces the boundaries. SwiftUI views never start processes or speak adb; they call application services.

```
App (SwiftUI)                         views, windows, the live display NSView, AppModel
  └─ DDServices                       application services (observable state for the UI)
       ├─ DDRuntime                   RuntimeAdapter protocol + AndroidEmulatorAdapter
       │    ├─ DDAndroidSDK           SDK discovery, images, profiles, AVD files, skins
       │    ├─ DDADB                  adb client, logcat, APK diagnostics
       │    └─ DDEmulatorGRPC         HTTP/2 + HPACK + gRPC + protobuf (no dependencies)
       ├─ DDPersistence               JSON documents, metadata, preferences, history
       └─ DDPlatform                  processes, host metrics, logging + redaction, files, ports
            └─ DDCore                 domain model, validation, capabilities (pure, no I/O)
```

`DroidDeckKit` is an umbrella module that re-exports all layers to the app.

## Module responsibilities

| Module | Contents |
|---|---|
| **DDCore** | `DeviceConfiguration`, `DeviceProfile`, `SystemImage`, `AndroidPlatform` (parses every SDK platform form), `ConfigurationValidator` with `RuntimeLimits` and `HostResources`, `RuntimeCapability`/`CapabilityReport`, `DeviceLifecycleState`, `DroidDeckError` (message, recovery, redacted detail). |
| **DDPlatform** | `ProcessRunner` (timeouts, cancellation, line and byte streaming, survives daemons that inherit pipes), `LaunchedProcess`, `HostEnvironment` (real architecture under Rosetta), `HostMemorySnapshot`, `ProcessMetricsSampler` (footprint and CPU via `proc_pid_rusage`), `AppLog` + `Redactor`, `INIFile` (order- and comment-preserving), `SafeFileOperations` (containment checks before deleting), `PortAllocator`. |
| **DDPersistence** | `AppPaths`, `DeviceMetadata` (group, notes, display mode, frame, shared folder, key bindings), `AppPreferences`, `JSONDocumentStore` (atomic writes, keeps corrupt files aside), `OperationHistoryStore`. |
| **DDAndroidSDK** | `SDKLocator`/`SDKInstallation`, `SystemImageCatalog` (filesystem is the source of truth for installed images), `SDKManagerClient` (interactive license prompts), `DeviceProfileCatalog` (sdklib device XML from Android Studio and cmdline-tools), `AVDRepository` (read/apply config, safe cloning, RAM-format and skin repair), `AVDManagerClient`, `SkinLayout`. |
| **DDADB** | `ADBClient` (track-devices, shell with quoting, install, files, media scan, logcat, screenshots, console), `InstallFailure`, `APKInfo`. |
| **DDEmulatorGRPC** | `HTTP2Connection` (flow control both ways, SETTINGS/PING/GOAWAY, CONTINUATION), `HPACKEncoder`/`HPACKDecoder` + Huffman (tables generated from RFC 7541 by `scripts/codegen`), `GRPCChannel`, `ProtoWriter`/`ProtoReader`, `EmulatorControllerClient`. |
| **DDRuntime** | `RuntimeAdapter`, `AndroidEmulatorAdapter` (detection, capabilities, create/update/clone/delete, start with atomic port reservation, staged boot, graceful→forced stop, snapshots, controller), `EmulatorDiscovery`, `EmulatorLaunchDiagnosis`, `ADBDeviceCapabilities`. |
| **DDServices** | `DeviceManager` (registry plus lifecycle, event-driven refresh), `TaskCenter`, `ResourceMonitor`, `ImageLibrary`, `ProfileLibrary`, `DisplaySession`/`InputPipeline`/`DisplayGeometry`/`DeviceFrameGeometry`, `SharedFolderService`, `NetworkDiagnostics`/`VPNMonitor`, `GooglePlayDiagnostics`, `DeviceStreamlining`, `Workflow`/`WorkflowRunner`, `DiagnosticsExporter`, `RefreshPolicy`/`PowerConditions`. |

## Key flows

**Start a device.** `DeviceManager.start` → `TaskCenter` task → `AndroidEmulatorAdapter.start`:
1. Validate the image, its files, the ABI and the RAM ceiling.
2. Reserve ports and launch the emulator with its log in `~/Library/Logs/DroidDeck/Emulators/<avd>/`.
3. Wait for the discovery file (with the gRPC port and token), then `sys.boot_completed`, then shared storage.

Phases stream to the UI, and failures are explained from the emulator log.

**Live display.** `EmulatorScreen` (NSViewRepresentable) owns a `DisplaySession` that streams RGBA frames scaled to the view's pixel size into a `CALayer`. The stream stops while the window is occluded or minimized. Mouse, trackpad and keyboard events become `EmulatorInputEvent`s through an `InputPipeline`, which is serialized and coalesces pointer moves. `DisplayGeometry` maps them to panel coordinates for the current rotation. `SkinnedFrame` composites the SDK skin.

**Refresh.** Updates are driven by events: `adb track-devices`, plus kqueue monitors on the emulator discovery folder and the AVD home (top level only, so busy disk images don't trigger anything). A fallback poll runs every 15–120 s depending on app activity and power source, and every 2 s during start/stop transitions.

**Shared folder.** An FSEvents watcher on the Mac folder feeds `SharedFolderSyncEngine` (an actor). It pushes files whose size is stable, sends a media-scan broadcast, and keeps a per-device index that is reconciled after a wipe. Deletions propagate only if you enable that.

## Persistence

| Data | Location |
|---|---|
| AVDs (runtime files, user data) | AVD home (`~/.android/avd` by default) |
| Device metadata, preferences | `~/Library/Application Support/DroidDeck/{devices,preferences}.json` |
| Operation history | `…/history.jsonl` (trimmed) |
| Workflows | `…/Automations/*.json` |
| Shared-folder sync indexes | `…/SyncIndexes/<avd>.json` |
| Logs | `~/Library/Logs/DroidDeck/` (app log, one file per emulator session) |

`DROIDDECK_SUPPORT_DIR` relocates DroidDeck's own data. UI tests use it to stay isolated from your real data.

## Safety

- Mutating an AVD (edit, clone, delete, wipe, repair) requires the device to be stopped. The adapter checks this, not only the UI.
- Deletion uses `avdmanager`, or contained removal inside the AVD home only. The UI always confirms, naming what will be lost.
- Licenses are surfaced to you and never auto-accepted. Imported workflows never run until approved, and any edit revokes approval.
- Secrets (the gRPC bearer token, which the emulator also echoes in errors; console tokens; JWTs) are redacted from logs, errors and exports.
