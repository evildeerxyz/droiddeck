import Foundation
import IOKit.ps
import DDCore
import DDPlatform

/// Watches a single directory's entries (files added, removed, renamed) with a kqueue vnode
/// source. Unlike recursive FSEvents it does not fire for writes inside running AVDs, so it
/// costs nothing while emulators are busy.
final class DirectoryMonitor: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?

    init?(url: URL, queue: DispatchQueue = .global(qos: .utility), onChange: @escaping @Sendable () -> Void) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link], queue: queue)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    deinit { cancel() }
}

/// Power conditions that decide how often DroidDeck refreshes in the background.
public struct PowerConditions: Sendable, Equatable {
    public var onBattery: Bool
    public var lowPowerMode: Bool

    public static func current() -> PowerConditions {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else {
            return PowerConditions(onBattery: false, lowPowerMode: lowPower)
        }
        return PowerConditions(onBattery: type == kIOPSBatteryPowerValue, lowPowerMode: lowPower)
    }

    public var isConstrained: Bool { onBattery || lowPowerMode }
}

/// Chooses refresh intervals. Changes arrive as events (adb track-devices, discovery-file and
/// AVD-folder monitors); polling is only a slow safety net for edits made by other tools.
public struct RefreshPolicy: Sendable, Equatable {
    public var appActive: Bool
    public var hasTransitions: Bool
    public var power: PowerConditions

    public var fallbackInterval: Duration {
        if hasTransitions { return .seconds(2) }
        if !appActive { return power.isConstrained ? .seconds(120) : .seconds(60) }
        return power.isConstrained ? .seconds(30) : .seconds(15)
    }

    public func metricsInterval(runningDevices: Int) -> Duration {
        if !appActive { return .seconds(60) }
        if runningDevices == 0 { return .seconds(15) }
        // Each sample re-renders the device table's CPU/memory columns; every few seconds is plenty.
        return power.isConstrained ? .seconds(10) : .seconds(5)
    }
}
