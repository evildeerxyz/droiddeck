import SwiftUI
import DroidDeckKit

/// DroidDeck › Settings (⌘,): the few app-wide choices, downloaded Android versions, and help when
/// something doesn't work.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AndroidVersionsSettings().tabItem { Label("Android Versions", systemImage: "square.stack.3d.down.right") }
            TroubleshootingSettings().tabItem { Label("Troubleshooting", systemImage: "stethoscope") }
        }
        .frame(width: 560, height: 440)
    }
}

/// Reads and writes one preference.
@MainActor
func preferenceBinding<T: Equatable>(_ model: AppModel, _ keyPath: WritableKeyPath<AppPreferences, T>) -> Binding<T> {
    Binding(get: { model.devices.preferences[keyPath: keyPath] },
            set: { value in Task { await model.devices.updatePreferences { $0[keyPath: keyPath] = value } } })
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle(isOn: preferenceBinding(model, \.sleepDevicesNotOnScreen)) {
                    Text("Turn off the screen of devices you're not looking at")
                    Text("Saves battery and keeps your Mac cool: 30 seconds after a device's window is closed or hidden, its screen turns off and videos stop. Apps stay open, VPNs stay connected, and it wakes when you open it.")
                }
            }
            Section {
                Picker("When you quit DroidDeck", selection: preferenceBinding(model, \.quitBehavior)) {
                    ForEach(QuitBehavior.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Screenshots") {
                    HStack(spacing: 8) {
                        Text(model.devices.preferences.screenshotDirectory.lastPathComponent).foregroundStyle(.secondary)
                        Button("Change…") {
                            if let url = chooseFolder() { Task { await model.devices.updatePreferences { $0.screenshotFolder = url.path } } }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AndroidVersionsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var removing: SystemImage?

    var body: some View {
        let downloaded = model.images.installed.filter { $0.packagePath.hasPrefix("system-images") }
            .sorted { $0.platform > $1.platform }
        let updates = model.images.updates.filter { !$0.path.hasPrefix("system-images") }
        Form {
            Section {
                if downloaded.isEmpty {
                    Text("None yet. Android downloads when you create a device.").foregroundStyle(.secondary)
                }
                ForEach(downloaded) { image in
                    let users = model.devices.devices.filter { $0.device.image?.id == image.id }
                    LabeledContent {
                        Button("Remove") { removing = image }
                            .controlSize(.small)
                            .disabled(!users.isEmpty)
                            .help(users.isEmpty ? "Frees up disk space" : "Used by \(users.map(\.displayName).joined(separator: ", "))")
                    } label: {
                        Text(image.title)
                        Text([users.isEmpty ? "Not used by any device" : users.count == 1 ? "Used by 1 device" : "Used by \(users.count) devices",
                              image.rendersOnMacGPU ? "Mac graphics chip" : "CPU graphics (more battery)"].joined(separator: " · "))
                    }
                }
            } header: {
                Text("Downloaded")
            } footer: {
                Text("Android 14 runs on your Mac's graphics chip. Android 15 and newer draw on the CPU, which uses much more battery.")
            }
            Section("Updates") {
                if updates.isEmpty {
                    Text(model.images.isLoadingCatalog ? "Checking…" : "Everything is up to date.").foregroundStyle(.secondary)
                }
                ForEach(updates, id: \.path) { update in
                    LabeledContent {
                        if let progress = model.images.installing[update.path] {
                            ProgressView(value: progress).frame(width: 80)
                        } else {
                            Button("Update") { model.images.install(update.path) }
                                .controlSize(.small)
                                .disabled(update.path == "emulator" && !model.devices.runningDevices.isEmpty)
                                .help(update.path == "emulator" && !model.devices.runningDevices.isEmpty ? "Stop running devices first." : "")
                        }
                    } label: {
                        Text(update.path == "emulator" ? "Android Emulator" : update.path == "platform-tools" ? "Platform tools" : update.path)
                        Text("\(update.version) → \(update.extra ?? "")")
                    }
                }
                Button("Check Now") { Task { await model.images.refreshCatalog() } }
                    .disabled(model.images.isLoadingCatalog)
            }
        }
        .formStyle(.grouped)
        .task {
            model.images.reloadInstalled()
            if model.images.catalog.isEmpty { await model.images.refreshCatalog() }
        }
        .confirmationDialog("Remove \(removing?.title ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let image = removing { model.attempt { try await model.images.uninstall(image) } }
            }
        } message: {
            Text("It downloads again if you create a device with it.")
        }
    }
}

struct TroubleshootingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var exporting = false
    @State private var items: [DiagnosticsExporter.Item] = []
    @State private var preparing = false

    var body: some View {
        Form {
            Section("Checks") {
                ForEach(model.devices.detection?.checks ?? []) { check in
                    HStack(alignment: .top) {
                        Image(systemName: check.status == .ok ? "checkmark.circle.fill" : check.status == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(check.status == .ok ? .green : check.status == .warning ? .orange : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title).fontWeight(.medium)
                            Text(check.detail).font(.callout).foregroundStyle(.secondary)
                            if let recovery = check.recovery { Text(recovery).font(.callout) }
                        }
                    }
                }
                Button("Check Again") { Task { await model.devices.redetect() } }
            }
            Section("Android SDK") {
                LabeledContent("Location") { Text(model.devices.sdk?.root.path ?? "Not found").textSelection(.enabled) }
                HStack {
                    Button("Choose…") {
                        if let url = chooseFolder() { Task { await model.devices.updatePreferences { $0.sdkPathOverride = url.path } } }
                    }
                    Button("Use Default") { Task { await model.devices.updatePreferences { $0.sdkPathOverride = nil; $0.avdHomeOverride = nil } } }
                }
            }
            Section {
                Button(preparing ? "Collecting…" : "Export Diagnostics…") {
                    preparing = true
                    Task {
                        items = await DiagnosticsExporter.collect(devices: model.devices, resources: model.resources)
                        preparing = false
                        exporting = true
                    }
                }
                .disabled(preparing)
                Button("Open Logs Folder") { NSWorkspace.shared.open(AppLog.shared.logDirectory) }
            } footer: {
                Text("Exports leave out passwords, tokens, email addresses and your home folder path. You can read every file before saving.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $exporting) { DiagnosticsPreview(items: items) }
    }
}

@MainActor
func chooseFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url : nil
}

struct DiagnosticsPreview: View {
    @Environment(\.dismiss) private var dismiss
    let items: [DiagnosticsExporter.Item]
    @State private var selected: String?

    var body: some View {
        HSplitView {
            List(items, selection: $selected) { item in
                VStack(alignment: .leading) {
                    Text(item.name)
                    Text(ByteFormat.fileString(Int64(item.contents.utf8.count))).font(.caption).foregroundStyle(.secondary)
                }
                .tag(item.name)
            }
            .frame(minWidth: 200)
            ScrollView {
                Text(items.first { $0.name == selected }?.contents.prefix(60_000) ?? "Select a file to review it.")
                    .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        }
        .frame(width: 820, height: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "DroidDeck Diagnostics \(Date().formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-")).zip"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    Task {
                        try? await DiagnosticsExporter.write(items, to: url)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        dismiss()
                    }
                }
            }
        }
        .onAppear { selected = items.first?.name }
    }
}
