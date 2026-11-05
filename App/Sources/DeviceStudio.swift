import SwiftUI
import DroidDeckKit

/// New device on one page: name, phone, Android version, tag. Sensible hardware is chosen for you.
struct NewDeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var profileID: String?
    @State private var imageID: String?
    @State private var tagID: String?
    @State private var count = 1
    @State private var creating = false

    var body: some View {
        @Bindable var images = model.images
        VStack(spacing: 0) {
            Text("New Device").font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(profile?.name ?? "Phone"))
                    Picker("Phone", selection: $profileID) {
                        ForEach(phones) { p in
                            Text("\(p.name)  ·  \(p.resolutionDescription)").tag(Optional(p.id))
                        }
                    }
                    Picker("Android", selection: $imageID) {
                        ForEach(androidVersions) { image in
                            Text(label(for: image)).tag(Optional(image.id))
                        }
                    }
                    if !model.devices.allTags.isEmpty {
                        Picker("Tag", selection: $tagID) {
                            Text("None").tag(String?.none)
                            ForEach(model.devices.allTags) { tag in
                                Label { Text(tag.name) } icon: { tag.color.menuDot }.tag(Optional(tag.id))
                            }
                        }
                    }
                    LabeledContent("How many") {
                        HStack(spacing: 6) {
                            Text(verbatim: "\(count)").monospacedDigit()
                            Stepper("How many", value: $count, in: 1...10).labelsHidden()
                        }
                    }
                } footer: {
                    if let image {
                        Text(image.rendersOnMacGPU
                             ? "\(image.platform.marketingName) runs on your Mac's graphics chip: cool and quiet, lowest battery use."
                             : "\(image.platform.marketingName) draws on the CPU, so it uses much more battery and makes your Mac warmer. Android 14 is recommended.")
                            .foregroundStyle(image.rendersOnMacGPU ? Color.secondary : Color.orange)
                    }
                }
                if let image, !image.isInstalled {
                    let progress = model.images.installing[image.packagePath]
                    NoticeView(kind: .info, title: "\(image.platform.marketingName) needs to be downloaded first",
                               message: image.downloadSizeBytes.map { "About \(ByteFormat.fileString($0)). It's kept for every device that uses it." },
                               action: (progress.map { "Downloading \(Int(($0 * 100).rounded()))%" } ?? "Download",
                                        { if progress == nil { model.images.install(image.packagePath) } }))
                }
                if let error = validation?.errors.first {
                    NoticeView(kind: .error, title: error.message, message: error.suggestion)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : count == 1 ? "Create" : "Create \(count)") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(creating || image?.isInstalled != true || !(validation?.isValid ?? false))
            }
            .padding(12)
        }
        .frame(width: 500, height: 470)
        .task { await prepare() }
        .sheet(item: $images.pendingLicense) { prompt in LicenseSheet(prompt: prompt).environment(model) }
    }

    // MARK: Choices

    /// Phones with Google Play, so the Play Store works.
    private var phones: [DeviceProfile] {
        model.profiles.phones.filter { $0.formFactor == .phone && $0.playStoreEnabled }
    }

    private var profile: DeviceProfile? { model.profiles.profile(id: profileID) }

    /// Everyday Google Play versions from Android 11 on: the ones that run on the Mac's graphics chip
    /// first (lowest battery use), newest first within each.
    private var androidVersions: [SystemImage] {
        let installed = model.images.installed
        let installedIDs = Set(installed.map(\.id))
        let all = installed + model.images.catalog.filter { !installedIDs.contains($0.id) }
        let everyday = model.images.compatible(all).filter {
            $0.formFactor == .phone && $0.hasGooglePlay && !$0.isAutomatedTestDevice && !$0.usesSixteenKBPages
                && !$0.platform.isPreview && $0.platform.extensionLevel == nil && $0.platform.apiLevel >= 30
        }
        // One entry per Android version: the installed one if there is one.
        var best: [Int: SystemImage] = [:]
        for image in everyday {
            if let current = best[image.platform.apiLevel], current.isInstalled || !image.isInstalled { continue }
            best[image.platform.apiLevel] = image
        }
        return best.values.sorted { ($0.rendersOnMacGPU ? 1 : 0, $0.platform) > ($1.rendersOnMacGPU ? 1 : 0, $1.platform) }
    }

    private var image: SystemImage? { androidVersions.first { $0.id == imageID } }

    private func label(for image: SystemImage) -> String {
        var text = image.platform.marketingName
        if image.id == androidVersions.first(where: \.rendersOnMacGPU)?.id { text += " (recommended)" }
        else if !image.rendersOnMacGPU { text += " (uses more battery)" }
        if !image.isInstalled { text += " · download" }
        return text
    }

    private func prepare() async {
        if model.profiles.profiles.isEmpty, let sdk = model.devices.sdk { await model.profiles.load(sdk: sdk) }
        if profileID == nil {
            // The Pixel 9a's screen has 30% fewer pixels than a Pixel 9 Pro's: less work for every frame.
            profileID = (phones.first { $0.id == "pixel_9a" } ?? phones.first)?.id
        }
        tagID = tagID ?? model.tagFilter
        // Pick from what's already downloaded right away; the online list (slower) only adds choices.
        chooseDefaultImage()
        if model.images.catalog.isEmpty {
            await model.images.refreshCatalog()
            chooseDefaultImage()
        }
    }

    private func chooseDefaultImage() {
        guard imageID == nil || image == nil else { return }
        imageID = (androidVersions.first { $0.isInstalled && $0.rendersOnMacGPU } ?? androidVersions.first(where: \.isInstalled)
                   ?? androidVersions.first)?.id
    }

    // MARK: Creating

    /// 4 GB is a ceiling (the Mac only spends what Android uses); no cameras or microphone.
    private var configuration: DeviceConfiguration? {
        guard let profile, let image else { return nil }
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? profile.name : name.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = DeviceConfiguration.from(profile: profile, image: image, displayName: displayName,
                                              avdName: AVDNaming.suggest(from: displayName, existing: Set(model.devices.devices.map(\.id))),
                                              ram: RAMPreset.gb4.megabytes, cpuCores: min(4, model.devices.host.logicalCPUs),
                                              dataPartition: .gigabytes(16))
        config.frontCamera = .none
        config.backCamera = .none
        config.audioInput = false
        return config
    }

    private var validation: ValidationResult? {
        guard let configuration else { return nil }
        let host = model.devices.host
        let resources = HostResources(
            architecture: host.architecture, physicalMemory: host.physicalMemory, logicalCPUs: host.logicalCPUs,
            performanceCPUs: host.performanceCPUs, availableDiskBytes: model.resources.disk?.available ?? Int64.max,
            runningDevicesRAM: Megabytes(model.devices.runningDevices.reduce(0) { $0 + $1.device.configuration.ram.value }))
        return ConfigurationValidator(
            host: resources,
            limits: .androidEmulator(host: host.architecture, hostPhysicalMemory: host.physicalMemory),
            existingAVDNames: Set(model.devices.devices.map(\.id)),
            image: image, emulatorVersion: model.devices.sdk?.emulator?.version
        ).validate(configuration)
    }

    private func create() {
        guard let configuration, let image else { return }
        let tag = model.devices.allTags.first { $0.id == tagID }
        let count = self.count
        creating = true
        model.attempt {
            defer { creating = false }
            var existing = Set(model.devices.devices.map(\.id))
            var created: [String] = []
            for index in 0..<count {
                var item = configuration
                if index > 0 {
                    item.displayName = "\(configuration.displayName) \(index + 1)"
                    item.avdName = AVDNaming.suggest(from: item.displayName, existing: existing)
                }
                existing.insert(item.avdName)
                try await model.devices.create(item, profile: profile, image: image, group: nil, startAfterCreation: true)
                created.append(item.avdName)
            }
            if let tag { model.devices.addTag(tag, to: created) }
            model.selectedDeviceID = created.first
            dismiss()
        }
    }
}

