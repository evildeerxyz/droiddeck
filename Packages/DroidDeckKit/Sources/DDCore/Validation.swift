import Foundation

/// Limits imposed by the runtime itself, independent of host resources.
public struct RuntimeLimits: Sendable, Equatable {
    public var maximumRAM: Megabytes
    /// True when the limit was measured against the installed runtime rather than assumed.
    public var maximumRAMVerified: Bool
    public var maximumRAMSource: String
    public var minimumRAM: Megabytes
    public var minimumDataPartition: Megabytes
    public var screenDimensionRange: ClosedRange<Int>
    public var densityRange: ClosedRange<Int>

    public init(maximumRAM: Megabytes, maximumRAMVerified: Bool, maximumRAMSource: String,
                minimumRAM: Megabytes = Megabytes(1024), minimumDataPartition: Megabytes = Megabytes(2048),
                screenDimensionRange: ClosedRange<Int> = 240...8192, densityRange: ClosedRange<Int> = 120...800) {
        self.maximumRAM = maximumRAM
        self.maximumRAMVerified = maximumRAMVerified
        self.maximumRAMSource = maximumRAMSource
        self.minimumRAM = minimumRAM
        self.minimumDataPartition = minimumDataPartition
        self.screenDimensionRange = screenDimensionRange
        self.densityRange = densityRange
    }

    /// Limits for the Android Emulator on a given host architecture.
    ///
    /// arm64: QEMU's `mach-virt` machine rejects more than 31 GB ("mach-virt: cannot model
    /// more than 31GB RAM"); 31744 MB boots. Measured with emulator 36.6.11 on Apple Silicon.
    /// x86_64: no runtime ceiling has been measured on Intel hardware, so the host policy applies.
    public static func androidEmulator(host: CPUArchitecture, hostPhysicalMemory: Megabytes) -> RuntimeLimits {
        switch host {
        case .arm64:
            return RuntimeLimits(
                maximumRAM: Megabytes(31 * 1024),
                maximumRAMVerified: true,
                maximumRAMSource: "Measured: QEMU mach-virt on Apple Silicon accepts at most 31 GB (emulator 36.6.11)."
            )
        case .x86_64:
            return RuntimeLimits(
                maximumRAM: Megabytes(max(4096, hostPhysicalMemory.value - 4096)),
                maximumRAMVerified: false,
                maximumRAMSource: "Not measured on Intel hardware; limited by host memory policy."
            )
        }
    }
}

/// Snapshot of host state used to validate a configuration.
public struct HostResources: Sendable, Equatable {
    public var architecture: CPUArchitecture
    public var physicalMemory: Megabytes
    public var logicalCPUs: Int
    public var performanceCPUs: Int
    /// Free space on the volume holding AVDs.
    public var availableDiskBytes: Int64
    /// Sum of configured RAM of devices already running.
    public var runningDevicesRAM: Megabytes

    public init(architecture: CPUArchitecture, physicalMemory: Megabytes, logicalCPUs: Int,
                performanceCPUs: Int, availableDiskBytes: Int64, runningDevicesRAM: Megabytes = Megabytes(0)) {
        self.architecture = architecture
        self.physicalMemory = physicalMemory
        self.logicalCPUs = logicalCPUs
        self.performanceCPUs = performanceCPUs
        self.availableDiskBytes = availableDiskBytes
        self.runningDevicesRAM = runningDevicesRAM
    }

    /// Memory DroidDeck never allocates to guests, to keep macOS responsive.
    public static let reservedHostMemory = Megabytes(4096)
}

public struct ValidationIssue: Hashable, Sendable, Identifiable {
    public enum Severity: Int, Sendable, Comparable {
        case info, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Field: String, Sendable {
        case name, displayName, image, ram, cpu, storage, sdCard, screen, gpu, host
    }

    public var severity: Severity
    public var field: Field
    public var message: String
    public var suggestion: String?

    public var id: String { "\(field.rawValue):\(message)" }

    public init(_ severity: Severity, _ field: Field, _ message: String, suggestion: String? = nil) {
        self.severity = severity
        self.field = field
        self.message = message
        self.suggestion = suggestion
    }
}

public struct ValidationResult: Sendable {
    public var issues: [ValidationIssue]

    public var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { errors.isEmpty }

