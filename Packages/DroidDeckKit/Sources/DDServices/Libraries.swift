import Foundation
import Observation
import DDCore
import DDPlatform
import DDAndroidSDK

/// Installed and downloadable system images, with license-aware installation.
@MainActor
@Observable
public final class ImageLibrary {
    public struct LicensePrompt: Identifiable, Equatable {
        public let id = UUID()
        public var package: String
        public var licenseID: String
        public var text: String
    }

    public private(set) var installed: [SystemImage] = []
    public private(set) var catalog: [SystemImage] = []
    public private(set) var updates: [SDKPackageListing] = []
    public private(set) var isLoadingCatalog = false
    public private(set) var catalogError: DroidDeckError?
    public private(set) var catalogDate: Date?
    public private(set) var installing: [String: Double] = [:]
    public var pendingLicense: LicensePrompt?

    private var licenseContinuation: CheckedContinuation<LicenseDecision, Never>?
    private let devices: DeviceManager

    public init(devices: DeviceManager) {
        self.devices = devices
    }

    public var hostABIs: [AndroidABI] { devices.host.architecture.acceleratedABIs }

    /// Images this Mac can run, newest first.
    public func compatible(_ images: [SystemImage]) -> [SystemImage] {
        images.filter { $0.androidABI.map(hostABIs.contains) ?? false }
    }

    public var latestStablePlatform: AndroidPlatform? {
        SystemImageCatalog.latestStablePlatform(in: catalog.isEmpty ? installed : catalog, abis: hostABIs)
    }

    public func reloadInstalled() {
        guard let sdk = devices.sdk else { installed = []; return }
        installed = SystemImageCatalog.installedImages(sdkRoot: sdk.root)
        if !catalog.isEmpty {
            catalog = SystemImageCatalog.merge(installed: installed, listing: lastListing ?? SDKManagerListing())
        }
    }

    private var lastListing: SDKManagerListing?

    /// Fetches the repository listing through sdkmanager (contacts dl.google.com).
    public func refreshCatalog() async {
        guard let sdk = devices.sdk else { return }
        isLoadingCatalog = true
        catalogError = nil
        defer { isLoadingCatalog = false }
        do {
            let listing = try await SDKManagerClient(installation: sdk).list()
            lastListing = listing
            reloadInstalled()
            catalog = SystemImageCatalog.merge(installed: installed, listing: listing)
            updates = listing.updates
            catalogDate = Date()
        } catch let error as DroidDeckError {
            catalogError = error
        } catch {
            catalogError = DroidDeckError(.network, error.localizedDescription)
        }
    }

    public func install(_ package: String) {
        guard let sdk = devices.sdk, installing[package] == nil else { return }
        installing[package] = 0
        let library = self
        devices.tasks.run("Download \(package.split(separator: ";").dropFirst().joined(separator: " "))") { reporter in
            defer { Task { @MainActor in library.installing[package] = nil; library.reloadInstalled() } }
            try await SDKManagerClient(installation: sdk).install(
                package: package,
                decide: { licenseID, text in
                    await library.askLicense(package: package, licenseID: licenseID, text: text)
                },
                progress: { event in
                    if case .progress(let percent, let message) = event {
                        reporter.update(progress: Double(percent) / 100, detail: message)
                        Task { @MainActor in library.installing[package] = Double(percent) / 100 }
                    }
                }
            )
        }
    }

    public func uninstall(_ image: SystemImage) async throws {
        guard let sdk = devices.sdk else { return }
        let inUse = devices.devices.filter { $0.device.configuration.systemImagePackage == image.packagePath }
        guard inUse.isEmpty else {
            throw DroidDeckError(.deviceBusy, "\(inUse.count) device\(inUse.count == 1 ? " uses" : "s use") this image.",
                                 recovery: "Delete those devices first: \(inUse.map(\.displayName).joined(separator: ", ")).")
        }
        _ = try await devices.tasks.perform("Remove \(image.title)") { _ in
            try await SDKManagerClient(installation: sdk).uninstall(package: image.packagePath)
        }
        reloadInstalled()
    }

    private func askLicense(package: String, licenseID: String, text: String) async -> LicenseDecision {
        await withCheckedContinuation { continuation in
            licenseContinuation = continuation
            pendingLicense = LicensePrompt(package: package, licenseID: licenseID, text: text)
        }
    }

    public func respondToLicense(accept: Bool) {
        pendingLicense = nil
        licenseContinuation?.resume(returning: accept ? .accept : .decline)
        licenseContinuation = nil
    }
}

/// Official hardware profiles.
@MainActor
@Observable
public final class ProfileLibrary {
    public private(set) var profiles: [DeviceProfile] = []
    public private(set) var isLoading = false

    public init() {}

    public func load(sdk: SDKInstallation) async {
        guard profiles.isEmpty else { return }
        isLoading = true
        profiles = await DeviceProfileCatalog.load(sdkRoot: sdk.root, runner: sdk.runner)
        isLoading = false
    }

    public func profile(id: String?) -> DeviceProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    public var phones: [DeviceProfile] { profiles.filter { $0.formFactor == .phone || $0.formFactor == .foldable } }
}
