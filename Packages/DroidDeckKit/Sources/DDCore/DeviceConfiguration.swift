import Foundation

public enum GPUMode: String, Codable, Sendable, CaseIterable {
    case auto, host, software

    public var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .host: return "Mac GPU"
        case .software: return "Software (CPU, slow)"
        }
    }
}

public enum CameraMode: String, Codable, Sendable, CaseIterable {
    case none
    case emulated
    case webcam0
    /// Back camera only: the emulator's 3D virtual scene.
    case virtualscene

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .emulated: return "Emulated"
        case .webcam0: return "Mac camera"
        case .virtualscene: return "Virtual scene"
        }
    }
}

public enum BootMode: String, Codable, Sendable, CaseIterable {
    /// Restore the Quick Boot snapshot when available, save one on exit.
    case quickBoot
    /// Always perform a full boot.
    case coldBoot

    public var displayName: String {
        switch self {
        case .quickBoot: return "Quick Boot"
        case .coldBoot: return "Cold Boot"
        }
    }
}

public enum Orientation: String, Codable, Sendable, CaseIterable {
    case portrait, landscape
}

public struct SensorSet: Codable, Hashable, Sendable {
    public var accelerometer = true
    public var gyroscope = true
    public var gps = true
    public var proximity = true
    public var light = true
    public var pressure = true
    public var magneticField = true
    public var orientation = true
    public var temperature = true

    public init() {}

    public static let all = SensorSet()
}

/// The complete, runtime-agnostic description of a virtual device's configuration.
/// Every field maps to a documented key in the emulator's hardware-properties.ini
/// or an AVD property written by Android Studio (see AVDConfigMapping in DDAndroidSDK).
public struct DeviceConfiguration: Codable, Hashable, Sendable {
    /// AVD identifier; restricted to [A-Za-z0-9._-].
    public var avdName: String
    public var displayName: String
    public var systemImagePackage: String
    public var profileID: String?
    public var ram: Megabytes
    public var cpuCores: Int
    public var vmHeap: Megabytes?
    public var dataPartition: Megabytes
    public var sdCard: Megabytes?
    public var screenWidth: Int
    public var screenHeight: Int
    public var screenDensity: Int
    public var gpuMode: GPUMode
    public var frontCamera: CameraMode
    public var backCamera: CameraMode
    public var hardwareKeyboard: Bool
    public var sensors: SensorSet
    public var audioInput: Bool
    public var audioOutput: Bool
    public var bootMode: BootMode
    public var initialOrientation: Orientation
    public var skinName: String?
    public var showDeviceFrame: Bool

    public init(avdName: String, displayName: String, systemImagePackage: String, profileID: String?,
                ram: Megabytes, cpuCores: Int, vmHeap: Megabytes? = nil, dataPartition: Megabytes,
                sdCard: Megabytes? = nil, screenWidth: Int, screenHeight: Int, screenDensity: Int,
                gpuMode: GPUMode = .auto, frontCamera: CameraMode = .emulated, backCamera: CameraMode = .emulated,
                hardwareKeyboard: Bool = true, sensors: SensorSet = .all, audioInput: Bool = true,
                audioOutput: Bool = true, bootMode: BootMode = .quickBoot,
                initialOrientation: Orientation = .portrait, skinName: String? = nil, showDeviceFrame: Bool = true) {
        self.avdName = avdName
        self.displayName = displayName
        self.systemImagePackage = systemImagePackage
        self.profileID = profileID
        self.ram = ram
        self.cpuCores = cpuCores
        self.vmHeap = vmHeap
        self.dataPartition = dataPartition
        self.sdCard = sdCard
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.screenDensity = screenDensity
        self.gpuMode = gpuMode
        self.frontCamera = frontCamera
        self.backCamera = backCamera
        self.hardwareKeyboard = hardwareKeyboard
        self.sensors = sensors
        self.audioInput = audioInput
        self.audioOutput = audioOutput
        self.bootMode = bootMode
        self.initialOrientation = initialOrientation
        self.skinName = skinName
        self.showDeviceFrame = showDeviceFrame
    }

    /// Builds a configuration that mirrors an official hardware profile.
    public static func from(profile: DeviceProfile, image: SystemImage, displayName: String, avdName: String,
                            ram: Megabytes, cpuCores: Int, dataPartition: Megabytes) -> DeviceConfiguration {
        DeviceConfiguration(
            avdName: avdName,
            displayName: displayName,
            systemImagePackage: image.packagePath,
            profileID: profile.id,
            ram: ram,
            cpuCores: cpuCores,
            dataPartition: dataPartition,
            sdCard: Megabytes(512),
            screenWidth: profile.screenWidth,
            screenHeight: profile.screenHeight,
            screenDensity: profile.lcdDensity,
            frontCamera: profile.hasFrontCamera ? .emulated : .none,
            backCamera: profile.hasBackCamera ? .emulated : .none,
            hardwareKeyboard: true,
            skinName: profile.skinName,
            showDeviceFrame: profile.skinName != nil
        )
    }
}

/// RAM presets shown in Device Studio.
public enum RAMPreset: Int, CaseIterable, Sendable, Identifiable {
    case gb4 = 4, gb8 = 8, gb12 = 12, gb16 = 16

    public var id: Int { rawValue }
    public var megabytes: Megabytes { .gigabytes(rawValue) }
    public var label: String { "\(rawValue) GB" }
}

/// AVD names become directory names and command-line arguments.
public enum AVDNaming {
    public static let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, !name.hasPrefix("."), !name.hasPrefix("-") else { return false }
        return name.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    /// "Pixel 9 Pro (Work)" → "Pixel_9_Pro_Work", de-duplicated against existing names.
    public static func suggest(from displayName: String, existing: Set<String>) -> String {
        var base = ""
        var lastWasSeparator = false
        for scalar in displayName.unicodeScalars {
            if allowedCharacters.contains(scalar) && scalar != "." {
                base.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator && !base.isEmpty {
                base.append("_")
                lastWasSeparator = true
            }
        }
        while base.hasSuffix("_") { base.removeLast() }
        if base.isEmpty || base.hasPrefix("-") { base = "Device" }
        base = String(base.prefix(56))
        let lowered = Set(existing.map { $0.lowercased() })
        if !lowered.contains(base.lowercased()) { return base }
        var counter = 2
        while lowered.contains("\(base)_\(counter)".lowercased()) { counter += 1 }
        return "\(base)_\(counter)"
    }
}
