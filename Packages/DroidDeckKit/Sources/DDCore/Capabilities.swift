import Foundation

/// Operations a runtime may or may not support. The UI must consult a
/// `CapabilityReport` and disable anything not listed as supported.
public enum RuntimeCapability: String, CaseIterable, Codable, Sendable {
    // Lifecycle
    case createDevice, deleteDevice, cloneDevice, startDevice, stopDevice, forceStop, coldBoot, wipeData
    // Display & input
    case embeddedDisplay, externalWindow, touchInput, multiTouchInput, keyboardInput, hardwareButtons
    case rotation, screenshot, clipboard
    // Developer tools (adb)
    case apkInstall, fileTransfer, logcat, shell, appLaunch, mediaSync
    // Simulation
    case gpsSimulation, sensorSimulation, batterySimulation, networkShaping
    // State
    case snapshots, backupExport
    // Gaming
    case keyMapping

    public var displayName: String {
        switch self {
        case .createDevice: return "Create devices"
        case .deleteDevice: return "Delete devices"
        case .cloneDevice: return "Clone devices"
        case .startDevice: return "Start"
        case .stopDevice: return "Stop"
        case .forceStop: return "Force stop"
        case .coldBoot: return "Cold boot"
        case .wipeData: return "Wipe data"
        case .embeddedDisplay: return "Display inside DroidDeck"
        case .externalWindow: return "Emulator window"
        case .touchInput: return "Touch input"
        case .multiTouchInput: return "Multi-touch"
        case .keyboardInput: return "Keyboard input"
        case .hardwareButtons: return "Hardware buttons"
        case .rotation: return "Rotation"
        case .screenshot: return "Screenshots"
        case .clipboard: return "Clipboard sync"
        case .apkInstall: return "APK installation"
        case .fileTransfer: return "File transfer"
        case .logcat: return "Logcat"
        case .shell: return "Shell"
        case .appLaunch: return "Launch & stop apps"
        case .mediaSync: return "Shared folder sync"
        case .gpsSimulation: return "Location simulation"
        case .sensorSimulation: return "Sensor simulation"
        case .batterySimulation: return "Battery simulation"
        case .networkShaping: return "Network speed & latency"
        case .snapshots: return "Snapshots"
        case .backupExport: return "Backup & restore"
        case .keyMapping: return "Keyboard-to-touch mapping"
        }
    }
}

/// What a runtime can do for a specific device in its current state, with
/// a reason for every unavailable capability.
public struct CapabilityReport: Sendable, Equatable {
    public private(set) var supported: Set<RuntimeCapability>
    public private(set) var reasons: [RuntimeCapability: String]

    public init(supported: Set<RuntimeCapability> = [], reasons: [RuntimeCapability: String] = [:]) {
        self.supported = supported
        self.reasons = reasons
    }

    public func supports(_ capability: RuntimeCapability) -> Bool { supported.contains(capability) }

    /// Explanation shown in tooltips for disabled controls.
    public func reason(_ capability: RuntimeCapability) -> String? {
        supports(capability) ? nil : (reasons[capability] ?? "Not supported by this runtime.")
    }

    public mutating func enable(_ capabilities: RuntimeCapability...) {
        for capability in capabilities {
            supported.insert(capability)
            reasons[capability] = nil
        }
    }

    public mutating func disable(_ capability: RuntimeCapability, because reason: String) {
        supported.remove(capability)
        reasons[capability] = reason
    }
}
