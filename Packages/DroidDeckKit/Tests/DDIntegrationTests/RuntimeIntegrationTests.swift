import Foundation
import Testing
import DDCore
import DDPlatform
import DDAndroidSDK
import DDADB
import DDRuntime
import DDEmulatorGRPC
import DDServices

/// End-to-end tests against the real Android SDK. They boot real emulators.
///
/// Opt in: `DROIDDECK_INTEGRATION=1 swift test --filter DDIntegrationTests`
/// AVDs are created in a temporary ANDROID_AVD_HOME and deleted afterwards;
/// the user's ~/.android/avd is never touched.
@Suite("Runtime integration", .enabled(if: ProcessInfo.processInfo.environment["DROIDDECK_INTEGRATION"] == "1"), .serialized)
struct RuntimeIntegrationTests {
    static let avdHome = URL(fileURLWithPath: "/tmp/droiddeck-it-\(ProcessInfo.processInfo.processIdentifier)/avd")

    func makeAdapter() async throws -> (AndroidEmulatorAdapter, SDKInstallation) {
        try FileManager.default.createDirectory(at: Self.avdHome, withIntermediateDirectories: true)
        let sdk = try #require(await SDKLocator.locate(avdHome: Self.avdHome), "No Android SDK found")
        return (try AndroidEmulatorAdapter(installation: sdk), sdk)
    }

    /// Picks an installed image the host can run, preferring a light Google APIs image.
    func pickImage(_ images: [SystemImage], host: HostEnvironment) throws -> SystemImage {
        let runnable = images.filter { $0.androidABI.map(host.architecture.acceleratedABIs.contains) ?? false && $0.formFactor == .phone }
        return try #require(runnable.first { !$0.hasGooglePlay } ?? runnable.first, "No runnable system image installed")
    }

    @Test("Full device lifecycle on the real emulator")
    func lifecycle() async throws {
        let (adapter, sdk) = try await makeAdapter()
        do {
            try await runLifecycle(adapter: adapter, sdk: sdk)
        } catch {
            if let error = error as? DroidDeckError {
                print("FAILURE: \(error.message)\nRECOVERY: \(error.recovery ?? "-")\nDETAIL: \(error.detail ?? "-")")
            }
            // Never leave emulators running after a failed test.
            for instance in await adapter.runningInstances() where instance.avdDirectory?.path.hasPrefix(Self.avdHome.path) == true {
                try? await adapter.stop(instance, force: true)
            }
            try? FileManager.default.removeItem(at: Self.avdHome.deletingLastPathComponent())
            throw error
        }
        try? FileManager.default.removeItem(at: Self.avdHome.deletingLastPathComponent())
    }

