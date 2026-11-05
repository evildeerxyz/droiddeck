import SwiftUI
import DroidDeckKit

/// Inspects APKs with aapt2, shows compatibility problems, then installs with chosen options.
struct InstallAPKSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let serial: String
    let files: [URL]
    let onFinish: () -> Void

    @State private var infos: [URL: APKInfo] = [:]
    @State private var problems: [String] = []
    @State private var options = InstallOptions()
    @State private var inspecting = true
    @State private var unsupported: [URL] = []

    var body: some View {
        Form {
            Section(files.count == 1 ? "APK" : "\(files.count) APKs (installed together as one app)") {
                ForEach(files, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent).fontWeight(.medium)
                        if let info = infos[url] {
                            Text([info.label, info.packageName, info.versionName.map { "v\($0)" },
                                  info.minSDK.map { "min API \($0)" },
                                  info.nativeABIs.isEmpty ? nil : info.nativeABIs.joined(separator: ", ")].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        } else if inspecting {
                            Text("Inspecting…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !unsupported.isEmpty {
                NoticeView(kind: .error, title: "Unsupported package format",
                           message: ".apks bundles need bundletool. Export universal or split .apk files and select them together.")
            }
            ForEach(problems, id: \.self) { problem in
                NoticeView(kind: .warning, title: "Likely to fail", message: problem)
            }
            Section("Options") {
                Toggle("Replace existing app", isOn: $options.replaceExisting)
                Toggle("Allow downgrade", isOn: $options.allowDowngrade)
                Toggle("Grant all runtime permissions", isOn: $options.grantAllPermissions)
                Toggle("Allow test packages", isOn: $options.allowTestPackages)
                Toggle("Bypass low target SDK block (Android 14+)", isOn: $options.bypassLowTargetSDKBlock)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss(); onFinish() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Install") { install() }.disabled(inspecting || !unsupported.isEmpty)
            }
        }
        .task { await inspect() }
    }

    private func inspect() async {
        guard let sdk = model.devices.sdk, let adb = model.devices.adb else { inspecting = false; return }
        unsupported = files.filter { $0.pathExtension.lowercased() == "apks" }
        let api = Int((try? await adb.getprop(serial, "ro.build.version.sdk")) ?? "")
        let abis = ((try? await adb.getprop(serial, "ro.product.cpu.abilist")) ?? "").split(separator: ",").map(String.init)
        if let aapt2 = sdk.aapt2 {
            for url in files where url.pathExtension.lowercased() == "apk" {
                if let info = try? await APKInfo.inspect(apk: url, aapt2: aapt2, runner: sdk.runner) {
                    infos[url] = info
                    if !info.isSplit { problems += info.compatibilityProblems(deviceAPI: api, deviceABIs: abis) }
                }
            }
        }
        inspecting = false
    }

    private func install() {
        guard let adb = model.devices.adb else { return }
        let files = self.files
        let options = self.options
        let serial = self.serial
        let title = files.count == 1 ? "Install \(files[0].lastPathComponent)" : "Install \(files.count) APKs"
        model.devices.tasks.run(title) { _ in
            var apks = files.filter { $0.pathExtension.lowercased() == "apk" }
            // .xapk: a zip containing the APK set (and optional OBB data, which is not installed).
            for xapk in files where xapk.pathExtension.lowercased() == "xapk" {
                let dir = FileManager.default.temporaryDirectory.appending(path: "xapk-\(UUID().uuidString)")
                let result = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", xapk.path, dir.path])
                guard result.succeeded else { throw DroidDeckError(.installFailed, "\(xapk.lastPathComponent) could not be extracted.") }
                let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                apks += contents.filter { $0.pathExtension.lowercased() == "apk" }
            }
            _ = try await adb.install(serial, apks: apks, options: options)
        }
        dismiss()
        onFinish()
    }
}

// MARK: - Files
