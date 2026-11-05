import Foundation
import DDCore
import DDPlatform
import DDAndroidSDK
import DDEmulatorGRPC

public struct CompatibilityCheck: Sendable, Identifiable, Equatable {
    public enum Status: Sendable, Equatable { case ok, warning, error }
    public var id: String
    public var title: String
    public var status: Status
    public var detail: String
    public var recovery: String?

    public init(id: String, title: String, status: Status, detail: String, recovery: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.recovery = recovery
    }
}

public struct RuntimeDetection: Sendable, Equatable {
    public var runtimeName: String
    public var host: HostEnvironment
    public var installation: SDKInstallation?
    public var checks: [CompatibilityCheck]

    public init(runtimeName: String, host: HostEnvironment, installation: SDKInstallation?, checks: [CompatibilityCheck]) {
        self.runtimeName = runtimeName
        self.host = host
        self.installation = installation
        self.checks = checks
    }

    /// The runtime can start devices (blocking errors absent).
    public var canRunDevices: Bool {
        installation?.emulator != nil && installation?.adb != nil && !checks.contains { $0.status == .error && $0.id != "cmdline-tools" }
    }

    public var canCreateDevices: Bool { canRunDevices && installation?.avdmanager != nil && installation?.javaHome != nil }
}

/// A virtual device known to the runtime (an AVD).
public struct VirtualDevice: Sendable, Equatable, Identifiable {
    public var avd: AVDRecord
    public var configuration: DeviceConfiguration
    public var image: SystemImage?

    public var id: String { avd.name }
    public var name: String { avd.name }
    public var displayName: String { configuration.displayName }
}

/// A running emulator process, whether DroidDeck started it or not.
public struct RunningInstance: Sendable, Equatable {
    public var pid: Int32
    public var avdName: String
    public var avdDirectory: URL?
    public var consolePort: Int
    public var adbPort: Int
    public var grpcPort: Int?
    /// gRPC bearer token from the discovery file. Never log or display this value.
    public var grpcToken: String?
    public var displayMode: DisplayMode
    public var launchedByDroidDeck: Bool
    public var emulatorVersion: String?
    public var startedAt: Date?

    public var adbSerial: String { "emulator-\(consolePort)" }
    public var hasControlChannel: Bool { grpcPort != nil && grpcToken != nil }

    public var details: RunningDetails {
        RunningDetails(pid: pid, adbSerial: adbSerial, consolePort: consolePort, grpcPort: grpcPort,
                       launchedByDroidDeck: launchedByDroidDeck, displayMode: displayMode, startedAt: startedAt)
    }
}

public struct LaunchOptions: Sendable, Equatable {
    public var displayMode: DisplayMode = .embedded
    public var coldBoot = false
    public var wipeData = false
    public var saveSnapshotOnExit = true
    /// Emulator `-netspeed` values: gsm, hscsd, gprs, edge, umts, hsdpa, lte, evdo, 5g, full.
    public var networkSpeed: String?
    /// Emulator `-netdelay` values: gsm, hscsd, gprs, edge, umts, hsdpa, lte, evdo, none.
    public var networkLatency: String?
    public var dnsServers: [String] = []
    public var bootTimeout: Duration = .seconds(300)

    public init() {}
}

public struct SnapshotInfo: Sendable, Equatable, Identifiable {
    public var name: String
    public var directory: URL
    public var sizeBytes: Int64
    public var created: Date?
    public var screenshot: URL?
    public var isQuickBoot: Bool { name == "default_boot" }
    public var id: String { name }
}

/// The boundary between DroidDeck and a virtualization runtime. The UI never calls
/// runtime tools directly; it asks for capabilities and invokes these operations.
public protocol RuntimeAdapter: Sendable {
    var identifier: String { get }
    var displayName: String { get }

    func detect() async -> RuntimeDetection
    func capabilities(for device: VirtualDevice?, instance: RunningInstance?) async -> CapabilityReport

    func devices() async -> [VirtualDevice]
    func installedImages() async -> [SystemImage]
    func runningInstances() async -> [RunningInstance]

    func create(_ configuration: DeviceConfiguration, profile: DeviceProfile?, image: SystemImage) async throws -> VirtualDevice
    func update(_ device: VirtualDevice, to configuration: DeviceConfiguration, profile: DeviceProfile?) async throws -> VirtualDevice
    func clone(_ device: VirtualDevice, as newName: String, displayName: String, includeUserData: Bool) async throws -> VirtualDevice
    func delete(_ device: VirtualDevice) async throws

    func start(_ device: VirtualDevice, options: LaunchOptions,
               onPhase: @escaping @Sendable (DeviceLifecycleState.StartPhase) -> Void) async throws -> RunningInstance
    func stop(_ instance: RunningInstance, force: Bool) async throws

    func snapshots(of device: VirtualDevice) async -> [SnapshotInfo]
    func saveSnapshot(_ name: String, on instance: RunningInstance) async throws
    func loadSnapshot(_ name: String, on instance: RunningInstance) async throws
    func deleteSnapshot(_ name: String, of device: VirtualDevice, instance: RunningInstance?) async throws

    func controller(for instance: RunningInstance) async -> EmulatorControllerClient?
    func logFile(for avdName: String) async -> URL?
}
