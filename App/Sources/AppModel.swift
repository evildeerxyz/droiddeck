import SwiftUI
import AppKit
import Observation
import DroidDeckKit

/// Root state: owns the application services and the main window's state.
@MainActor
@Observable
final class AppModel {
    let devices: DeviceManager
    let resources = ResourceMonitor()
    let profiles = ProfileLibrary()
    let images: ImageLibrary

    var selectedDeviceID: String?
    /// Shows only devices with this tag (by tag id); nil shows every device.
    var tagFilter: String?
    var showingNewDevice = false
    /// The device whose settings sheet is open.
    var settingsDeviceID: String?
    var presentedError: DroidDeckError?
    var started = false

    /// Device whose display window should open (set by UI-test launch arguments).
    var pendingDisplayWindow: String?

    init() {
        let devices = DeviceManager()
        self.devices = devices
        images = ImageLibrary(devices: devices)
    }

    func start() async {
        guard !started else { return }
        started = true
        await devices.bootstrap()
        devices.startMonitoring()
        resources.start(devices: devices)
        images.reloadInstalled()
        if let sdk = devices.sdk { await profiles.load(sdk: sdk) }
        if selectedDeviceID == nil { selectedDeviceID = devices.devices.first?.id }
        if await runSnapshotHook() { return }
        await runLingerHook()
        await runUITestHooks()
    }

    /// `--ui-snapshot <dir>`: renders the main window and its sheets to PNG files and quits.
    private func runSnapshotHook() async -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard ProcessInfo.processInfo.environment["DROIDDECK_SUPPORT_DIR"] != nil,
              let index = args.firstIndex(of: "--ui-snapshot"), index + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await devices.updatePreferences { $0.onboardingCompleted = true }
        func snap(_ name: String, sheet: Bool = false) async {
            try? await Task.sleep(for: .seconds(2.5))
            guard let main = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true || $0.title == "DroidDeck" })
                    ?? NSApp.windows.first(where: { $0.isVisible && $0.attachedSheet != nil }) ?? NSApp.windows.first(where: \.isVisible) else { return }
            let window = sheet ? (main.attachedSheet ?? main) : main
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
        }
        selectedDeviceID = devices.devices.first?.id
        await snap("devices")
        showingNewDevice = true
        await snap("new-device", sheet: true)
        showingNewDevice = false
        try? await Task.sleep(for: .seconds(1))
        settingsDeviceID = devices.devices.first?.id
        await snap("device-settings", sheet: true)
        settingsDeviceID = nil
        try? await Task.sleep(for: .seconds(1))
        if let tag = devices.allTags.first {
            tagFilter = tag.id
            await snap("devices-filtered")
        }
        NSApp.terminate(nil)
        return true
    }

    /// `--ui-linger <seconds>`: stays on the device list (no quit), so a human or script can confirm
    /// the UI is stable over time. Only honored with DROIDDECK_SUPPORT_DIR set.
    private func runLingerHook() async {
        let args = ProcessInfo.processInfo.arguments
        guard ProcessInfo.processInfo.environment["DROIDDECK_SUPPORT_DIR"] != nil,
              args.contains("--ui-linger") else { return }
        await devices.updatePreferences { $0.onboardingCompleted = true }
        selectedDeviceID = devices.devices.first?.id
    }

    /// `--ui-test-open <avd>`: starts a device and opens its window, for automated UI smoke tests.
    /// Only honored together with DROIDDECK_SUPPORT_DIR so it can never act on a normal install.
    private func runUITestHooks() async {
        let args = ProcessInfo.processInfo.arguments
        guard ProcessInfo.processInfo.environment["DROIDDECK_SUPPORT_DIR"] != nil,
              let index = args.firstIndex(of: "--ui-test-open"), index + 1 < args.count else { return }
        let name = args[index + 1]
        await devices.updatePreferences { $0.onboardingCompleted = true }
        selectedDeviceID = name
        if devices.device(named: name)?.instance == nil { devices.start(name) }
        while devices.device(named: name)?.state.isRunning != true {
            try? await Task.sleep(for: .seconds(1))
            if case .failed = devices.device(named: name)?.state { return }
        }
        pendingDisplayWindow = name
    }

    var needsOnboarding: Bool {
        !devices.preferences.onboardingCompleted || devices.adapter == nil
    }

    /// Devices shown in the main window: all of them, or those with the chosen tag.
    var visibleDevices: [ManagedDevice] {
        guard let tagFilter else { return devices.devices }
        return devices.devices(taggedWith: tagFilter)
    }

    func present(_ error: Error) {
        if let error = error as? DroidDeckError {
            if error.kind != .cancelled { presentedError = error }
        } else {
            presentedError = DroidDeckError(.toolFailed, error.localizedDescription)
        }
    }

    /// Runs an async action and surfaces failures in an alert.
    func attempt(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch { present(error) }
        }
    }
}
