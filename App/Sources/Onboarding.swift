import SwiftUI
import DroidDeckKit

// MARK: - Onboarding

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.system(size: 34)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Welcome to DroidDeck").font(.title2.weight(.semibold))
                    Text("DroidDeck runs real Android virtual devices with Google's Android Emulator.").foregroundStyle(.secondary)
                }
            }
            if let error = model.devices.bootstrapError {
                NoticeView(kind: .error, title: error.message, message: error.recovery)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.devices.detection?.checks ?? []) { check in
                    HStack(alignment: .top) {
                        Image(systemName: check.status == .ok ? "checkmark.circle.fill" : check.status == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(check.status == .ok ? .green : check.status == .warning ? .orange : .red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.title).fontWeight(.medium)
                            Text(check.detail).font(.callout).foregroundStyle(.secondary)
                            if let recovery = check.recovery { Text(recovery).font(.callout) }
                        }
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Choose SDK Folder…") { chooseSDK() }
                Button("Check Again") { Task { await model.devices.bootstrap() } }
                Spacer()
                Button("Continue") {
                    Task { await model.devices.updatePreferences { $0.onboardingCompleted = true } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!(model.devices.detection?.canRunDevices ?? false))
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private func chooseSDK() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your Android SDK folder (it contains emulator and platform-tools)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.devices.updatePreferences { $0.sdkPathOverride = url.path } }
    }
}

// MARK: - Licenses

struct LicenseSheet: View {
    @Environment(AppModel.self) private var model
    let prompt: ImageLibrary.LicensePrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("License Agreement").font(.title3.weight(.semibold))
            Text("Installing \(prompt.package) requires accepting \"\(prompt.licenseID)\". DroidDeck never accepts licenses for you.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(prompt.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Decline") { model.images.respondToLicense(accept: false) }
                Button("Accept") { model.images.respondToLicense(accept: true) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .interactiveDismissDisabled()
    }
}
