import Foundation
import Darwin
import DDCore

/// Facts about the Mac DroidDeck is running on.
public struct HostEnvironment: Sendable, Equatable {
    /// The hardware architecture. Reports `.arm64` on Apple Silicon even under Rosetta.
    public var architecture: CPUArchitecture
    /// True when this process runs translated by Rosetta 2.
    public var isTranslated: Bool
    public var physicalMemory: Megabytes
    public var logicalCPUs: Int
    /// Performance cores on Apple Silicon; physical cores on Intel; 0 if unknown.
    public var performanceCPUs: Int
    public var modelIdentifier: String
    public var cpuBrand: String
    public var osVersion: String

    public static func current() -> HostEnvironment {
        let armHardware = sysctlInt("hw.optional.arm64") == 1
        return HostEnvironment(
            architecture: armHardware ? .arm64 : .x86_64,
            isTranslated: sysctlInt("sysctl.proc_translated") == 1,
            physicalMemory: Megabytes(Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)),
            logicalCPUs: ProcessInfo.processInfo.activeProcessorCount,
            performanceCPUs: sysctlInt("hw.perflevel0.physicalcpu") ?? sysctlInt("hw.physicalcpu") ?? 0,
            modelIdentifier: sysctlString("hw.model") ?? "Mac",
            cpuBrand: sysctlString("machdep.cpu.brand_string") ?? "",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    public static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size {
            return Int(Int32(truncatingIfNeeded: value))
        }
        return Int(value)
    }

    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Host memory and disk state, sampled on demand.
public struct HostMemorySnapshot: Sendable, Equatable {
    public enum Pressure: String, Sendable {
        case normal, warning, critical, unknown
    }

    public var total: Int64
    /// Approximates Activity Monitor's "Memory Used": app + wired + compressed.
    public var used: Int64
    public var wired: Int64
    public var compressed: Int64
    public var pressure: Pressure

    public init(total: Int64, used: Int64, wired: Int64, compressed: Int64, pressure: Pressure) {
        self.total = total
        self.used = used
        self.wired = wired
        self.compressed = compressed
        self.pressure = pressure
    }

    public static func sample() -> HostMemorySnapshot {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let pressureLevel = HostEnvironment.sysctlInt("kern.memorystatus_vm_pressure_level")
        let pressure: Pressure
        switch pressureLevel {
        case 1: pressure = .normal
        case 2: pressure = .warning
        case 4: pressure = .critical
        default: pressure = .unknown
        }
        guard result == KERN_SUCCESS else {
            return HostMemorySnapshot(total: total, used: 0, wired: 0, compressed: 0, pressure: pressure)
        }
        let page = Int64(getpagesize())
        let internalPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        let app = max(0, internalPages) * page
        return HostMemorySnapshot(total: total, used: app + wired + compressed, wired: wired,
                                  compressed: compressed, pressure: pressure)
    }
}

public struct DiskSpace: Sendable, Equatable {
    public var available: Int64
    public var total: Int64

    public init(available: Int64, total: Int64) {
        self.available = available
        self.total = total
    }

    /// Free space for the volume containing `url` (or its nearest existing ancestor).
    public static func forVolume(containing url: URL) -> DiskSpace? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        guard let values = try? probe.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ]) else { return nil }
        return DiskSpace(
            available: values.volumeAvailableCapacityForImportantUsage ?? 0,
            total: Int64(values.volumeTotalCapacity ?? 0)
        )
    }
}

/// Per-process resource usage via proc_pid_rusage, with CPU% computed from deltas.
public final class ProcessMetricsSampler: @unchecked Sendable {
    public struct Sample: Sendable, Equatable {
        public var pid: Int32
        /// Physical footprint (what Activity Monitor shows as Memory).
        public var footprintBytes: Int64
        /// CPU usage since the previous sample, in percent of one core (can exceed 100).
        public var cpuPercent: Double?
    }

    private let lock = NSLock()
    private var previous: [Int32: (cpuNanos: UInt64, at: UInt64)] = [:]
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    public init() {}

    public func sample(pid: Int32) -> Sample? {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard status == 0 else {
            lock.withLock { _ = previous.removeValue(forKey: pid) }
            return nil
        }
        // ri_user_time/ri_system_time are in Mach absolute time units on Apple Silicon.
        let cpuTicks = info.ri_user_time + info.ri_system_time
        let cpuNanos = cpuTicks * timebase.numer / timebase.denom
        let now = DispatchTime.now().uptimeNanoseconds
        let percent: Double? = lock.withLock {
            defer { previous[pid] = (cpuNanos, now) }
            guard let last = previous[pid], now > last.at, cpuNanos >= last.cpuNanos else { return nil }
            return Double(cpuNanos - last.cpuNanos) / Double(now - last.at) * 100
        }
        return Sample(pid: pid, footprintBytes: Int64(info.ri_phys_footprint), cpuPercent: percent)
    }

    public func forget(pid: Int32) {
        lock.withLock { _ = previous.removeValue(forKey: pid) }
    }
}
