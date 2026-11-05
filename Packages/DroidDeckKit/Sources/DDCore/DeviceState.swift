import Foundation

/// Lifecycle state of a virtual device as observed by DroidDeck.
public enum DeviceLifecycleState: Equatable, Sendable {
    case stopped
    /// Emulator process launched; waiting for ADB / boot completion.
    case starting(phase: StartPhase)
    case running(RunningDetails)
    case stopping
    /// The last operation failed; the device is not running.
    case failed(message: String)

    public enum StartPhase: String, Sendable {
        case launching = "Starting"
        case waitingForADB = "Connecting"
        case booting = "Booting Android"
        /// The saved Quick Boot state was unusable; booting Android from scratch (data is kept).
        case recovering = "Starting fresh"
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .starting, .stopping: return true
        default: return false
        }
    }

    public var isActive: Bool { isRunning || isBusy }

    public var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting(let phase): return phase.rawValue
        case .running(let details): return details.launchedByDroidDeck ? "Running" : "Running (external)"
        case .stopping: return "Stopping"
        case .failed: return "Failed"
        }
    }
}

public struct RunningDetails: Equatable, Sendable {
    public var pid: Int32
    public var adbSerial: String
    public var consolePort: Int
    public var grpcPort: Int?
    public var launchedByDroidDeck: Bool
    public var displayMode: DisplayMode
    public var startedAt: Date?

    public init(pid: Int32, adbSerial: String, consolePort: Int, grpcPort: Int?, launchedByDroidDeck: Bool,
                displayMode: DisplayMode, startedAt: Date?) {
        self.pid = pid
        self.adbSerial = adbSerial
        self.consolePort = consolePort
        self.grpcPort = grpcPort
        self.launchedByDroidDeck = launchedByDroidDeck
        self.displayMode = displayMode
        self.startedAt = startedAt
    }
}

/// How the device's screen is presented.
public enum DisplayMode: String, Codable, Sendable, CaseIterable {
    /// Rendered inside DroidDeck through the emulator's gRPC screen stream.
    case embedded
    /// The emulator's own window.
    case externalWindow
    /// No display (automation, CI).
    case headless

    public var displayName: String {
        switch self {
        case .embedded: return "In DroidDeck"
        case .externalWindow: return "Emulator window"
        case .headless: return "Headless"
        }
    }
}
