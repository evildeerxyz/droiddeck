import SwiftUI
import AppKit
import DroidDeckKit

@main
struct DroidDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("DroidDeck", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 620, minHeight: 380)
                .task {
                    appDelegate.model = model
                    await model.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.devices.setAppActive(true)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    model.devices.setAppActive(false)
                }
        }
        .defaultSize(width: 820, height: 560)
        .commands { DroidDeckCommands(model: model) }

        WindowGroup("Device", id: "device", for: String.self) { $deviceID in
            if let deviceID {
                DeviceWindowView(deviceID: deviceID)
                    .environment(model)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 960)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct DroidDeckCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Device…") { model.showingNewDevice = true }
                .keyboardShortcut("n", modifiers: [.command])
        }
        CommandMenu("Device") {
            Button("Start") {
                if let id = model.selectedDeviceID { model.devices.start(id) }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!(model.selectedDeviceID.map { model.devices.capabilities(for: $0).supports(.startDevice) } ?? false))
            Button("Stop") {
                if let id = model.selectedDeviceID { model.devices.stop(id) }
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!(model.selectedDeviceID.map { model.devices.capabilities(for: $0).supports(.stopDevice) } ?? false))
            Button("Open Display") {
                if let id = model.selectedDeviceID { openWindow(id: "device", value: id) }
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(!(model.selectedDeviceID.map { model.devices.capabilities(for: $0).supports(.embeddedDisplay) } ?? false))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    /// UI-test hook: `--render-frame-preview <skinDir> <screen.png> <out.png> <rotation 0-3>` renders the
    /// skinned frame offscreen and exits. Only honored with DROIDDECK_SUPPORT_DIR set.
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        guard ProcessInfo.processInfo.environment["DROIDDECK_SUPPORT_DIR"] != nil,
              let i = args.firstIndex(of: "--render-frame-preview"), i + 4 < args.count else { return }
        let skinDir = URL(fileURLWithPath: args[i + 1])
        guard let layout = SkinLayout.load(directory: skinDir), let backURL = layout.backgroundImage,
              let back = NSImage(contentsOf: backURL), let shot = NSImage(contentsOfFile: args[i + 2]),
              let rotation = EmulatorSkinRotation(rawValue: Int32(args[i + 4]) ?? 0) else { exit(2) }
        let mask = layout.maskImage.flatMap { NSImage(contentsOf: $0) }
        let size = rotation.quarterTurns % 2 == 0 ? CGSize(width: 500, height: 1000) : CGSize(width: 1000, height: 500)
        let view = SkinnedFrame(skin: layout, back: back, mask: mask, rotation: rotation, available: size) {
            Image(nsImage: shot).resizable()
        }
        .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(3) }
        try? png.write(to: URL(fileURLWithPath: args[i + 3]))
        exit(0)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.devices.runningDevices.filter({ $0.instance?.launchedByDroidDeck == true }).isEmpty else {
            return .terminateNow
        }
        switch model.devices.preferences.quitBehavior {
        case .leaveRunning:
            return .terminateNow
        case .stopDevices:
            stopAndTerminate(model)
            return .terminateLater
        case .ask:
            let alert = NSAlert()
            alert.messageText = "Stop running devices?"
            alert.informativeText = "Devices started by DroidDeck keep running after you quit unless you stop them. You can reconnect to them the next time you open DroidDeck."
            alert.addButton(withTitle: "Stop Devices and Quit")
            alert.addButton(withTitle: "Leave Running")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                stopAndTerminate(model)
                return .terminateLater
            case .alertSecondButtonReturn:
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
    }

    @MainActor
    private func stopAndTerminate(_ model: AppModel) {
        Task {
            await model.devices.stopEverything()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
}
