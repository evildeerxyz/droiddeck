import Foundation
import DDCore
import DDADB

/// Capabilities for devices reached only through adb: physical phones and
/// emulators DroidDeck does not manage (e.g. third-party players). Lifecycle,
/// snapshots and hardware simulation are unavailable because there is no runtime to drive.
public enum ADBDeviceCapabilities {
    public static func report(for device: ADBDevice) -> CapabilityReport {
        var report = CapabilityReport()
        guard device.state == .device else {
            let reason: String
            switch device.state {
            case .unauthorized: reason = "Accept the USB debugging prompt on the device."
            case .offline: reason = "The device is offline. Reconnect it or restart adb."
            default: reason = "The device is not ready (\(device.state.rawValue))."
            }
            for capability in RuntimeCapability.allCases { report.disable(capability, because: reason) }
            return report
        }
        report.enable(.apkInstall, .fileTransfer, .logcat, .shell, .appLaunch, .screenshot, .hardwareButtons, .mediaSync)
        let notManaged = device.isEmulatorSerial
            ? "This emulator is not managed by DroidDeck (it was not started from an Android Virtual Device DroidDeck can see)."
            : "Not available for physical devices."
        for capability in RuntimeCapability.allCases where !report.supports(capability) {
            report.disable(capability, because: notManaged)
        }
        return report
    }
}