    public func issues(for field: ValidationIssue.Field) -> [ValidationIssue] {
        issues.filter { $0.field == field }
    }
}

/// Pure validation of a device configuration against runtime limits and host resources.
public struct ConfigurationValidator: Sendable {
    /// Requests for less are raised to this size by the emulator (measured: 4 GB → 6 GB).
    public static let observedMinimumDataPartition = Megabytes(6144)

    public var host: HostResources
    public var limits: RuntimeLimits
    public var existingAVDNames: Set<String>
    public var image: SystemImage?
    public var emulatorVersion: PackageVersion?
    /// When editing an existing device its own name is not a conflict.
    public var editingAVDName: String?

    public init(host: HostResources, limits: RuntimeLimits, existingAVDNames: Set<String>,
                image: SystemImage?, emulatorVersion: PackageVersion?, editingAVDName: String? = nil) {
        self.host = host
        self.limits = limits
        self.existingAVDNames = existingAVDNames
        self.image = image
        self.emulatorVersion = emulatorVersion
        self.editingAVDName = editingAVDName
    }

    public func validate(_ config: DeviceConfiguration) -> ValidationResult {
        var issues: [ValidationIssue] = []
        validateNames(config, &issues)
        validateImage(config, &issues)
        validateRAM(config, &issues)
        validateCPU(config, &issues)
        validateStorage(config, &issues)
        validateScreen(config, &issues)
        if config.gpuMode == .software {
            issues.append(.init(.warning, .gpu, "Software rendering is much slower than the host GPU.",
                                suggestion: "Use Automatic unless the host GPU causes rendering problems."))
        }
        return ValidationResult(issues: issues.sorted { $0.severity > $1.severity })
    }

