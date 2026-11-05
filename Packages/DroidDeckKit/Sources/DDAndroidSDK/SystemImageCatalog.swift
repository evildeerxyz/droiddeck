import Foundation
import DDCore
import DDPlatform

/// One row of an `sdkmanager --list` table.
public struct SDKPackageListing: Sendable, Equatable {
    public var path: String
    public var version: String
    public var description: String
    /// Installed location (installed table) or available version (updates table).
    public var extra: String?
}

public struct SDKManagerListing: Sendable, Equatable {
    public var installed: [SDKPackageListing] = []
    public var available: [SDKPackageListing] = []
    public var updates: [SDKPackageListing] = []

    public init(installed: [SDKPackageListing] = [], available: [SDKPackageListing] = [], updates: [SDKPackageListing] = []) {
        self.installed = installed
        self.available = available
        self.updates = updates
    }
}

public enum SystemImageCatalog {
    /// Scans `<sdk>/system-images/<platform>/<tag>/<abi>/source.properties`.
    ///
    /// The filesystem is authoritative for installed images: older cmdline-tools omit
    /// packages written with newer repository XML schemas from their "Installed" list.
    public static func installedImages(sdkRoot: URL) -> [SystemImage] {
        let fm = FileManager.default
        let base = sdkRoot.appending(path: "system-images")
        var images: [SystemImage] = []
        for platformDir in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
            guard let platform = AndroidPlatform(sdkString: platformDir) else { continue }
            let platformURL = base.appending(path: platformDir)
            for tagDir in (try? fm.contentsOfDirectory(atPath: platformURL.path)) ?? [] {
                let tagURL = platformURL.appending(path: tagDir)
                for abiDir in (try? fm.contentsOfDirectory(atPath: tagURL.path)) ?? [] {
                    let dir = tagURL.appending(path: abiDir)
                    guard let props = try? INIFile(contentsOf: dir.appending(path: "source.properties")) else { continue }
                    images.append(image(from: props, platformDir: platformDir, platform: platform,
                                        tagDir: tagDir, abiDir: abiDir, directory: dir))
                }
            }
        }
        return images.sorted { ($0.platform, $0.tagDirectory) > ($1.platform, $1.tagDirectory) }
    }

    static func image(from props: INIFile, platformDir: String, platform: AndroidPlatform,
                      tagDir: String, abiDir: String, directory: URL) -> SystemImage {
        let tagIDs = (props["SystemImage.TagId"] ?? tagDir).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        // "Pkg.Dependencies=emulator#35.4.9"
        let minEmulator = (props["Pkg.Dependencies"] ?? "")
            .split(separator: ",")
            .first { $0.hasPrefix("emulator#") }
            .flatMap { PackageVersion(String($0.dropFirst("emulator#".count))) }
        return SystemImage(
            packagePath: "system-images;\(platformDir);\(tagDir);\(abiDir)",
            platform: platform,
            tagDirectory: tagDir,
            tagIDs: tagIDs,
            tagDisplay: props["SystemImage.TagDisplay"] ?? tagDir,
            abi: props["SystemImage.Abi"] ?? abiDir,
            revision: props["Pkg.Revision"] ?? "?",
            description: props["Pkg.Desc"] ?? "",
            extensionLevel: props["AndroidVersion.ExtensionLevel"].flatMap(Int.init),
            minimumEmulatorVersion: minEmulator,
            isInstalled: true,
            installPath: directory.path
        )
    }

    /// Verifies the files the emulator needs to boot are present.
    public static func missingFiles(in image: SystemImage) -> [String] {
        guard let path = image.installPath else { return ["installation directory"] }
        let dir = URL(fileURLWithPath: path)
        let required = ["system.img", "ramdisk.img", "build.prop"]
        var missing = required.filter { !FileManager.default.fileExists(atPath: dir.appending(path: $0).path) }
        let kernels = ["kernel-ranchu", "kernel-ranchu-64", "kernel-qemu"]
        if !kernels.contains(where: { FileManager.default.fileExists(atPath: dir.appending(path: $0).path) }) {
            missing.append("kernel")
        }
        return missing
    }

    /// Parses `sdkmanager --list` output (progress noise, three tables).
    public static func parseListing(_ text: String) -> SDKManagerListing {
        var listing = SDKManagerListing()
        enum Section { case none, installed, available, updates }
        var section = Section.none
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Progress output uses carriage returns; keep only what follows the last one.
            let line = String(rawLine.split(separator: "\r", omittingEmptySubsequences: false).last ?? "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Installed packages:") { section = .installed; continue }
            if trimmed.hasPrefix("Available Packages:") { section = .available; continue }
            if trimmed.hasPrefix("Available Updates:") { section = .updates; continue }
            let columns = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 3, !columns[0].isEmpty, columns[0] != "Path", columns[0] != "ID",
                  !columns[0].hasPrefix("---") else { continue }
            switch section {
            case .installed:
                listing.installed.append(.init(path: columns[0], version: columns[1], description: columns[2],
                                               extra: columns.count > 3 ? columns[3] : nil))
            case .available:
                listing.available.append(.init(path: columns[0], version: columns[1], description: columns[2], extra: nil))
            case .updates:
                // ID | Installed | Available
                listing.updates.append(.init(path: columns[0], version: columns[1], description: "", extra: columns[2]))
            case .none:
                break
            }
        }
        return listing
    }

    /// Combines installed images with downloadable ones from the repository listing.
    public static func merge(installed: [SystemImage], listing: SDKManagerListing) -> [SystemImage] {
        var byPath = Dictionary(uniqueKeysWithValues: installed.map { ($0.packagePath, $0) })
        for row in listing.available where row.path.hasPrefix("system-images;") {
            guard byPath[row.path] == nil, let parts = SystemImage.components(of: row.path) else { continue }
            byPath[row.path] = SystemImage(
                packagePath: row.path,
                platform: parts.platform,
                tagDirectory: parts.tag,
                tagIDs: tagIDs(forDirectory: parts.tag),
                tagDisplay: row.description,
                abi: parts.abi,
                revision: row.version,
                description: row.description,
                extensionLevel: parts.platform.extensionLevel,
                isInstalled: false
            )
        }
        return byPath.values.sorted { ($0.platform, $0.tagDirectory, $0.abi) > ($1.platform, $1.tagDirectory, $1.abi) }
    }

    /// Repository tag directories map to tag ids, e.g. "google_apis_playstore_ps16k" → ["google_apis_playstore", "page_size_16kb"].
    static func tagIDs(forDirectory tag: String) -> [String] {
        if tag.hasSuffix("_ps16k") {
            return [String(tag.dropLast("_ps16k".count)), "page_size_16kb"]
        }
        return [tag]
    }

    /// The newest stable (non-preview) platform among phone images for the host ABI.
    public static func latestStablePlatform(in images: [SystemImage], abis: [AndroidABI]) -> AndroidPlatform? {
        images
            .filter { !$0.platform.isPreview && $0.formFactor == .phone && $0.platform.extensionLevel == nil }
            .filter { image in image.androidABI.map(abis.contains) ?? false }
            .map(\.platform)
            .max()
    }
}
