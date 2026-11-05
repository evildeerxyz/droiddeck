import SwiftUI
import DroidDeckKit

/// One device's settings: name, tags, battery, and the few facts worth knowing.
struct DeviceSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let deviceID: String
    @State private var name = ""
    @State private var storage: AVDRepository.StorageBreakdown?
    @State private var editingHardware = false

    var body: some View {
        VStack(spacing: 0) {
            if let device = model.devices.device(named: deviceID) {
                Text(device.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top], 20)
                form(device)
                    .sheet(isPresented: $editingHardware) { EditHardwareSheet(device: device).environment(model) }
                    .task(id: "\(device.id)-\(device.state.isRunning)") {
                        storage = await model.devices.storageBreakdown(device.id)
                    }
            } else {
                EmptyStateView(title: "Device Not Found", systemImage: "iphone.slash", message: "It may have been deleted.")
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { saveName(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 640)
        .onAppear { name = model.devices.device(named: deviceID)?.metadata.name ?? "" }
    }

    private func form(_ device: ManagedDevice) -> some View {
        let config = device.device.configuration
        let prefs = model.devices.preferences
        return Form {
            notices(device)
            Section {
                TextField("Name", text: $name, prompt: Text(device.device.displayName))
                    .onSubmit(saveName)
            }
            Section("Tags") {
                TagEditor(deviceIDs: [device.id])
            }
            Section {
                Toggle(isOn: Binding(get: { prefs.sleepDevicesNotOnScreen && !device.metadata.keepAwakeInBackground },
                                     set: { on in model.devices.updateMetadata(device.id) { $0.keepAwakeInBackground = !on } })) {
                    Text("Turn off screen when hidden")
                    Text(prefs.sleepDevicesNotOnScreen
                         ? "Saves battery: 30 seconds after you close or hide this device, its screen turns off and videos stop. Apps stay open and VPNs stay connected."
                         : "Turned off for all devices in Settings.")
                }
                .disabled(!prefs.sleepDevicesNotOnScreen)
                Toggle("Show phone frame", isOn: Binding(get: { device.metadata.showFrame },
                                                         set: { on in model.devices.updateMetadata(device.id) { $0.showFrame = on } }))
            }
            Section("About") {
                LabeledContent("Android") {
                    Text(device.device.image?.title ?? device.device.avd.platform?.marketingName ?? "Unknown")
                }
                LabeledContent("Graphics") {
                    if device.drawsOnCPU {
                        Label("CPU: more battery and heat", systemImage: "flame.fill")
                            .foregroundStyle(.orange)
                            .help("Android 15 and newer can't use the Mac's graphics chip in the Android Emulator. Create an Android 14 device for the lowest battery use.")
                    } else {
                        Text("Mac graphics chip: low battery use")
                    }
                }
                LabeledContent("Memory and CPU") {
                    HStack(spacing: 8) {
                        Text("\(config.ram.description) · \(config.cpuCores) cores").monospacedDigit()
                        Button("Change…") { editingHardware = true }
                            .controlSize(.small)
                            .disabled(device.instance != nil)
                            .help(device.instance != nil ? "Stop the device to change this." : "Memory, CPU cores and screen")
                    }
                }
                LabeledContent("Screen") {
                    Text(verbatim: "\(config.screenWidth) × \(config.screenHeight)").monospacedDigit()
                }
                LabeledContent("On disk") {
                    HStack(spacing: 8) {
                        Text(storage.map { ByteFormat.fileString($0.total) } ?? "Measuring…").monospacedDigit()
                        if let storage, storage.reclaimable > 0 {
                            Button("Free Up \(ByteFormat.fileString(storage.reclaimable))") {
                                model.attempt {
                                    try await model.devices.reclaimSpace(device.id, quickBoot: storage.quickBootSnapshot > 0, sdCard: storage.sdCard > 0)
                                    self.storage = await model.devices.storageBreakdown(device.id)
                                }
                            }
                            .controlSize(.small)
                            .disabled(device.instance != nil)
                            .help(device.instance != nil
                                  ? "Stop the device to free up space."
                                  : "Removes the saved quick-start state and SD card. Apps and accounts stay; the next start takes a little longer.")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func notices(_ device: ManagedDevice) -> some View {
        if device.device.image == nil {
            NoticeView(kind: .error, title: "Android version missing",
                       message: "This device's Android version isn't downloaded, so it can't start. Choose the same Android version in New Device to download it again.")
        }
        if device.device.avd.ramValueIgnoredByEmulator {
            NoticeView(kind: .warning, title: "Memory setting isn't applied",
                       message: "The emulator ignores this device's memory setting and uses its minimum.",
                       action: device.instance == nil ? ("Fix", { model.attempt { try await model.devices.repairRAMFormat(device.id) } }) : nil)
        }
        if device.instance == nil && model.devices.skinIsBroken(device.id) {
            NoticeView(kind: .warning, title: "Phone frame setting is broken",
                       message: "The emulator won't start this device until it's repaired.",
                       action: ("Repair", { model.attempt { try await model.devices.repairSkin(device.id) } }))
        }
    }

    private func saveName() {
        guard let device = model.devices.device(named: deviceID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty || trimmed == device.device.displayName ? nil : trimmed
        if next != device.metadata.name { model.devices.updateMetadata(deviceID) { $0.name = next } }
    }
}
