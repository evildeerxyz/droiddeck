import Foundation
import DDCore
import DDPlatform

/// An AVD on disk: `<avdHome>/<name>.ini` pointing at `<name>.avd/config.ini`.
public struct AVDRecord: Sendable, Equatable, Identifiable {
    public var name: String
    public var pointerFile: URL
    public var directory: URL
    public var config: INIFile

    public var id: String { name }

    public var displayName: String { config["avd.ini.displayname"] ?? name.replacingOccurrences(of: "_", with: " ") }

    /// "system-images/android-34/google_apis/arm64-v8a/" → "system-images;android-34;google_apis;arm64-v8a".
    public var systemImagePackage: String? {
        guard let sysdir = config["image.sysdir.1"] else { return nil }
        let parts = sysdir.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "system-images" else { return nil }
        return parts.prefix(4).joined(separator: ";")
    }

    public var platform: AndroidPlatform? {
        systemImagePackage.flatMap(SystemImage.components(of:))?.platform
            ?? config["target"].flatMap(AndroidPlatform.init(sdkString:))
    }

    public var ram: Megabytes? { config["hw.ramSize"].flatMap(Megabytes.parse) }

    /// True when hw.ramSize carries a unit suffix ("2G", "3072M"). Verified with emulator
    /// 36.6.11: such values are ignored and the guest gets the emulator's minimum RAM.
    public var ramValueIgnoredByEmulator: Bool {
        guard let raw = config["hw.ramSize"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return false }
        return Int(raw) == nil
    }
    public var cpuCores: Int? { config["hw.cpu.ncore"].flatMap(Int.init) }
    public var playStoreEnabled: Bool { config.bool("PlayStore.enabled") ?? false }
    public var deviceProfileID: String? { config["hw.device.name"] }
    public var abi: String? { config["abi.type"] }
}

public enum AVDConfigKeys {
    // Hardware keys verified against emulator/lib/hardware-properties.ini (emulator 36.6.11).
    public static let ramSize = "hw.ramSize"
    public static let cpuCores = "hw.cpu.ncore"
    public static let heapSize = "vm.heapSize"
    public static let dataPartition = "disk.dataPartition.size"
    public static let sdCard = "hw.sdCard"
    public static let lcdWidth = "hw.lcd.width"
    public static let lcdHeight = "hw.lcd.height"
    public static let lcdDensity = "hw.lcd.density"
    public static let gpuMode = "hw.gpu.mode"
    public static let gpuEnabled = "hw.gpu.enabled"
    public static let cameraFront = "hw.camera.front"
    public static let cameraBack = "hw.camera.back"
    public static let keyboard = "hw.keyboard"
    public static let audioInput = "hw.audioInput"
    public static let audioOutput = "hw.audioOutput"
    public static let initialOrientation = "hw.initialOrientation"
    public static let deviceName = "hw.device.name"
    public static let forceColdBoot = "fastboot.forceColdBoot"
    public static let playStore = "PlayStore.enabled"
    // AVD properties written by Android Studio (observed in Studio-created config.ini files).
    public static let displayName = "avd.ini.displayname"
    public static let deviceManufacturer = "hw.device.manufacturer"
    public static let forceFastBoot = "fastboot.forceFastBoot"
    public static let skinName = "skin.name"
    public static let skinPath = "skin.path"
    public static let showDeviceFrame = "showDeviceFrame"
    public static let sdCardSize = "sdcard.size"
}

/// Reads and writes AVDs. Every mutating operation requires the device to be stopped;
/// callers (the runtime adapter) enforce that before calling in.
public struct AVDRepository: Sendable {
    public let avdHome: URL

    public init(avdHome: URL) {
        self.avdHome = avdHome
    }

