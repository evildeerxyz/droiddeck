import Foundation
import Observation
import DDCore
import DDPlatform

/// Host memory/disk and per-emulator process usage. Reports what the host actually
/// spends (process footprint), which is usually far below a device's configured RAM.
@MainActor
@Observable
public final class ResourceMonitor {
    public struct DeviceUsage: Equatable, Sendable {
        public var footprintBytes: Int64
        public var cpuPercent: Double?
        public var configuredRAM: Megabytes
    }

    public enum Warning: Equatable, Sendable, Identifiable {
        case memoryPressure(HostMemorySnapshot.Pressure)
        case committedMemory(configured: Megabytes, physical: Megabytes)
        case lowDisk(available: Int64)

        public var id: String {
            switch self {
            case .memoryPressure: return "pressure"
            case .committedMemory: return "committed"
            case .lowDisk: return "disk"
            }
        }

        public var message: String {
            switch self {
            case .memoryPressure(let level):
                return level == .critical
                    ? "macOS is under critical memory pressure. Stop a device to keep the Mac responsive."
                    : "macOS reports elevated memory pressure."
            case .committedMemory(let configured, let physical):
                return "Running devices are configured for \(configured) of RAM on a \(physical) Mac. Actual use is lower, but heavy workloads can exhaust memory."
            case .lowDisk(let available):
                return "Only \(ByteFormat.fileString(available)) free for devices. Devices may fail to start or save snapshots."
            }
        }
    }

    public private(set) var memory = HostMemorySnapshot(total: 0, used: 0, wired: 0, compressed: 0, pressure: .unknown)
    public private(set) var disk: DiskSpace?
    public private(set) var usage: [String: DeviceUsage] = [:]
    public private(set) var warnings: [Warning] = []
    public private(set) var avdDiskUsage: [String: Int64] = [:]

    private let sampler = ProcessMetricsSampler()
    private var task: Task<Void, Never>?
    private weak var devices: DeviceManager?

    public init() {}

    /// Samples on an adaptive schedule: every 2 s with devices running in an active app,
    /// slower on battery, and rarely while DroidDeck is in the background.
    public func start(devices: DeviceManager) {
        self.devices = devices
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sample()
                let interval = devices.refreshPolicy.metricsInterval(runningDevices: devices.runningDevices.count)
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public var totalEmulatorFootprint: Int64 { usage.values.reduce(0) { $0 + $1.footprintBytes } }

    private func sample() {
        // Publish only meaningful changes: assigning an @Observable property re-renders observers
        // (e.g. the sidebar footer) even for a tiny delta, and frequent re-renders can drive a
        // NavigationSplitView constraint loop. 64 MB / 256 MB thresholds keep the UI steady.
        let newMemory = HostMemorySnapshot.sample()
        if newMemory.pressure != memory.pressure || newMemory.total != memory.total
            || abs(newMemory.used - memory.used) > 64 * 1_048_576 {
            memory = newMemory
        }
        guard let devices else { return }
        if let home = devices.sdk?.avdHome {
            let newDisk = DiskSpace.forVolume(containing: home)
            if disk == nil || abs((newDisk?.available ?? 0) - (disk?.available ?? 0)) > 256 * 1_048_576 {
                disk = newDisk
            }
        }
        var next: [String: DeviceUsage] = [:]
        var committed = 0
        for device in devices.runningDevices {
            guard let instance = device.instance else { continue }
            committed += device.device.configuration.ram.value
            if let sample = sampler.sample(pid: instance.pid) {
                next[device.id] = DeviceUsage(footprintBytes: sample.footprintBytes, cpuPercent: sample.cpuPercent,
                                              configuredRAM: device.device.configuration.ram)
            }
        }
        usage = next

        var warnings: [Warning] = []
        if memory.pressure == .warning || memory.pressure == .critical {
            warnings.append(.memoryPressure(memory.pressure))
        }
        let physical = Megabytes(Int(memory.total / 1_048_576))
        if committed > physical.value * 3 / 4 {
            warnings.append(.committedMemory(configured: Megabytes(committed), physical: physical))
        }
        if let disk, disk.available < 8 * 1_073_741_824 {
            warnings.append(.lowDisk(available: disk.available))
        }
        self.warnings = warnings
    }

    /// Measures on-disk size of each AVD (sparse images report real usage). Runs off the main actor.
    public func measureDiskUsage() async {
        guard let devices else { return }
        let targets = devices.devices.map { ($0.id, $0.device.avd.directory) }
        let sizes = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: targets.map { ($0.0, SafeFileOperations.allocatedSize(of: $0.1)) })
        }.value
        avdDiskUsage = sizes
    }
}
