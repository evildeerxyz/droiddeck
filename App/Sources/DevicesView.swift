import SwiftUI
import DroidDeckKit

/// Every device in one list: start, open and stop right on the row; the rest is in its ⋯ menu.
struct DeviceListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var newTagFor: NewTagRequest?
    @State private var deleting: ManagedDevice?
    @State private var wiping: ManagedDevice?

    var body: some View {
        @Bindable var model = model
        let rows = model.visibleDevices
        VStack(spacing: 0) {
            if model.resources.memory.pressure == .critical {
                NoticeView(kind: .warning, title: "Your Mac is low on memory",
                           message: "Stop a device you aren't using to keep everything smooth.")
                    .padding([.horizontal, .top], 12)
            }
            if model.devices.devices.isEmpty {
                if model.devices.adapter != nil {
                    EmptyStateView(title: "No Devices Yet", systemImage: "iphone",
                                   message: "Create an Android phone to get started.",
                                   action: ("New Device", { model.showingNewDevice = true }))
                } else {
                    Spacer()
                }
            } else if rows.isEmpty {
                EmptyStateView(title: "No Devices with This Tag", systemImage: "tag",
                               message: "Add the tag to a device from its ⋯ menu.",
                               action: ("Show All Devices", { model.tagFilter = nil }))
            } else {
                List(selection: $model.selectedDeviceID) {
                    ForEach(rows) { device in
                        DeviceRow(device: device, actions: actions)
                            .tag(device.id)
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let device = model.devices.device(named: id) {
                        DeviceMenuItems(device: device, actions: actions)
                    }
                } primaryAction: { ids in
                    guard let id = ids.first, let device = model.devices.device(named: id) else { return }
                    if device.state.isRunning { actions.open(device) } else if device.instance == nil { model.devices.start(id) }
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.devices.allTags.isEmpty { TagFilterMenu() }
                Button {
                    model.showingNewDevice = true
                } label: {
                    Label("New Device", systemImage: "plus")
                }
                .disabled(!(model.devices.detection?.canCreateDevices ?? false))
                .help("New Device")
            }
        }
        .sheet(item: $newTagFor) { request in NewTagSheet(deviceIDs: request.deviceIDs) }
        .confirmationDialog("Delete \(deleting?.displayName ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Device", role: .destructive) {
                if let device = deleting { model.attempt { try await model.devices.delete(device.id) } }
            }
        } message: {
            Text("The device and all of its apps, accounts and files are removed for good.")
        }
        .confirmationDialog("Wipe \(wiping?.displayName ?? "")?", isPresented: Binding(get: { wiping != nil }, set: { if !$0 { wiping = nil } })) {
            Button("Wipe and Start", role: .destructive) {
                if let device = wiping {
                    var options = LaunchOptions()
                    options.displayMode = device.metadata.displayMode
                    options.wipeData = true
                    options.coldBoot = true
                    model.devices.start(device.id, options: options)
                }
            }
        } message: {
            Text("All apps, accounts and files on this device are erased and it starts like new.")
        }
    }

    private var actions: DeviceActions {
        DeviceActions(
            open: { device in
                if device.instance?.displayMode == .externalWindow, let pid = device.instance?.pid {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                } else {
                    openWindow(id: "device", value: device.id)
                }
            },
            newTag: { newTagFor = NewTagRequest(deviceIDs: [$0.id]) },
            wipe: { wiping = $0 },
            delete: { deleting = $0 })
    }

    private var title: String {
        if let tag = model.tagFilter { return model.devices.allTags.first { $0.id == tag }?.name ?? "DroidDeck" }
        return "DroidDeck"
    }

    private var subtitle: String {
        let rows = model.visibleDevices
        let running = rows.filter { $0.state.isRunning }.count
        let count = rows.count == 1 ? "1 device" : "\(rows.count) devices"
        return running > 0 ? "\(count) · \(running) running" : count
    }
}

/// What rows and menus ask the list to do.
struct DeviceActions {
    let open: (ManagedDevice) -> Void
    let newTag: (ManagedDevice) -> Void
    let wipe: (ManagedDevice) -> Void
    let delete: (ManagedDevice) -> Void
}

struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: ManagedDevice
    let actions: DeviceActions

    var body: some View {
        HStack(spacing: 12) {
            DeviceGlyph(device: device)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName).font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    ForEach(device.metadata.tags) { TagChip(tag: $0).fixedSize() }
                    AndroidVersionLabel(device: device)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            DeviceStatus(device: device)
            buttons
            Menu {
                DeviceMenuItems(device: device, actions: actions)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var buttons: some View {
        if device.instance == nil {
            Button("Start") { model.devices.start(device.id) }
                .disabled(!device.capabilities.supports(.startDevice) || device.state.isBusy)
                .help(device.capabilities.reason(.startDevice) ?? "Start \(device.displayName)")
                .frame(minWidth: 64)
        } else {
            Button("Open") { actions.open(device) }
                .buttonStyle(.borderedProminent)
                .disabled(!device.state.isRunning)
                .frame(minWidth: 64)
            Button {
                model.devices.stop(device.id)
            } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(!device.capabilities.supports(.stopDevice) || device.state == .stopping)
            .help("Stop")
            .accessibilityLabel("Stop \(device.displayName)")
        }
    }
}

/// A phone in the device's first tag color, with a dot while it runs.
struct DeviceGlyph: View {
    let device: ManagedDevice

    var body: some View {
        let tint = device.metadata.tags.first?.color.color ?? .secondary
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(tint.opacity(0.14))
            .frame(width: 36, height: 36)
            .overlay {
                Image(systemName: "iphone").font(.system(size: 17, weight: .medium)).foregroundStyle(tint)
            }
            .overlay(alignment: .bottomTrailing) {
                if device.state.isRunning {
                    Circle()
                        .fill(device.isPaused ? Color.orange : .green)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
    }
}

/// "Android 14", with a flame when that Android version draws on the CPU (more battery and heat).
struct AndroidVersionLabel: View {
    let device: ManagedDevice

    var body: some View {
        let platform = device.device.image?.platform ?? device.device.avd.platform
        if let platform {
            HStack(spacing: 3) {
                Text(platform.marketingName)
                if device.drawsOnCPU {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(device.drawsOnCPU
                  ? "\(platform.marketingName) draws on the CPU, so it uses more battery and makes your Mac warmer. Android 14 devices use the Mac's graphics chip."
                  : "Runs on the Mac's graphics chip: low battery use.")
        } else {
            Text("Android version missing").font(.caption).foregroundStyle(.red)
        }
    }
}

extension ManagedDevice {
    /// Whether this device draws on the CPU instead of the Mac's graphics chip.
    var drawsOnCPU: Bool {
        let api = device.image?.platform.apiLevel ?? device.avd.platform?.apiLevel ?? 0
        switch device.configuration.gpuMode {
        case .software: return true
        case .host: return false
        default: return api >= SystemImage.firstAPILevelNeedingES31
        }
    }
}

struct DeviceStatus: View {
    @Environment(AppModel.self) private var model
    let device: ManagedDevice

    var body: some View {
        HStack(spacing: 5) {
            switch device.state {
            case .running:
                if device.isPaused {
                    Text("Paused")
                } else if model.devices.asleepOffScreen.contains(device.id) {
                    Image(systemName: "moon.fill").foregroundStyle(.indigo).font(.caption)
                    Text("Screen off")
                } else {
                    Text("Running")
                }
                if let cpu = model.resources.usage[device.id]?.cpuPercent {
                    Text("\(Int(cpu.rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(cpu > 150 ? .orange : .secondary)
                        .help("CPU use (100% is one core)")
                }
            case .starting, .stopping:
                ProgressView().controlSize(.small)
                Text(device.state.label)
            case .failed(let message):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text("Couldn't start").help(message)
            case .stopped:
                EmptyView()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}

/// The ⋯ menu and right-click menu of a device.
struct DeviceMenuItems: View {
    @Environment(AppModel.self) private var model
    let device: ManagedDevice
    let actions: DeviceActions

    var body: some View {
        if device.instance == nil {
            Button("Start") { model.devices.start(device.id) }
                .disabled(!device.capabilities.supports(.startDevice) || device.state.isBusy)
        } else {
            Button("Open") { actions.open(device) }.disabled(!device.state.isRunning)
            Button("Stop") { model.devices.stop(device.id) }.disabled(device.state == .stopping)
        }
        if device.state.isRunning {
            Button(device.isPaused ? "Resume" : "Pause") {
                device.isPaused ? model.devices.resume(device.id) : model.devices.pause(device.id)
            }
            .help("Pausing freezes Android so it uses no CPU")
        }
        if case .failed(let message) = device.state {
            Button("Why Didn't It Start?") { model.presentedError = DroidDeckError(.toolFailed, "\(device.displayName) couldn't start", recovery: message) }
        }
        Divider()
        TagToggleMenu(deviceIDs: [device.id]) { actions.newTag(device) }
        Button("Rename…") { rename(device, model: model) }
        Button("Settings…") { model.settingsDeviceID = device.id }
        Divider()
        Button("Wipe Data…") { actions.wipe(device) }
            .disabled(!device.capabilities.supports(.wipeData))
        Button("Delete…", role: .destructive) { actions.delete(device) }
            .disabled(!device.capabilities.supports(.deleteDevice))
    }
}

/// Toolbar menu: show every device or only one tag's, and edit tags.
struct TagFilterMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let tags = model.devices.allTags
        Menu {
            Picker("Show", selection: $model.tagFilter) {
                Text("All Devices").tag(String?.none)
                ForEach(tags) { tag in
                    Label { Text(tag.name) } icon: { tag.color.menuDot }.tag(Optional(tag.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Menu("Edit Tags") {
                ForEach(tags) { tag in
                    Menu {
                        TagManagementMenu(tag: tag)
                    } label: {
                        Label { Text(tag.name) } icon: { tag.color.menuDot }
                    }
                }
            }
        } label: {
            Label("Show", systemImage: model.tagFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Show devices with a tag")
    }
}

struct NewTagRequest: Identifiable {
    let id = UUID()
    let deviceIDs: [String]
}

/// Names the device in DroidDeck (it can be renamed while it runs).
@MainActor
func rename(_ device: ManagedDevice, model: AppModel) {
    let alert = NSAlert()
    alert.messageText = "Rename Device"
    alert.informativeText = "A name you'll recognise, like the account it's for."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = device.displayName
    field.placeholderString = device.device.displayName
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    model.devices.updateMetadata(device.id) { $0.name = name.isEmpty || name == device.device.displayName ? nil : name }
}