    public func list() -> [AVDRecord] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: avdHome, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "ini" }
            .compactMap { record(pointer: $0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func record(named name: String) -> AVDRecord? {
        record(pointer: avdHome.appending(path: "\(name).ini"))
    }

    private func record(pointer: URL) -> AVDRecord? {
        guard let ini = try? INIFile(contentsOf: pointer) else { return nil }
        let name = pointer.deletingPathExtension().lastPathComponent
        var directory = ini["path"].map { URL(fileURLWithPath: $0) }
        if directory == nil || !FileManager.default.fileExists(atPath: directory!.path),
           let relative = ini["path.rel"] {
            directory = avdHome.deletingLastPathComponent().appending(path: relative)
        }
        guard let directory, let config = try? INIFile(contentsOf: directory.appending(path: "config.ini")) else { return nil }
        return AVDRecord(name: name, pointerFile: pointer, directory: directory, config: config)
    }

    /// Reads the parts of config.ini DroidDeck manages.
    public func configuration(of avd: AVDRecord) -> DeviceConfiguration {
        let c = avd.config
        var sensors = SensorSet()
        sensors.accelerometer = c.bool("hw.accelerometer") ?? true
        sensors.gyroscope = c.bool("hw.gyroscope") ?? true
        sensors.gps = c.bool("hw.gps") ?? true
        sensors.proximity = c.bool("hw.sensors.proximity") ?? true
        sensors.light = c.bool("hw.sensors.light") ?? true
        sensors.pressure = c.bool("hw.sensors.pressure") ?? true
        sensors.magneticField = c.bool("hw.sensors.magnetic_field") ?? true
        sensors.orientation = c.bool("hw.sensors.orientation") ?? true
        sensors.temperature = c.bool("hw.sensors.temperature") ?? true
        return DeviceConfiguration(
            avdName: avd.name,
            displayName: avd.displayName,
            systemImagePackage: avd.systemImagePackage ?? "",
            profileID: avd.deviceProfileID,
            ram: avd.ram ?? Megabytes(2048),
            cpuCores: avd.cpuCores ?? 2,
            vmHeap: c[AVDConfigKeys.heapSize].flatMap(Megabytes.parse),
            dataPartition: c[AVDConfigKeys.dataPartition].flatMap(Megabytes.parse) ?? Megabytes(6144),
            sdCard: c[AVDConfigKeys.sdCardSize].flatMap(Megabytes.parse),
            screenWidth: c[AVDConfigKeys.lcdWidth].flatMap(Int.init) ?? 1080,
            screenHeight: c[AVDConfigKeys.lcdHeight].flatMap(Int.init) ?? 2400,
            screenDensity: c[AVDConfigKeys.lcdDensity].flatMap(Int.init) ?? 420,
            gpuMode: c[AVDConfigKeys.gpuMode].flatMap(GPUMode.init(rawValue:)) ?? .auto,
            frontCamera: c[AVDConfigKeys.cameraFront].flatMap(CameraMode.init(rawValue:)) ?? .none,
            backCamera: c[AVDConfigKeys.cameraBack].flatMap(CameraMode.init(rawValue:)) ?? .emulated,
            hardwareKeyboard: c.bool(AVDConfigKeys.keyboard) ?? false,
            sensors: sensors,
            audioInput: c.bool(AVDConfigKeys.audioInput) ?? true,
            audioOutput: c.bool(AVDConfigKeys.audioOutput) ?? true,
            bootMode: c.bool(AVDConfigKeys.forceColdBoot) == true ? .coldBoot : .quickBoot,
            initialOrientation: c[AVDConfigKeys.initialOrientation].flatMap(Orientation.init(rawValue:)) ?? .portrait,
            skinName: c[AVDConfigKeys.skinName],
            showDeviceFrame: c.bool(AVDConfigKeys.showDeviceFrame) ?? false
        )
    }

    /// Writes a configuration into config.ini, preserving every key DroidDeck does not manage.
    public func apply(_ config: DeviceConfiguration, image: SystemImage?, profile: DeviceProfile?, skinDirectory: URL?, to avd: AVDRecord) throws {
        var ini = avd.config
        ini[AVDConfigKeys.displayName] = config.displayName
        ini[AVDConfigKeys.ramSize] = config.ram.plainMegabytesValue
        ini[AVDConfigKeys.cpuCores] = String(config.cpuCores)
        if let heap = config.vmHeap { ini[AVDConfigKeys.heapSize] = heap.plainMegabytesValue }
        ini[AVDConfigKeys.dataPartition] = config.dataPartition.diskSizeValue
        ini[AVDConfigKeys.lcdWidth] = String(config.screenWidth)
        ini[AVDConfigKeys.lcdHeight] = String(config.screenHeight)
        ini[AVDConfigKeys.lcdDensity] = String(config.screenDensity)
        ini[AVDConfigKeys.gpuMode] = config.gpuMode.rawValue
        ini.setBool(AVDConfigKeys.gpuEnabled, config.gpuMode != .software)
        ini[AVDConfigKeys.cameraFront] = config.frontCamera == .virtualscene ? CameraMode.emulated.rawValue : config.frontCamera.rawValue
        ini[AVDConfigKeys.cameraBack] = config.backCamera.rawValue
        ini.setBool(AVDConfigKeys.keyboard, config.hardwareKeyboard)
        ini.setBool(AVDConfigKeys.audioInput, config.audioInput)
        ini.setBool(AVDConfigKeys.audioOutput, config.audioOutput)
        ini[AVDConfigKeys.initialOrientation] = config.initialOrientation.rawValue
        ini.setBool("hw.accelerometer", config.sensors.accelerometer)
        ini.setBool("hw.gyroscope", config.sensors.gyroscope)
        ini.setBool("hw.gps", config.sensors.gps)
        ini.setBool("hw.sensors.proximity", config.sensors.proximity)
        ini.setBool("hw.sensors.light", config.sensors.light)
        ini.setBool("hw.sensors.pressure", config.sensors.pressure)
        ini.setBool("hw.sensors.magnetic_field", config.sensors.magneticField)
        ini.setBool("hw.sensors.orientation", config.sensors.orientation)
        ini.setBool("hw.sensors.temperature", config.sensors.temperature)
        ini.setBool(AVDConfigKeys.forceColdBoot, config.bootMode == .coldBoot)
        ini.setBool(AVDConfigKeys.forceFastBoot, config.bootMode == .quickBoot)
        if let image { ini.setBool(AVDConfigKeys.playStore, image.hasGooglePlay) }
        if let profile {
            ini[AVDConfigKeys.deviceName] = profile.id
            ini[AVDConfigKeys.deviceManufacturer] = profile.manufacturer
        }
        if let skinName = config.skinName, let skinDirectory, config.showDeviceFrame {
            ini[AVDConfigKeys.skinName] = skinName
            ini[AVDConfigKeys.skinPath] = skinDirectory.path
            ini.setBool(AVDConfigKeys.showDeviceFrame, true)
        } else {
            ini.setBool(AVDConfigKeys.showDeviceFrame, false)
        }
        try ini.write(to: avd.directory.appending(path: "config.ini"))
    }

    /// Runtime state files that must not be carried into a copy.
    /// qemu-version.txt and version_num.cache are deliberately kept: without them the emulator
    /// treats the copy's userdata as needing re-initialization and the copied data is lost
    /// (found by the integration test, confirmed by a manual copy that kept them).
    static let transientFiles = [
        "multiinstance.lock", "hardware-qemu.ini", "hardware-qemu.ini.lock", "emu-launch-params.txt",
        "bootcompleted.ini", "read-snapshot.txt", "snapshot.trace", "tmpAdbCmds",
    ]

    static let userDataFiles = [
        "userdata-qemu.img", "userdata-qemu.img.qcow2", "cache.img", "cache.img.qcow2",
        "encryptionkey.img", "encryptionkey.img.qcow2", "sdcard.img", "sdcard.img.qcow2", "data",
    ]

    /// Copies a stopped AVD. Disk overlays reference their backing files by relative
    /// path, so a directory copy is self-contained; the copy cold-boots the first time.
    public func clone(_ source: AVDRecord, as newName: String, displayName: String, includeUserData: Bool,
                      mksdcard: URL?, runner: ProcessRunner) async throws -> AVDRecord {
        guard AVDNaming.isValid(newName) else {
            throw DroidDeckError(.invalidConfiguration, "\(newName) is not a valid device identifier.")
        }
        let destination = avdHome.appending(path: "\(newName).avd")
        let pointer = avdHome.appending(path: "\(newName).ini")
        guard !FileManager.default.fileExists(atPath: destination.path),
              !FileManager.default.fileExists(atPath: pointer.path) else {
            throw DroidDeckError(.invalidConfiguration, "A device named \(newName) already exists.")
        }
        try SafeFileOperations.cloneDirectory(source.directory, to: destination)
        do {
            let fm = FileManager.default
            // Snapshots are always dropped: the emulator refuses to load a snapshot in a copied
            // AVD ("The emulator hardware cannot load snapshot"), so they would only waste disk space.
            var removals = Self.transientFiles + ["snapshots"]
            if !includeUserData { removals += Self.userDataFiles }
            for item in removals {
                let url = destination.appending(path: item)
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            }
            if !includeUserData, let sdSize = source.config[AVDConfigKeys.sdCardSize], let mksdcard,
               fm.fileExists(atPath: source.directory.appending(path: "sdcard.img").path) {
                let result = try await runner.run(mksdcard, ["-l", "DroidDeck", sdSize, destination.appending(path: "sdcard.img").path])
                if !result.succeeded {
                    throw DroidDeckError(.toolFailed, "Could not create a new SD card for the copy.", detail: result.diagnosticOutput)
                }
            }
            var config = try INIFile(contentsOf: destination.appending(path: "config.ini"))
            if config["AvdId"] != nil { config["AvdId"] = newName }
            config[AVDConfigKeys.displayName] = displayName
            try config.write(to: destination.appending(path: "config.ini"))
            var pointerINI = try INIFile(contentsOf: source.pointerFile)
            pointerINI["path"] = destination.path
            pointerINI["path.rel"] = "avd/\(newName).avd"
            try pointerINI.write(to: pointer)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: pointer)
            throw error
        }
        guard let record = record(named: newName) else {
            throw DroidDeckError(.fileOperationFailed, "The copy was created but could not be read back.")
        }
        return record
    }

    /// Base config.ini keys, mirroring what avdmanager (cmdline-tools 23.0) writes for a phone.
    /// Hardware values are then set by `apply`. Keys not listed fall back to emulator defaults.
    static let baseConfig: [(String, String)] = [
        ("avd.ini.encoding", "UTF-8"), ("disk.cachePartition", "yes"), ("disk.cachePartition.size", "66MB"),
        ("disk.dataPartition.path", "<temp>"), ("disk.systemPartition.size", "0"), ("disk.vendorPartition.size", "0"),
        ("fastboot.forceChosenSnapshotBoot", "no"), ("firstboot.bootFromDownloadableSnapshot", "yes"),
        ("firstboot.bootFromLocalSnapshot", "yes"), ("firstboot.saveToLocalSnapshot", "yes"),
        ("hw.accelerometer_uncalibrated", "yes"), ("hw.arc", "false"), ("hw.battery", "yes"),
        ("hw.camera.back.orientation", "90"), ("hw.camera.front.orientation", "90"), ("hw.dPad", "no"),
        ("hw.gltransport", "pipe"), ("hw.gsmModem", "yes"), ("hw.keyboard.charmap", "qwerty2"), ("hw.keyboard.lid", "yes"),
        ("hw.lcd.backlight", "yes"), ("hw.lcd.circular", "false"), ("hw.lcd.depth", "32"), ("hw.lcd.transparent", "false"),
        ("hw.lcd.vsync", "60"), ("hw.mainKeys", "no"), ("hw.screen", "multi-touch"), ("hw.sensors.gyroscope_uncalibrated", "yes"),
        ("hw.sensors.humidity", "yes"), ("hw.sensors.magnetic_field_uncalibrated", "yes"), ("hw.trackBall", "no"),
        ("hw.useext4", "yes"), ("kernel.newDeviceNaming", "autodetect"), ("kernel.supportsYaffs2", "autodetect"),
        ("runtime.network.latency", "none"), ("runtime.network.speed", "full"), ("userdata.useQcow2", "no"),
    ]

    /// Creates an AVD by writing its files directly, as Android Studio does, instead of starting
    /// avdmanager (a JVM, ~1.7 s per device). The emulator creates disk images on first boot.
    public func createDirect(_ config: DeviceConfiguration, image: SystemImage, sdkRoot: URL, profile: DeviceProfile?,
                             skinDirectory: URL?) throws -> AVDRecord {
        let name = config.avdName
        guard AVDNaming.isValid(name) else {
            throw DroidDeckError(.invalidConfiguration, "\(name) is not a valid device identifier.")
        }
        let fm = FileManager.default
        let directory = avdHome.appending(path: "\(name).avd")
        let pointer = avdHome.appending(path: "\(name).ini")
        guard !fm.fileExists(atPath: directory.path), !fm.fileExists(atPath: pointer.path) else {
            throw DroidDeckError(.invalidConfiguration, "A device named \(name) already exists.")
        }
        guard let installPath = image.installPath else {
            throw DroidDeckError(.invalidConfiguration, "\(image.title) is not installed.")
        }
        let imageDir = URL(fileURLWithPath: installPath)
        let root = SafeFileOperations.canonical(sdkRoot).path
        let canonicalImage = SafeFileOperations.canonical(imageDir).path
        guard canonicalImage.hasPrefix(root + "/") else {
            throw DroidDeckError(.invalidConfiguration, "The system image is outside the Android SDK.")
        }
        let sysdir = String(canonicalImage.dropFirst(root.count + 1)) + "/"
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var ini = INIFile(text: "")
            for (key, value) in Self.baseConfig { ini[key] = value }
            ini["AvdId"] = name
            ini["abi.type"] = image.abi
            ini["hw.cpu.arch"] = image.abi.hasPrefix("arm64") ? "arm64" : image.abi == "x86" ? "x86" : "x86_64"
            ini["image.sysdir.1"] = sysdir
            ini["target"] = image.platform.sdkString
            ini["tag.id"] = image.tagIDs.first ?? image.tagDirectory
            ini["tag.ids"] = image.tagIDs.joined(separator: ",")
            ini["tag.display"] = image.tagDisplay.split(separator: ",").first.map(String.init) ?? image.tagDisplay
            ini["tag.displaynames"] = image.tagDisplay
            ini.setBool("hw.sdCard", (config.sdCard?.value ?? 0) > 0)
            if let sd = config.sdCard, sd.value > 0 { ini[AVDConfigKeys.sdCardSize] = "\(sd.value)M" }
            try ini.write(to: directory.appending(path: "config.ini"))
            // avdmanager copies the image's initial user data when the image ships one.
            let userdata = imageDir.appending(path: "userdata.img")
            if fm.fileExists(atPath: userdata.path) {
                try fm.copyItem(at: userdata, to: directory.appending(path: "userdata.img"))
            }
            var pointerINI = INIFile(text: "")
            pointerINI["avd.ini.encoding"] = "UTF-8"
            pointerINI["path"] = directory.path
            pointerINI["path.rel"] = "avd/\(name).avd"
            pointerINI["target"] = image.platform.sdkString
            try pointerINI.write(to: pointer)
            guard let created = record(named: name) else {
                throw DroidDeckError(.fileOperationFailed, "The device files were written but could not be read back.")
            }
            try apply(config, image: image, profile: profile, skinDirectory: skinDirectory, to: created)
            return record(named: name) ?? created
        } catch {
            try? fm.removeItem(at: directory)
            try? fm.removeItem(at: pointer)
            throw error
        }
    }

    /// skin.name without a resolvable skin.path makes the emulator exit with "unknown skin name".
    public func skinConfigurationIsBroken(_ avd: AVDRecord, sdkRoot: URL) -> Bool {
        guard let name = avd.config[AVDConfigKeys.skinName], !name.isEmpty, name != "_no_skin",
              !name.contains("x") || Int(name.split(separator: "x").first ?? "") == nil else { return false }
        if let path = avd.config[AVDConfigKeys.skinPath], FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appending(path: "layout").path) {
            return false
        }
        return true
    }

    /// Points skin.path at the SDK's copy of the skin, or removes the skin when none exists.
    public func repairSkin(_ avd: AVDRecord, sdkRoot: URL) throws {
        var ini = avd.config
        if let name = ini[AVDConfigKeys.skinName],
           let dir = SkinLayout.directory(named: name, sdkRoot: sdkRoot, systemImagePath: nil) {
            ini[AVDConfigKeys.skinPath] = dir.path
        } else {
            ini[AVDConfigKeys.skinName] = nil
            ini[AVDConfigKeys.skinPath] = nil
            ini.setBool(AVDConfigKeys.showDeviceFrame, false)
        }
        try ini.write(to: avd.directory.appending(path: "config.ini"))
    }

    /// Rewrites a suffixed hw.ramSize ("2G") as plain megabytes so the emulator applies it.
    public func normalizeRAMValue(_ avd: AVDRecord) throws {
        guard avd.ramValueIgnoredByEmulator, let ram = avd.ram else { return }
        var ini = avd.config
        ini[AVDConfigKeys.ramSize] = ram.plainMegabytesValue
        try ini.write(to: avd.directory.appending(path: "config.ini"))
    }

    public func snapshotsDirectory(of avd: AVDRecord) -> URL { avd.directory.appending(path: "snapshots") }

    public struct StorageBreakdown: Sendable, Equatable {
        public var userData: Int64
        public var quickBootSnapshot: Int64
        public var otherSnapshots: Int64
        public var sdCard: Int64
        public var other: Int64
        public var total: Int64 { userData + quickBootSnapshot + otherSnapshots + sdCard + other }
        /// Space that can be reclaimed without losing apps or accounts.
        public var reclaimable: Int64 { quickBootSnapshot + sdCard }
    }

    /// On-disk (allocated) usage by category. Disk images are sparse, so this is real usage.
    public func storage(of avd: AVDRecord) -> StorageBreakdown {
        let fm = FileManager.default
        var breakdown = StorageBreakdown(userData: 0, quickBootSnapshot: 0, otherSnapshots: 0, sdCard: 0, other: 0)
        for item in (try? fm.contentsOfDirectory(atPath: avd.directory.path)) ?? [] {
            let url = avd.directory.appending(path: item)
            if item == "snapshots" {
                for snapshot in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] {
                    let size = SafeFileOperations.allocatedSize(of: url.appending(path: snapshot))
                    if snapshot == "default_boot" { breakdown.quickBootSnapshot += size } else { breakdown.otherSnapshots += size }
                }
                continue
            }
            let size = SafeFileOperations.allocatedSize(of: url)
            if item.hasPrefix("userdata") || item.hasPrefix("data") || item.hasPrefix("encryptionkey") || item.hasPrefix("cache") {
                breakdown.userData += size
            } else if item.hasPrefix("sdcard") {
                breakdown.sdCard += size
            } else {
                breakdown.other += size
            }
        }
        return breakdown
    }

    /// Deletes the Quick Boot snapshot. The next start is a cold boot; apps and data are kept.
    public func deleteQuickBootSnapshot(_ avd: AVDRecord) throws {
        let dir = snapshotsDirectory(of: avd).appending(path: "default_boot")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try SafeFileOperations.remove(dir, within: avd.directory, useTrash: false)
    }

    /// Removes the removable SD card image (shared storage lives in internal storage instead).
    public func removeSDCard(_ avd: AVDRecord) throws {
        for name in ["sdcard.img", "sdcard.img.qcow2"] {
            let url = avd.directory.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) {
                try SafeFileOperations.remove(url, within: avd.directory, useTrash: false)
            }
        }
        var ini = avd.config
        ini.setBool("hw.sdCard", false)
        ini[AVDConfigKeys.sdCardSize] = nil
        try ini.write(to: avd.directory.appending(path: "config.ini"))
    }

    /// Typing from the Mac keyboard requires hw.keyboard=yes (verified: with "no", key events are ignored).
    public func enableHardwareKeyboard(_ avd: AVDRecord) throws {
        var ini = avd.config
        ini.setBool(AVDConfigKeys.keyboard, true)
        try ini.write(to: avd.directory.appending(path: "config.ini"))
    }
}