    private func validateNames(_ config: DeviceConfiguration, _ issues: inout [ValidationIssue]) {
        if config.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(.error, .displayName, "Enter a device name."))
        }
        if !AVDNaming.isValid(config.avdName) {
            issues.append(.init(.error, .name, "The device identifier may only contain letters, numbers, '.', '_' and '-'.",
                                suggestion: "Try \(AVDNaming.suggest(from: config.displayName, existing: existingAVDNames))."))
        } else if config.avdName != editingAVDName,
                  existingAVDNames.contains(where: { $0.caseInsensitiveCompare(config.avdName) == .orderedSame }) {
            issues.append(.init(.error, .name, "A device named \(config.avdName) already exists.",
                                suggestion: "Try \(AVDNaming.suggest(from: config.displayName, existing: existingAVDNames))."))
        }
    }

    private func validateImage(_ config: DeviceConfiguration, _ issues: inout [ValidationIssue]) {
        guard let image else {
            issues.append(.init(.error, .image, "Choose a system image."))
            return
        }
        if !image.isInstalled {
            issues.append(.init(.error, .image, "\(image.title) is not installed.",
                                suggestion: "Download it from System Images first."))
        }
        if let abi = image.androidABI, !host.architecture.acceleratedABIs.contains(abi) {
            issues.append(.init(.error, .image,
                                "\(abi.displayName) images cannot run with acceleration on \(host.architecture.displayName) Macs.",
                                suggestion: "Choose an image with the \(host.architecture.acceleratedABIs[0].rawValue) ABI."))
        }
        if let required = image.minimumEmulatorVersion, let installed = emulatorVersion, installed < required {
            issues.append(.init(.error, .image, "This image needs Android Emulator \(required) or later (installed: \(installed)).",
                                suggestion: "Update the Android Emulator package."))
        }
        if image.isAutomatedTestDevice {
            issues.append(.init(.warning, .image, "Automated Test Device images remove most apps and are intended for headless testing."))
        }
        if image.formFactor != .phone {
            issues.append(.init(.info, .image, "This is a \(image.formFactor.displayName) image."))
        }
    }

    private func validateRAM(_ config: DeviceConfiguration, _ issues: inout [ValidationIssue]) {
        let ram = config.ram
        let hostCeiling = Megabytes(host.physicalMemory.value - HostResources.reservedHostMemory.value)
        if ram < limits.minimumRAM {
            issues.append(.init(.error, .ram, "At least \(limits.minimumRAM) of RAM is required."))
        } else if ram < Megabytes(2048) {
            issues.append(.init(.warning, .ram, "Modern Android versions run poorly with less than 2 GB.",
                                suggestion: "The emulator may raise RAM automatically for high-resolution screens."))
        }
        if ram > limits.maximumRAM {
            issues.append(.init(.error, .ram, "The emulator supports at most \(limits.maximumRAM) on this Mac.",
                                suggestion: limits.maximumRAMSource))
        } else if ram > hostCeiling {
            issues.append(.init(.error, .ram,
                                "\(ram) leaves less than \(HostResources.reservedHostMemory) for macOS on this \(host.physicalMemory) Mac.",
                                suggestion: "Choose \(Megabytes(max(limits.minimumRAM.value, hostCeiling.value))) or less."))
        } else if ram.value * 2 > host.physicalMemory.value {
            issues.append(.init(.warning, .ram, "\(ram) is more than half of this Mac's memory.",
                                suggestion: "Guest memory is allocated on demand, but heavy use can cause memory pressure."))
        }
        if !limits.maximumRAMVerified && ram > Megabytes(16 * 1024) {
            issues.append(.init(.warning, .ram, "RAM above 16 GB has not been verified for this runtime on this architecture."))
        }
        let projected = host.runningDevicesRAM.value + ram.value
        if host.runningDevicesRAM.value > 0 && projected > host.physicalMemory.value * 3 / 4 {
            issues.append(.init(.warning, .host,
                                "Running devices are configured for \(host.runningDevicesRAM); adding \(ram) commits \(Megabytes(projected)) of \(host.physicalMemory).",
                                suggestion: "Configured RAM is a ceiling; check actual usage in Resources before starting more devices."))
        }
    }

    private func validateCPU(_ config: DeviceConfiguration, _ issues: inout [ValidationIssue]) {
        if config.cpuCores < 1 {
            issues.append(.init(.error, .cpu, "At least one CPU core is required."))
        } else if config.cpuCores > host.logicalCPUs {
            issues.append(.init(.error, .cpu, "This Mac has \(host.logicalCPUs) CPU cores."))
        } else if host.performanceCPUs > 0 && config.cpuCores > host.performanceCPUs {
            issues.append(.init(.warning, .cpu,
                                "More cores than this Mac's \(host.performanceCPUs) performance cores may reduce responsiveness."))
        }
    }

    private func validateStorage(_ config: DeviceConfiguration, _ issues: inout [ValidationIssue]) {
        if config.dataPartition < limits.minimumDataPartition {
            issues.append(.init(.error, .storage, "Internal storage must be at least \(limits.minimumDataPartition)."))
        } else if config.dataPartition < Self.observedMinimumDataPartition {
            issues.append(.init(.warning, .storage,
                                "The emulator enlarges internal storage below \(Self.observedMinimumDataPartition) to \(Self.observedMinimumDataPartition).",
                                suggestion: "Observed with emulator 36.6.11 and Android 14 images."))
        }
        // Disk images are sparse: they consume host space as the guest writes data.
        let committed = config.dataPartition.bytes + (config.sdCard?.bytes ?? 0)
        let minimumFree: Int64 = 4 * 1_073_741_824
        if host.availableDiskBytes < minimumFree {
            issues.append(.init(.error, .storage,
                                "Only \(ByteFormat.fileString(host.availableDiskBytes)) free on the AVD volume; at least 4 GB is needed to create a device.",
                                suggestion: "Free disk space or move the AVD location in Settings."))
        } else if committed > host.availableDiskBytes {
            issues.append(.init(.warning, .storage,
                                "If the device fills its storage it will need \(ByteFormat.fileString(committed)), but only \(ByteFormat.fileString(host.availableDiskBytes)) is free."))
        }
        if let sd = config.sdCard, sd.value > 0, sd < Megabytes(10) {
            issues.append(.init(.error, .sdCard, "SD cards must be at least 10 MB."))
        }
    }

    private func validateScreen(_ config: DeviceConfiguration, _ issues: inout [ValidationIssue]) {
        let range = limits.screenDimensionRange
        if !range.contains(config.screenWidth) || !range.contains(config.screenHeight) {
            issues.append(.init(.error, .screen, "Screen dimensions must be between \(range.lowerBound) and \(range.upperBound) pixels."))
        }
        if !limits.densityRange.contains(config.screenDensity) {
            issues.append(.init(.error, .screen, "Density must be between \(limits.densityRange.lowerBound) and \(limits.densityRange.upperBound) dpi."))
        }
    }
}