/// Memory, CPU cores and screen size of a stopped device.
struct EditHardwareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let device: ManagedDevice
    @State private var config: DeviceConfiguration?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if config != nil {
                    let binding = Binding(get: { config! }, set: { config = $0 })
                    Section {
                        Stepper("Memory: \(binding.wrappedValue.ram.description)",
                                value: Binding(get: { binding.wrappedValue.ram.value }, set: { binding.wrappedValue.ram = Megabytes($0) }),
                                in: 1024...65536, step: 1024)
                        Stepper("CPU cores: \(binding.wrappedValue.cpuCores)", value: binding.cpuCores, in: 1...max(1, model.devices.host.logicalCPUs))
                    } footer: {
                        Text("Memory is a ceiling: your Mac only spends what Android uses. Fewer cores limit how hard one device can work your Mac.")
                    }
                    Section {
                        LabeledContent("Screen") {
                            HStack(spacing: 4) {
                                TextField("Width", value: binding.screenWidth, format: .number.grouping(.never)).frame(width: 64)
                                Text("×")
                                TextField("Height", value: binding.screenHeight, format: .number.grouping(.never)).frame(width: 64)
                            }
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Density (dpi)") {
                            TextField("Density", value: binding.screenDensity, format: .number.grouping(.never))
                                .labelsHidden().frame(width: 64).multilineTextAlignment(.trailing)
                        }
                    } footer: {
                        Text("A smaller screen means less work for every frame, so less battery.")
                    }
                    ForEach(validation?.issues ?? []) { issue in
                        NoticeView(kind: issue.severity == .error ? .error : issue.severity == .warning ? .warning : .info,
                                   title: issue.message, message: issue.suggestion)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let config else { return }
                    model.attempt {
                        try await model.devices.update(device.id, configuration: config, profile: model.profiles.profile(id: config.profileID))
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!(validation?.isValid ?? false))
            }
            .padding(12)
        }
        .frame(width: 440, height: 400)
        .onAppear { config = device.device.configuration }
    }

    private var validation: ValidationResult? {
        guard let config else { return nil }
        let host = model.devices.host
        return ConfigurationValidator(
            host: HostResources(architecture: host.architecture, physicalMemory: host.physicalMemory, logicalCPUs: host.logicalCPUs,
                                performanceCPUs: host.performanceCPUs, availableDiskBytes: model.resources.disk?.available ?? Int64.max),
            limits: .androidEmulator(host: host.architecture, hostPhysicalMemory: host.physicalMemory),
            existingAVDNames: Set(model.devices.devices.map(\.id)), image: device.device.image,
            emulatorVersion: model.devices.sdk?.emulator?.version, editingAVDName: device.id
        ).validate(config)
    }
}
