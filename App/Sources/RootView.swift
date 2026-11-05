import SwiftUI
import DroidDeckKit

/// The main window: one list of devices. Everything else is a sheet or lives in Settings.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        DeviceListView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $model.showingNewDevice) {
                NewDeviceSheet().environment(model)
            }
            .sheet(item: Binding(get: { model.settingsDeviceID.map(DeviceRef.init) },
                                 set: { model.settingsDeviceID = $0?.id })) { ref in
                DeviceSettingsSheet(deviceID: ref.id).environment(model)
            }
            .sheet(isPresented: Binding(get: { model.started && model.needsOnboarding && !model.devices.isBootstrapping },
                                        set: { _ in })) {
                OnboardingView()
                    .environment(model)
                    .interactiveDismissDisabled()
            }
            // The New Device sheet shows its own license prompt (a window shows one sheet at a time).
            .sheet(item: Binding(get: { model.showingNewDevice ? nil : model.images.pendingLicense }, set: { _ in })) { prompt in
                LicenseSheet(prompt: prompt).environment(model)
            }
            .errorAlert(model)
            .onChange(of: model.pendingDisplayWindow) { _, id in
                if let id {
                    openWindow(id: "device", value: id)
                    model.pendingDisplayWindow = nil
                }
            }
            .overlay {
                if model.devices.isBootstrapping && model.devices.adapter == nil {
                    ProgressView("Looking for the Android SDK…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
    }
}

/// A device id that sheets can present by.
struct DeviceRef: Identifiable, Hashable {
    let id: String
}