/// Wraps avdmanager for creation, deletion and renaming (the supported tool for these operations).
public struct AVDManagerClient: Sendable {
    public let installation: SDKInstallation

    public init(installation: SDKInstallation) {
        self.installation = installation
    }

    private func executable() throws -> URL {
        guard let tool = installation.avdmanager else {
            throw DroidDeckError(.toolMissing, "avdmanager was not found.",
                                 recovery: "Install \"Android SDK Command-line Tools (latest)\" from Android Studio's SDK Manager.")
        }
        guard installation.javaHome != nil else {
            throw DroidDeckError(.toolMissing, "A Java runtime (17 or later) is required by avdmanager.",
                                 recovery: "Install Android Studio, which bundles a compatible runtime.")
        }
        return tool.url
    }

    /// Device ids known to this avdmanager (`avdmanager list device -c`).
    public func knownDeviceIDs() async throws -> Set<String> {
        let result = try await installation.runner.run(try executable(), ["list", "device", "-c"], timeout: .seconds(120))
        guard result.succeeded else { return [] }
        // One id per line on stdout; ids may contain spaces ("Nexus 7 2013"). Warnings go to stderr.
        return Set(result.stdoutString.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("Warning") && !$0.hasPrefix("[") && !$0.hasPrefix("Loading") })
    }

    /// `avdmanager create avd`. Answers "no" to the custom-hardware-profile question;
    /// hardware is applied to config.ini afterwards by AVDRepository.apply.
    public func create(name: String, package: String, deviceID: String?, sdCard: Megabytes?) async throws {
        var args = ["create", "avd", "-n", name, "-k", package, "-p", installation.avdHome.appending(path: "\(name).avd").path]
        if let deviceID { args += ["-d", deviceID] }
        if let sdCard, sdCard.value > 0 { args += ["-c", "\(sdCard.value)M"] }
        let result = try await installation.runner.run(try executable(), args, input: Data("no\n".utf8), timeout: .seconds(300))
        guard result.succeeded, FileManager.default.fileExists(atPath: installation.avdHome.appending(path: "\(name).ini").path) else {
            throw DroidDeckError(.toolFailed, "avdmanager could not create the device.",
                                 recovery: "Check that the system image is fully installed.", detail: result.diagnosticOutput)
        }
    }

    public func delete(name: String) async throws {
        let result = try await installation.runner.run(try executable(), ["delete", "avd", "-n", name], timeout: .seconds(120))
        guard result.succeeded else {
            throw DroidDeckError(.toolFailed, "avdmanager could not delete \(name).", detail: result.diagnosticOutput)
        }
    }

    public func rename(name: String, to newName: String) async throws {
        let result = try await installation.runner.run(try executable(), ["move", "avd", "-n", name, "-r", newName], timeout: .seconds(120))
        guard result.succeeded else {
            throw DroidDeckError(.toolFailed, "avdmanager could not rename \(name).", detail: result.diagnosticOutput)
        }
    }
}