    func runLifecycle(adapter: AndroidEmulatorAdapter, sdk: SDKInstallation) async throws {
        let host = HostEnvironment.current()

        // Detection
        let detection = await adapter.detect()
        for check in detection.checks { print("check \(check.id): \(check.status) — \(check.detail)") }
        #expect(detection.canRunDevices)
        #expect(detection.checks.first { $0.id == "acceleration" }?.status == .ok)

        // Profiles: prefer one avdmanager does not know (exercises config.ini application).
        let profiles = await DeviceProfileCatalog.load(sdkRoot: sdk.root)
        print("profiles: \(profiles.count), first: \(profiles.prefix(5).map(\.id))")
        let profile = try #require(profiles.first { $0.id == "pixel_10" } ?? profiles.first { $0.id == "pixel_9_pro" })

        let image = try pickImage(await adapter.installedImages(), host: host)
        print("image: \(image.packagePath)")
        var config = DeviceConfiguration.from(profile: profile, image: image, displayName: "DD Integration A",
                                              avdName: "DD_IT_A", ram: Megabytes(3072), cpuCores: 2, dataPartition: Megabytes(8192))
        config.audioInput = false
        let validator = ConfigurationValidator(
            host: HostResources(architecture: host.architecture, physicalMemory: host.physicalMemory,
                                logicalCPUs: host.logicalCPUs, performanceCPUs: host.performanceCPUs,
                                availableDiskBytes: DiskSpace.forVolume(containing: Self.avdHome)?.available ?? 0),
            limits: .androidEmulator(host: host.architecture, hostPhysicalMemory: host.physicalMemory),
            existingAVDNames: [], image: image, emulatorVersion: sdk.emulator?.version)
        let validation = validator.validate(config)
        #expect(validation.isValid, "\(validation.errors)")

        // Create
        let device = try await adapter.create(config, profile: profile, image: image)
        #expect(device.avd.config["hw.ramSize"] == "3072")
        #expect(device.avd.config["hw.lcd.width"] == String(profile.screenWidth))
        #expect(device.avd.config["hw.device.name"] == profile.id)
        #expect(device.avd.directory.path.hasPrefix(Self.avdHome.path))
        #expect(await adapter.devices().map(\.name) == ["DD_IT_A"])

        // Start (embedded display mode)
        let phases = PhaseRecorder()
        let clock = ContinuousClock()
        let started = clock.now
        let instance = try await adapter.start(device, options: LaunchOptions()) { phases.record($0) }
        print("booted in \(clock.now - started); phases \(phases.all); console \(instance.consolePort) grpc \(instance.grpcPort ?? -1)")
        #expect(instance.launchedByDroidDeck)
        #expect(instance.hasControlChannel)
        #expect(instance.displayMode == .embedded)
        #expect(phases.all.contains(.launching) && phases.all.contains(.booting))
        let caps = await adapter.capabilities(for: device, instance: instance)
        #expect(caps.supports(.embeddedDisplay) && caps.supports(.stopDevice) && !caps.supports(.deleteDevice))

        let adb = adapter.adb
        let serial = instance.adbSerial
        let sdkLevel = try await adb.getprop(serial, "ro.build.version.sdk")
        #expect(Int(sdkLevel) == image.platform.apiLevel)
        // Configured hardware is actually applied inside the guest.
        let memTotalKB = Int(try await adb.shell(serial, "grep MemTotal /proc/meminfo").filter(\.isNumber)) ?? 0
        print("guest MemTotal \(memTotalKB) kB, cpus \(try await adb.shell(serial, "nproc").trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(memTotalKB > 2_900_000 && memTotalKB < 3_200_000)
        #expect(try await adb.shell(serial, "nproc").trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        let dataKB = try await adb.shell(serial, "df -k /data | tail -1").split(separator: " ", omittingEmptySubsequences: true).dropFirst().first.flatMap { Int($0) } ?? 0
        print("guest /data \(dataKB) kB")
        #expect(dataKB > 7_500_000 && dataKB < 8_600_000)

        // Screenshot (adb) and gRPC display/input
        let png = try await adb.screenshotPNG(serial)
        #expect(png.count > 10_000)
        let controller = try #require(await adapter.controller(for: instance))
        let status = try await controller.status()
        #expect(status.booted)
        let frame = try await controller.screenshot(EmulatorImageRequest(format: .rgba8888, width: 270, height: 600))
        #expect(frame.width > 0 && frame.pixels.count == frame.width * frame.height * 4)
        try await controller.send(.touch([EmulatorTouch(x: 100, y: 100, identifier: 1, pressure: 1)]))
        try await controller.send(.touch([EmulatorTouch(x: 100, y: 100, identifier: 1, pressure: 0)]))
        // Two-finger gesture: both pointers down, move apart, lift.
        try await controller.send(.touch([EmulatorTouch(x: 400, y: 1000, identifier: 1, pressure: 1),
                                          EmulatorTouch(x: 600, y: 1200, identifier: 2, pressure: 1)]))
        try await controller.send(.touch([EmulatorTouch(x: 300, y: 900, identifier: 1, pressure: 1),
                                          EmulatorTouch(x: 700, y: 1300, identifier: 2, pressure: 1)]))
        try await controller.send(.touch([EmulatorTouch(x: 300, y: 900, identifier: 1, pressure: 0),
                                          EmulatorTouch(x: 700, y: 1300, identifier: 2, pressure: 0)]))
        try await controller.setGPS(EmulatorGPSState(latitude: 48.8584, longitude: 2.2945, altitude: 35))
        #expect(abs(try await controller.gps().latitude - 48.8584) < 0.0001)
        try await controller.setClipboard("droiddeck-clipboard")
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await controller.clipboard() == "droiddeck-clipboard")

        // Hardware button through adb input (verified path for power/volume)
        try await adb.keyevent(serial, 3)

        // Files and media indexing
        let tmp = FileManager.default.temporaryDirectory.appending(path: "dd-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let local = tmp.appending(path: "it photo.png")
        try png.write(to: local)
        try await adb.makeDirectory(serial, path: "/sdcard/Pictures/DroidDeck")
        try await adb.push(serial, local: local, remote: "/sdcard/Pictures/DroidDeck/it photo.png")
        try await adb.scanMedia(serial, path: "/sdcard/Pictures/DroidDeck/it photo.png")
        let listing = try await adb.listDirectory(serial, path: "/sdcard/Pictures/DroidDeck")
        #expect(listing.contains { $0.name == "it photo.png" && $0.size == Int64(png.count) })
        try await Task.sleep(for: .seconds(1))
        let media = try await adb.shell(serial, "content query --uri content://media/external/images/media --projection _display_name:_size")
        #expect(media.contains("_display_name=it photo.png"), "MediaStore: \(media)")
        let pulled = tmp.appending(path: "pulled.png")
        try await adb.pull(serial, remote: "/sdcard/Pictures/DroidDeck/it photo.png", local: pulled)
        #expect(try Data(contentsOf: pulled) == png)

        // APK install: reinstall a system app's own APK as an update (same signature), then roll back.
        let apkPath = try await adb.shell(serial, "pm path com.android.egg", allowFailure: true)
            .split(separator: "\n").first.map { String($0.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces) }
        if let apkPath, !apkPath.isEmpty {
            let apk = tmp.appending(path: "egg.apk")
            try await adb.pull(serial, remote: apkPath, local: apk)
            if let aapt2 = sdk.aapt2 {
                let info = try await APKInfo.inspect(apk: apk, aapt2: aapt2, runner: sdk.runner)
                #expect(info.packageName == "com.android.egg")
            }
            var options = InstallOptions()
            options.replaceExisting = true
            _ = try await adb.install(serial, apks: [apk], options: options)
            let newPath = try await adb.shell(serial, "pm path com.android.egg")
            #expect(newPath.contains("/data/app/"), "installed path: \(newPath)")
            try await adb.uninstall(serial, package: "com.android.egg", keepData: false)
        } else {
            print("com.android.egg not present; skipping APK round trip")
        }
        let bogus = tmp.appending(path: "bogus.apk")
        try Data("not an apk".utf8).write(to: bogus)
        do {
            _ = try await adb.install(serial, apks: [bogus], options: InstallOptions())
            Issue.record("Installing an invalid APK should fail")
        } catch let error as DroidDeckError {
            print("bogus install diagnosed as: \(error.message) [\(error.detail?.split(separator: "\n").first ?? "")]")
            #expect(error.kind == .installFailed)
        }

        // Streamline: disable a preinstalled app and animations, then restore everything.
        let streamlineStart = try await DeviceStreamlining.state(serial: serial, adb: adb)
        if streamlineStart.installed.contains("com.google.android.youtube") {
            let failures = try await DeviceStreamlining.apply(serial: serial, adb: adb, disable: ["com.google.android.youtube"], animationsOff: true)
            #expect(failures.isEmpty)
            let after = try await DeviceStreamlining.state(serial: serial, adb: adb)
            #expect(after.disabled.contains("com.google.android.youtube") && after.animationsOff)
            try await DeviceStreamlining.restore(serial: serial, adb: adb)
            let restored = try await DeviceStreamlining.state(serial: serial, adb: adb)
            #expect(!restored.disabled.contains("com.google.android.youtube") && !restored.animationsOff)
        }

        // Console controls
        _ = try await adb.emu(serial, ["rotate"])
        _ = try await adb.emu(serial, ["rotate"])
        _ = try await adb.emu(serial, ["rotate"])
        _ = try await adb.emu(serial, ["rotate"])
        _ = try await adb.emu(serial, ["network", "speed", "lte"])
        _ = try await adb.emu(serial, ["network", "speed", "full"])
        _ = try await adb.emu(serial, ["geo", "fix", "2.2945", "48.8584"])

        // Pause / resume through the console; the VM state is visible over gRPC.
        _ = try await adb.emu(serial, ["avd", "pause"])
        #expect(try await controller.vmState() == .paused)
        _ = try await adb.emu(serial, ["avd", "resume"])
        #expect(try await controller.vmState() == .running)

        // Landscape touch mapping: Android's "show touches" dot must appear where DroidDeck aims.
        try await adb.shell(serial, "settings put system show_touches 1")
        try await adb.keyevent(serial, 3)
        _ = try await adb.emu(serial, ["rotate"])
        try await Task.sleep(for: .seconds(3))
        let before = try await controller.screenshot(EmulatorImageRequest(format: .rgba8888, width: 600, height: 600))
        try await Task.sleep(for: .milliseconds(600))
        print("after one console rotate: gRPC rotation \(before.rotation), frame \(before.width)x\(before.height), android rotation \(try await adb.shell(serial, "dumpsys window displays | grep -m1 -o 'mRotation=[A-Z_0-9]*'").trimmingCharacters(in: .whitespacesAndNewlines))")
        let target = (x: 0.30, y: 0.30)
        let geometry = DisplayGeometry(deviceWidth: config.screenWidth, deviceHeight: config.screenHeight, rotation: before.rotation)
        let p = geometry.devicePoint(normalizedX: target.x, normalizedY: target.y)
        try await controller.send(.touch([EmulatorTouch(x: p.x, y: p.y, identifier: 1, pressure: 1)]))
        try await Task.sleep(for: .milliseconds(150)) // short: a long press opens the launcher menu
        let during = try await controller.screenshot(EmulatorImageRequest(format: .rgba8888, width: 600, height: 600))
        try await controller.send(.touch([EmulatorTouch(x: p.x, y: p.y, identifier: 1, pressure: 0)]))
        var sx = 0.0, sy = 0.0, n = 0.0
        if before.width == during.width && before.height == during.height {
            for y in 0..<during.height {
                for x in 0..<during.width {
                    let i = (y * during.width + x) * 4
                    let d = abs(Int(during.pixels[i]) - Int(before.pixels[i])) + abs(Int(during.pixels[i + 1]) - Int(before.pixels[i + 1]))
                        + abs(Int(during.pixels[i + 2]) - Int(before.pixels[i + 2]))
                    if d > 60 { sx += Double(x); sy += Double(y); n += 1 }
                }
            }
        }
        let found = n > 0 ? (x: sx / n / Double(during.width), y: sy / n / Double(during.height)) : (x: -1.0, y: -1.0)
        print(String(format: "touch dot expected at (%.2f, %.2f), found at (%.2f, %.2f) from %.0f changed pixels", target.x, target.y, found.x, found.y, n))
        #expect(n > 0)
        #expect(abs(found.x - target.x) < 0.08 && abs(found.y - target.y) < 0.08)
        for _ in 0..<3 { _ = try await adb.emu(serial, ["rotate"]) }
        try await adb.shell(serial, "settings put system show_touches 0")

        // Snapshots
        try await adapter.saveSnapshot("it_snapshot", on: instance)
        #expect(await adapter.snapshots(of: device).contains { $0.name == "it_snapshot" })
        try await adapter.deleteSnapshot("it_snapshot", of: device, instance: instance)
        #expect(!(await adapter.snapshots(of: device).contains { $0.name == "it_snapshot" }))

        // Mutating operations are refused while running.
        await #expect(throws: DroidDeckError.self) { try await adapter.delete(device) }
        await #expect(throws: DroidDeckError.self) {
            _ = try await adapter.clone(device, as: "DD_IT_Nope", displayName: "x", includeUserData: true)
        }

        // Graceful stop
        try await adapter.stop(instance, force: false)
        #expect(!ProcessLiveness.isAlive(instance.pid))
        #expect(await adapter.runningInstances().allSatisfy { $0.pid != instance.pid })

        // Clone with data, then run both at once (multi-instance)
        let clone = try await adapter.clone(device, as: "DD_IT_B", displayName: "DD Integration B", includeUserData: true)
        #expect(clone.avd.config["avd.ini.displayname"] == "DD Integration B")
        async let a = adapter.start(device, options: { var o = LaunchOptions(); o.displayMode = .headless; return o }()) { _ in }
        async let b = adapter.start(clone, options: { var o = LaunchOptions(); o.displayMode = .headless; return o }()) { _ in }
        let (ia, ib) = try await (a, b)
        print("multi-instance: \(ia.adbSerial) + \(ib.adbSerial)")
        #expect(ia.consolePort != ib.consolePort && ia.grpcPort != ib.grpcPort)
        // The clone carries the original's user data (the pushed photo).
        let cloned = try await adb.listDirectory(ib.adbSerial, path: "/sdcard/Pictures/DroidDeck")
        #expect(cloned.contains { $0.name == "it photo.png" })
        try await adapter.stop(ia, force: false)
        try await adapter.stop(ib, force: true)

        // Delete
        try await adapter.delete(device)
        try await adapter.delete(clone)
        #expect(await adapter.devices().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: device.avd.directory.path))
    }

    @Test("Launch failures are diagnosed from the emulator log")
    func ramCeilingDiagnosis() {
        let error = EmulatorLaunchDiagnosis.diagnose(
            log: "INFO | ...\nqemu-system-aarch64-headless: mach-virt: cannot model more than 31GB RAM\n", exitCode: 1)
        #expect(error.message.contains("RAM"))
    }
}

final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [DeviceLifecycleState.StartPhase] = []
    func record(_ phase: DeviceLifecycleState.StartPhase) { lock.withLock { phases.append(phase) } }
    var all: [DeviceLifecycleState.StartPhase] { lock.withLock { phases } }
}
