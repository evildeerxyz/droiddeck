import Foundation
import DDCore
import DDPlatform
import DDAndroidSDK
import DDADB
import DDEmulatorGRPC

/// RuntimeAdapter for Google's Android Emulator, driven through avdmanager,
/// the emulator binary, adb, the emulator console (`adb emu`), and gRPC.
public actor AndroidEmulatorAdapter: RuntimeAdapter {
    public nonisolated let identifier = "android-emulator"
    public nonisolated let displayName = "Android Emulator"

    public nonisolated let installation: SDKInstallation
    public nonisolated let host: HostEnvironment
    public nonisolated let adb: ADBClient
    public nonisolated let repository: AVDRepository
    private let avdManager: AVDManagerClient
    private let logRoot: URL

    private var launched: [String: LaunchedProcess] = [:]
    private var controllers: [Int32: EmulatorControllerClient] = [:]
    private var stopping: Set<String> = []
    /// Ports handed to launches that have not yet published a discovery file.
    /// Allocation and reservation happen without an intervening suspension point,
    /// so concurrent starts can never receive the same ports.
    private var pendingPorts: [String: Set<Int>] = [:]
    private var imageCache: (stamp: [String: Date], images: [SystemImage])?

    public init(installation: SDKInstallation, host: HostEnvironment = .current(),
                logRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DroidDeck/Emulators")) throws {
        guard let adbTool = installation.adb else {
            throw DroidDeckError(.toolMissing, "Android SDK Platform-Tools (adb) are not installed.",
                                 recovery: "Install \"Android SDK Platform-Tools\" from Android Studio's SDK Manager.")
        }
        self.installation = installation
        self.host = host
        self.adb = ADBClient(executable: adbTool.url, runner: installation.runner)
        self.repository = AVDRepository(avdHome: installation.avdHome)
        self.avdManager = AVDManagerClient(installation: installation)
        self.logRoot = logRoot
    }

    // MARK: Detection

    public func detect() async -> RuntimeDetection {
        var checks: [CompatibilityCheck] = []
        checks.append(CompatibilityCheck(
            id: "host", title: "Mac", status: host.isTranslated ? .warning : .ok,
            detail: "\(host.architecture.displayName) · \(host.physicalMemory) memory · \(host.logicalCPUs) cores · \(host.osVersion)",
            recovery: host.isTranslated ? "DroidDeck is running under Rosetta. Run the native build for best performance." : nil
        ))
        if let emulator = installation.emulator {
            checks.append(CompatibilityCheck(id: "emulator", title: "Android Emulator", status: .ok,
                                             detail: "Version \(emulator.version?.description ?? "unknown")"))
            checks.append(await accelerationCheck(emulator.url))
        } else {
            checks.append(CompatibilityCheck(id: "emulator", title: "Android Emulator", status: .error,
                                             detail: "Not installed in \(installation.root.path).",
                                             recovery: "Install the \"Android Emulator\" package from Android Studio's SDK Manager."))
        }
        if let adbTool = installation.adb {
            checks.append(CompatibilityCheck(id: "adb", title: "Platform-Tools (adb)", status: .ok,
                                             detail: "Version \(adbTool.version?.description ?? "unknown")"))
        } else {
            checks.append(CompatibilityCheck(id: "adb", title: "Platform-Tools (adb)", status: .error, detail: "Not installed.",
                                             recovery: "Install \"Android SDK Platform-Tools\"."))
        }
        for other in installation.conflictingADBs {
            checks.append(CompatibilityCheck(
                id: "adb-conflict-\(other.url.path)", title: "Second adb installation", status: .warning,
                detail: "\(other.url.path) is version \(other.version?.description ?? "unknown"). Different adb versions restart each other's server, which disconnects devices.",
                recovery: "Use the SDK's platform-tools adb in Terminal, or update both to the same version."))
        }
        if installation.avdmanager == nil || installation.javaHome == nil {
            checks.append(CompatibilityCheck(
                id: "cmdline-tools", title: "Command-line Tools", status: .warning,
                detail: installation.avdmanager == nil ? "avdmanager/sdkmanager are not installed." : "No Java 17+ runtime found for avdmanager.",
                recovery: "Device creation and image downloads need Android SDK Command-line Tools and Android Studio's Java runtime."))
        } else {
            checks.append(CompatibilityCheck(id: "cmdline-tools", title: "Command-line Tools", status: .ok,
                                             detail: "Version \(installation.avdmanager?.version?.description ?? "unknown")"))
        }
        let images = SystemImageCatalog.installedImages(sdkRoot: installation.root)
        let runnable = images.filter { $0.androidABI.map(host.architecture.acceleratedABIs.contains) ?? false }
        checks.append(CompatibilityCheck(
            id: "images", title: "System images", status: runnable.isEmpty ? .warning : .ok,
            detail: runnable.isEmpty
                ? "No \(host.architecture.acceleratedABIs.map(\.rawValue).joined(separator: "/")) system images installed."
                : "\(runnable.count) compatible image\(runnable.count == 1 ? "" : "s") installed (\(images.count - runnable.count) incompatible).",
            recovery: runnable.isEmpty ? "Download a system image in System Images." : nil))
        if let disk = DiskSpace.forVolume(containing: installation.avdHome) {
            let low = disk.available < 8 * 1_073_741_824
            checks.append(CompatibilityCheck(id: "disk", title: "Disk space", status: low ? .warning : .ok,
                                             detail: "\(ByteFormat.fileString(disk.available)) free for devices.",
                                             recovery: low ? "Each device needs several GB; free disk space." : nil))
        }
        return RuntimeDetection(runtimeName: displayName, host: host, installation: installation, checks: checks)
    }

    /// `emulator -accel-check` exits 0 when Hypervisor.framework acceleration is usable.
    private func accelerationCheck(_ emulator: URL) async -> CompatibilityCheck {
        let result = try? await installation.runner.run(emulator, ["-accel-check"], timeout: .seconds(30))
        let output = result?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ok = result?.exitCode == 0
        // Output is "accel:\n<status code>\n<description>\naccel"; show the description.
        let summary = output.split(separator: "\n").map(String.init)
            .first { !$0.isEmpty && $0 != "accel" && $0 != "accel:" && Int($0) == nil } ?? output
        return CompatibilityCheck(
            id: "acceleration", title: "Hardware acceleration", status: ok ? .ok : .error,
            detail: ok ? summary : "Acceleration is unavailable: \(summary)",
            recovery: ok ? nil : "Android Emulator needs macOS Hypervisor.framework. Quit other virtualization apps and try again.")
    }

    // MARK: Capabilities

    public func capabilities(for device: VirtualDevice?, instance: RunningInstance?) async -> CapabilityReport {
        var report = CapabilityReport()
        let canManage = installation.avdmanager != nil && installation.javaHome != nil
        if canManage { report.enable(.createDevice) } else {
            report.disable(.createDevice, because: "Install Android SDK Command-line Tools and Android Studio (for Java).")
        }
        if installation.emulator != nil { report.enable(.externalWindow) } else {
            report.disable(.externalWindow, because: "The Android Emulator package is not installed.")
        }
        guard let device else { return report }

        let running = instance != nil
        if running {
            for cap in [RuntimeCapability.deleteDevice, .cloneDevice, .wipeData, .coldBoot] {
                report.disable(cap, because: "Stop the device first.")
            }
            report.enable(.stopDevice, .forceStop)
            report.disable(.startDevice, because: "The device is already running.")
        } else {
            report.enable(.startDevice, .coldBoot, .wipeData, .cloneDevice)
            report.enable(.deleteDevice) // avdmanager, or contained file removal when it is unavailable.
            for cap in [RuntimeCapability.stopDevice, .forceStop] { report.disable(cap, because: "The device is not running.") }
        }
        if device.image == nil {
            report.disable(.startDevice, because: "The device's system image is not installed.")
        }
        report.enable(.backupExport)
        report.enable(.snapshots)

        guard let instance else {
            let needsRunning = "Start the device to use this."
            for cap in [RuntimeCapability.embeddedDisplay, .touchInput, .multiTouchInput, .keyboardInput, .hardwareButtons,
                        .rotation, .screenshot, .clipboard, .apkInstall, .fileTransfer, .logcat, .shell, .appLaunch,
                        .mediaSync, .gpsSimulation, .sensorSimulation, .batterySimulation, .networkShaping, .keyMapping] {
                report.disable(cap, because: needsRunning)
            }
            return report
        }
        report.enable(.hardwareButtons, .rotation, .screenshot, .apkInstall, .fileTransfer, .logcat, .shell,
                      .appLaunch, .mediaSync, .gpsSimulation, .sensorSimulation, .batterySimulation, .networkShaping)
        if instance.hasControlChannel {
            report.enable(.embeddedDisplay, .touchInput, .multiTouchInput, .keyboardInput, .clipboard, .keyMapping)
            if !device.configuration.hardwareKeyboard {
                report.disable(.keyboardInput, because: "Typing from your Mac needs the hardware keyboard setting. Turn it on in the device's Info tab.")
            }
        } else {
            let reason = "This emulator was started without its gRPC control channel. Restart it from DroidDeck."
            for cap in [RuntimeCapability.embeddedDisplay, .touchInput, .multiTouchInput, .keyboardInput, .clipboard, .keyMapping] {
                report.disable(cap, because: reason)
            }
        }
        return report
    }

    // MARK: Inventory

    /// Installed images, rescanned only when the system-images tree changes (cheap stat calls).
    private func cachedImages() -> [SystemImage] {
        let fm = FileManager.default
        let base = installation.systemImagesDirectory
        var stamp: [String: Date] = [:]
        func record(_ url: URL) {
            stamp[url.path] = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        record(base)
        for platform in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
            let platformURL = base.appending(path: platform)
            record(platformURL)
            for tag in (try? fm.contentsOfDirectory(atPath: platformURL.path)) ?? [] { record(platformURL.appending(path: tag)) }
        }
        if let cache = imageCache, cache.stamp == stamp { return cache.images }
        let images = SystemImageCatalog.installedImages(sdkRoot: installation.root)
        imageCache = (stamp, images)
        return images
    }

    public func devices() async -> [VirtualDevice] {
        let images = cachedImages()
        return repository.list().map { avd in
            VirtualDevice(avd: avd, configuration: repository.configuration(of: avd),
                          image: images.first { $0.packagePath == avd.systemImagePackage })
        }
    }

    public func installedImages() async -> [SystemImage] {
        cachedImages()
    }

    public func runningInstances() async -> [RunningInstance] {
        let ours = Set(launched.values.filter(\.isRunning).map(\.pid))
        return EmulatorDiscovery.runningInstances(launchedPIDs: ours)
    }

    private func instance(for device: VirtualDevice) async -> RunningInstance? {
        let target = SafeFileOperations.canonical(device.avd.directory).path
        return await runningInstances().first {
            $0.avdDirectory.map { SafeFileOperations.canonical($0).path } == target
        }
    }

    private func requireStopped(_ device: VirtualDevice, for action: String) async throws {
        if await instance(for: device) != nil {
            throw DroidDeckError(.deviceBusy, "Stop \(device.displayName) before you \(action).")
        }
    }

    // MARK: Create / update / clone / delete

    public func create(_ configuration: DeviceConfiguration, profile: DeviceProfile?, image: SystemImage) async throws -> VirtualDevice {
        guard image.isInstalled else {
            throw DroidDeckError(.invalidConfiguration, "\(image.title) is not installed.")
        }
        if repository.record(named: configuration.avdName) != nil {
            throw DroidDeckError(.invalidConfiguration, "A device named \(configuration.avdName) already exists.")
        }
        let skin = skinDirectory(configuration.skinName, image: image)
        let avd: AVDRecord
        do {
            avd = try repository.createDirect(configuration, image: image, sdkRoot: installation.root, profile: profile, skinDirectory: skin)
        } catch let error as DroidDeckError where error.kind == .invalidConfiguration {
            throw error
        } catch {
            // Fall back to the SDK tool if writing the files directly failed for another reason.
            log.warning("runtime", "Direct AVD creation failed (\(error)); using avdmanager")
            let known = (try? await avdManager.knownDeviceIDs()) ?? []
            let deviceID = profile.flatMap { known.contains($0.id) ? $0.id : nil }
            try await avdManager.create(name: configuration.avdName, package: image.packagePath,
                                        deviceID: deviceID, sdCard: configuration.sdCard)
            guard let record = repository.record(named: configuration.avdName) else {
                throw DroidDeckError(.fileOperationFailed, "The device was created but its configuration could not be read.")
            }
            try repository.apply(configuration, image: image, profile: profile, skinDirectory: skin, to: record)
            avd = record
        }
        log.info("runtime", "Created AVD \(configuration.avdName) from \(image.packagePath)")
        return VirtualDevice(avd: avd, configuration: repository.configuration(of: avd), image: image)
    }

    public func update(_ device: VirtualDevice, to configuration: DeviceConfiguration, profile: DeviceProfile?) async throws -> VirtualDevice {
        try await requireStopped(device, for: "change its hardware")
        try repository.apply(configuration, image: device.image, profile: profile,
                             skinDirectory: skinDirectory(configuration.skinName, image: device.image), to: device.avd)
        let refreshed = repository.record(named: device.name) ?? device.avd
        return VirtualDevice(avd: refreshed, configuration: repository.configuration(of: refreshed), image: device.image)
    }

    public func clone(_ device: VirtualDevice, as newName: String, displayName: String, includeUserData: Bool) async throws -> VirtualDevice {
        try await requireStopped(device, for: "copy it")
        let avd = try await repository.clone(device.avd, as: newName, displayName: displayName, includeUserData: includeUserData,
                                             mksdcard: installation.mksdcard, runner: installation.runner)
        log.info("runtime", "Cloned \(device.name) to \(newName) (user data: \(includeUserData))")
        return VirtualDevice(avd: avd, configuration: repository.configuration(of: avd), image: device.image)
    }

    public func delete(_ device: VirtualDevice) async throws {
        try await requireStopped(device, for: "delete it")
        if installation.avdmanager != nil, installation.javaHome != nil {
            do {
                try await avdManager.delete(name: device.name)
                log.info("runtime", "Deleted AVD \(device.name) with avdmanager")
                return
            } catch {
                log.warning("runtime", "avdmanager delete failed, falling back to file removal: \(error)")
            }
        }
        // Fallback: remove exactly the AVD directory and its pointer file, inside the AVD home only.
        try SafeFileOperations.remove(device.avd.directory, within: installation.avdHome, useTrash: false)
        try SafeFileOperations.remove(device.avd.pointerFile, within: installation.avdHome, useTrash: false)
    }

    private func skinDirectory(_ name: String?, image: SystemImage?) -> URL? {
        guard let name else { return nil }
        return SkinLayout.directory(named: name, sdkRoot: installation.root, systemImagePath: image?.installPath)
    }

    // MARK: Start / stop

    public func start(_ device: VirtualDevice, options: LaunchOptions,
                      onPhase: @escaping @Sendable (DeviceLifecycleState.StartPhase) -> Void) async throws -> RunningInstance {
        do {
            return try await launch(device, options: options, onPhase: onPhase)
        } catch is QuickBootSnapshotUnusable {
            // The saved machine state can't be restored. Discard it and boot Android normally;
            // apps, accounts and files live on the data disk, not in the snapshot.
            log.info("runtime", "\(device.name): Quick Boot snapshot could not be restored; discarded it and cold booting")
            try? repository.deleteQuickBootSnapshot(device.avd)
            var cold = options
            cold.coldBoot = true
            onPhase(.recovering)
            return try await launch(device, options: cold, onPhase: onPhase)
        }
    }

    private func launch(_ device: VirtualDevice, options: LaunchOptions,
                        onPhase: @escaping @Sendable (DeviceLifecycleState.StartPhase) -> Void) async throws -> RunningInstance {
        guard let emulator = installation.emulator else {
            throw DroidDeckError(.toolMissing, "The Android Emulator package is not installed.")
        }
        if let existing = await instance(for: device) {
            throw DroidDeckError(.deviceBusy, "\(device.displayName) is already running (pid \(existing.pid)).")
        }
        guard let image = device.image else {
            throw DroidDeckError(.invalidConfiguration, "The system image for \(device.displayName) is not installed.",
                                 recovery: "Install \(device.configuration.systemImagePackage) in System Images.")
        }
        let missing = SystemImageCatalog.missingFiles(in: image)
        guard missing.isEmpty else {
            throw DroidDeckError(.invalidConfiguration, "The system image is incomplete (missing \(missing.joined(separator: ", "))).",
                                 recovery: "Reinstall the system image.")
        }
        if let abi = image.androidABI, !host.architecture.acceleratedABIs.contains(abi) {
            throw DroidDeckError(.unsupported, "\(abi.displayName) images cannot run on this Mac.")
        }
        let limits = RuntimeLimits.androidEmulator(host: host.architecture, hostPhysicalMemory: host.physicalMemory)
        if device.configuration.ram > limits.maximumRAM {
            throw DroidDeckError(.invalidConfiguration, "\(device.configuration.ram) exceeds the emulator's \(limits.maximumRAM) limit.",
                                 recovery: limits.maximumRAMSource)
        }

        onPhase(.launching)
        let instances = await runningInstances()
        var reserved = Set(instances.flatMap { [$0.consolePort, $0.adbPort, $0.grpcPort ?? 0] })
        // Other emulators (e.g. third-party players) may hold emulator-<port> serials without discovery files.
        for adbDevice in (try? await adb.devices()) ?? [] {
            if let port = adbDevice.consolePort { reserved.formUnion([port, port + 1]) }
        }
        guard pendingPorts[device.name] == nil else {
            throw DroidDeckError(.deviceBusy, "\(device.displayName) is already starting.")
        }
        reserved.formUnion(pendingPorts.values.flatMap { $0 })
        guard let ports = PortAllocator.consolePortPair(excluding: reserved),
              let grpcPort = PortAllocator.grpcPort(excluding: reserved) else {
            throw DroidDeckError(.launchFailed, "No free ports are available for another emulator.",
                                 recovery: "Stop a running device and try again.")
        }
        pendingPorts[device.name] = [ports.console, ports.adb, grpcPort]
        defer { pendingPorts[device.name] = nil }

        var args = ["-avd", device.name, "-ports", "\(ports.console),\(ports.adb)", "-grpc", "\(grpcPort)", "-grpc-use-token", "-no-metrics",
                    // No crash-upload consent dialog (it crashes when the window is hidden) and nothing is sent to Google.
                    "-crash-report-mode", "never",
                    // Skips the boot animation: faster boots and less GPU work while booting.
                    "-no-boot-anim"]
        switch options.displayMode {
        case .embedded: args.append("-qt-hide-window")   // keeps host-GPU rendering; -no-window forces software
        case .headless: args.append("-no-window")
        case .externalWindow: break
        }
        // No -gpu override: config.ini's hw.gpu.mode decides. With Automatic the emulator uses the Mac GPU for
        // Android 14 and older and software rendering for Android 15+ ("API level 35 requires GLES 3.1"). The Mac
        // GPU path offers OpenGL ES 3.0 only; forcing it on Android 15+ broke Chrome/WebView ("EGL_BAD_CONFIG: no ES
        // 3.1 support", so Google sign-in closed itself) and TikTok video (static). Verified 2026-10-28.
        let quickBoot = !(options.coldBoot || device.configuration.bootMode == .coldBoot)
        if !quickBoot { args.append("-no-snapshot-load") }
        // Cold Boot devices never write a Quick Boot snapshot (saves several GB per device).
        if device.configuration.bootMode == .coldBoot { args.append("-no-snapshot-save") }
        if options.wipeData { args.append("-wipe-data") }
        if !options.saveSnapshotOnExit && device.configuration.bootMode != .coldBoot { args.append("-no-snapshot-save") }
        if let speed = options.networkSpeed { args += ["-netspeed", speed] }
        if let latency = options.networkLatency { args += ["-netdelay", latency] }
        if !options.dnsServers.isEmpty { args += ["-dns-server", options.dnsServers.joined(separator: ",")] }

        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let logFile = logRoot.appending(path: "\(device.name)/emulator-\(stamp).log")
        var environment = installation.environment
        // The emulator's CoreAudio output keeps only ~45 ms buffered (512 frames x 4) and crackles or
        // drops out whenever the emulator is busy, e.g. video apps on several devices. 1024 x 4 (~85 ms)
        // rides out those hiccups; verified that audio still reaches the Mac. User-set values win.
        environment["QEMU_COREAUDIO_BUFFER_SIZE"] = environment["QEMU_COREAUDIO_BUFFER_SIZE"] ?? "1024"
        environment["QEMU_COREAUDIO_BUFFER_COUNT"] = environment["QEMU_COREAUDIO_BUFFER_COUNT"] ?? "4"
        let process: LaunchedProcess
        do {
            process = try LaunchedProcess(executable: emulator.url, arguments: args, environment: environment, logFile: logFile)
        } catch {
            throw DroidDeckError(.launchFailed, "The emulator could not be launched.", detail: error.localizedDescription)
        }
        launched[device.name] = process
        log.info("runtime", "Launched \(device.name) pid \(process.pid) console \(ports.console) grpc \(grpcPort) mode \(options.displayMode.rawValue)")

        do {
            let running = try await waitForDiscovery(process: process, device: device)
            onPhase(.waitingForADB)
            try await waitForBoot(process: process, serial: running.adbSerial, timeout: options.bootTimeout,
                                  watchSnapshot: quickBoot, onPhase: onPhase)
            log.info("runtime", "\(device.name) booted")
            return running
        } catch {
            let snapshotFailed = error is QuickBootSnapshotUnusable
                || (quickBoot && EmulatorLaunchDiagnosis.quickBootSnapshotFailed(log: process.logTail(maxBytes: 64_000)))
            if process.isRunning {
                // After a failed restore the machine is half-loaded: it hangs or crashes, and a normal
                // stop would save that broken state as the new snapshot. Kill it without saving.
                if snapshotFailed { process.kill() } else { process.terminate() }
                _ = await process.waitForExit()
            }
            launched[device.name] = nil
            if snapshotFailed { throw QuickBootSnapshotUnusable() }
            if let error = error as? DroidDeckError, error.kind != .launchFailed { throw error }
            if error is CancellationError { throw DroidDeckError.cancelled }
            throw EmulatorLaunchDiagnosis.diagnose(log: process.logTail(maxBytes: 20_000), exitCode: process.terminationStatus)
        }
    }

    private func waitForDiscovery(process: LaunchedProcess, device: VirtualDevice) async throws -> RunningInstance {
        let file = EmulatorDiscovery.discoveryFile(pid: process.pid)
        for _ in 0..<120 {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw EmulatorLaunchDiagnosis.diagnose(log: process.logTail(maxBytes: 20_000), exitCode: process.terminationStatus)
            }
            if let ini = try? INIFile(contentsOf: file), ini["grpc.token"] != nil,
               let instance = EmulatorDiscovery.instance(from: ini, pid: process.pid, launchedByDroidDeck: true) {
                return instance
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw DroidDeckError(.launchFailed, "The emulator started but did not publish its connection details within 60 seconds.",
                             detail: process.logTail())
    }

    private func waitForBoot(process: LaunchedProcess, serial: String, timeout: Duration, watchSnapshot: Bool,
                             onPhase: @escaping @Sendable (DeviceLifecycleState.StartPhase) -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [adb] in
                try await adb.waitForBoot(serial, timeout: timeout, onPhase: onPhase)
            }
            group.addTask {
                // Fails fast if the emulator dies during boot, or reports that its snapshot didn't restore.
                while process.isRunning {
                    if watchSnapshot, EmulatorLaunchDiagnosis.quickBootSnapshotFailed(log: process.logTail(maxBytes: 64_000)) {
                        throw QuickBootSnapshotUnusable()
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                throw EmulatorLaunchDiagnosis.diagnose(log: process.logTail(maxBytes: 20_000), exitCode: process.terminationStatus)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Graceful stop through the console (lets the emulator save its Quick Boot snapshot),
    /// escalating to SIGTERM and SIGKILL. `force` skips the graceful step.
    public func stop(_ instance: RunningInstance, force: Bool) async throws {
        guard !stopping.contains(instance.avdName) else { return }
        stopping.insert(instance.avdName)
        defer { stopping.remove(instance.avdName) }
        if let controller = controllers.removeValue(forKey: instance.pid) { await controller.close() }

        if !force {
            // Flush the guest page cache first. Quick Boot saves RAM, not dirty pages, to the
            // snapshot; without this, recent writes exist only in the snapshot and are missing
            // from the disk image used by clones and backups (verified by integration test).
            _ = try? await adb.shell(instance.adbSerial, "sync", timeout: .seconds(30), allowFailure: true)
            _ = try? await adb.emu(instance.adbSerial, ["kill"], timeout: .seconds(15))
            if await waitForExit(pid: instance.pid, timeout: .seconds(90)) {
                finishStop(instance)
                return
            }
            log.warning("runtime", "\(instance.avdName) did not exit after console kill; terminating")
        }
        kill(instance.pid, SIGTERM)
        if await waitForExit(pid: instance.pid, timeout: .seconds(10)) {
            finishStop(instance)
            return
        }
        kill(instance.pid, SIGKILL)
        if await waitForExit(pid: instance.pid, timeout: .seconds(5)) {
            finishStop(instance)
            return
        }
        throw DroidDeckError(.toolFailed, "The emulator process \(instance.pid) could not be stopped.")
    }

    private func finishStop(_ instance: RunningInstance) {
        launched[instance.avdName] = nil
        log.info("runtime", "Stopped \(instance.avdName)")
    }

    private func waitForExit(pid: Int32, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if !ProcessLiveness.isAlive(pid) { return true }
            // Reap our own children so they do not linger as zombies (kill(pid, 0) succeeds on zombies).
            if launched.values.contains(where: { $0.pid == pid && !$0.isRunning }) { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return !ProcessLiveness.isAlive(pid)
    }

    // MARK: Snapshots

    public func snapshots(of device: VirtualDevice) async -> [SnapshotInfo] {
        let root = repository.snapshotsDirectory(of: device.avd)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return dirs.compactMap { dir -> SnapshotInfo? in
            guard FileManager.default.fileExists(atPath: dir.appending(path: "snapshot.pb").path) else { return nil }
            let screenshot = dir.appending(path: "screenshot.png")
            return SnapshotInfo(
                name: dir.lastPathComponent,
                directory: dir,
                sizeBytes: SafeFileOperations.allocatedSize(of: dir),
                created: (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                screenshot: FileManager.default.fileExists(atPath: screenshot.path) ? screenshot : nil
            )
        }
        .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    public func saveSnapshot(_ name: String, on instance: RunningInstance) async throws {
        try Self.validateSnapshotName(name)
        _ = try await adb.emu(instance.adbSerial, ["avd", "snapshot", "save", name], timeout: .seconds(300))
    }

    public func loadSnapshot(_ name: String, on instance: RunningInstance) async throws {
        try Self.validateSnapshotName(name)
        _ = try await adb.emu(instance.adbSerial, ["avd", "snapshot", "load", name], timeout: .seconds(300))
    }

    public func deleteSnapshot(_ name: String, of device: VirtualDevice, instance: RunningInstance?) async throws {
        try Self.validateSnapshotName(name)
        if let instance {
            _ = try await adb.emu(instance.adbSerial, ["avd", "snapshot", "delete", name], timeout: .seconds(120))
        } else {
            let dir = repository.snapshotsDirectory(of: device.avd).appending(path: name)
            try SafeFileOperations.remove(dir, within: repository.snapshotsDirectory(of: device.avd), useTrash: false)
        }
    }

    static func validateSnapshotName(_ name: String) throws {
        guard AVDNaming.isValid(name) else {
            throw DroidDeckError(.invalidConfiguration, "Snapshot names may only contain letters, numbers, '.', '_' and '-'.")
        }
    }

    // MARK: Control channel

    public func controller(for instance: RunningInstance) async -> EmulatorControllerClient? {
        guard let port = instance.grpcPort, let token = instance.grpcToken, let p = UInt16(exactly: port) else { return nil }
        if let existing = controllers[instance.pid] { return existing }
        let client = EmulatorControllerClient(port: p, token: token)
        controllers[instance.pid] = client
        return client
    }

    public func logFile(for avdName: String) async -> URL? {
        if let process = launched[avdName] { return process.logFile }
        let dir = logRoot.appending(path: avdName)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.max {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }
}

/// The emulator could not restore the Quick Boot snapshot (the launch is retried as a cold boot).
struct QuickBootSnapshotUnusable: Error {}
