import Foundation
import DDCore
import DDPlatform
import DDPersistence
import DDRuntime

/// Builds a diagnostics archive. Every file is redacted at export level (secrets,
/// emails, home directory) and the user sees the file list before saving.
public enum DiagnosticsExporter {
    public struct Item: Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var contents: String
    }

    @MainActor
    public static func collect(devices: DeviceManager, resources: ResourceMonitor) async -> [Item] {
        var items: [Item] = []
        let host = devices.host
        var summary = """
        DroidDeck diagnostics — \(Date().formatted(.iso8601))
        App version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")
        Mac: \(host.modelIdentifier) \(host.cpuBrand) · \(host.architecture.rawValue)\(host.isTranslated ? " (Rosetta)" : "")
        macOS: \(host.osVersion)
        Memory: \(host.physicalMemory) · CPU cores: \(host.logicalCPUs) (performance: \(host.performanceCPUs))
        Memory used: \(ByteFormat.string(resources.memory.used)) · pressure: \(resources.memory.pressure.rawValue)
        Disk free (AVD volume): \(resources.disk.map { ByteFormat.fileString($0.available) } ?? "unknown")

        """
        if let sdk = devices.sdk {
            summary += """
            SDK: \(sdk.root.path)
            AVD home: \(sdk.avdHome.path)
            Emulator: \(sdk.emulator?.version?.description ?? "missing")
            adb: \(sdk.adb?.version?.description ?? "missing")
            Command-line tools: \(sdk.avdmanager?.version?.description ?? "missing")
            Java: \(sdk.javaHome?.path ?? "missing")

            """
        }
        for check in devices.detection?.checks ?? [] {
            summary += "[\(check.status)] \(check.title): \(check.detail)\(check.recovery.map { " — \($0)" } ?? "")\n"
        }
        items.append(Item(name: "summary.txt", contents: summary))

        var deviceText = ""
        for device in devices.devices {
            let c = device.device.configuration
            deviceText += """
            \(device.displayName) [\(device.id)] — \(device.state.label)
              image: \(c.systemImagePackage)
              profile: \(c.profileID ?? "custom") · RAM \(c.ram) · cores \(c.cpuCores) · storage \(c.dataPartition)
              screen: \(c.screenWidth)x\(c.screenHeight) @ \(c.screenDensity)dpi · GPU \(c.gpuMode.rawValue)
              RAM value applied by emulator: \(device.device.avd.ramValueIgnoredByEmulator ? "NO (unit suffix in config.ini)" : "yes")
            \(device.instance.map { "  running: pid \($0.pid), \($0.adbSerial), gRPC \($0.grpcPort.map(String.init) ?? "none"), mode \($0.displayMode.rawValue)\n" } ?? "")
            """
        }
        for other in devices.connectedDevices {
            deviceText += "ADB device \(other.adb.serial) (\(other.kindDescription)) state \(other.adb.state.rawValue)\n"
        }
        items.append(Item(name: "devices.txt", contents: deviceText))

        let history = devices.tasks.history.prefix(200).map {
            "\($0.finishedAt.formatted(.iso8601)) \($0.outcome.rawValue) \($0.title)\($0.message.map { ": \($0)" } ?? "")"
        }.joined(separator: "\n")
        items.append(Item(name: "operations.txt", contents: history))

        let appLog = AppLog.shared.recentEntries().suffix(3000).map {
            "\($0.date.formatted(.iso8601)) [\($0.level.rawValue)] \($0.category): \($0.message)"
        }.joined(separator: "\n")
        items.append(Item(name: "droiddeck.log", contents: appLog))

        for device in devices.devices {
            if let file = await devices.emulatorLogFile(device.id), let data = try? Data(contentsOf: file) {
                items.append(Item(name: "emulator-\(device.id).log", contents: String(decoding: data.suffix(200_000), as: UTF8.self)))
            }
        }
        return items.map { Item(name: $0.name, contents: Redactor.redact($0.contents, level: .export)) }
    }

    /// Writes the items into a zip archive using ditto.
    public static func write(_ items: [Item], to destination: URL) async throws {
        let staging = FileManager.default.temporaryDirectory.appending(path: "DroidDeck-Diagnostics-\(UUID().uuidString)")
        let folder = staging.appending(path: "DroidDeck Diagnostics")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for item in items {
            try Data(item.contents.utf8).write(to: folder.appending(path: item.name))
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                                   ["-c", "-k", "--keepParent", folder.path, destination.path], timeout: .seconds(120))
        guard result.succeeded else {
            throw DroidDeckError(.fileOperationFailed, "Could not create the diagnostics archive.", detail: result.diagnosticOutput)
        }
    }
}
