import Foundation

/// A semantic version as used by SDK packages ("36.6.11", "35.4.9").
public struct PackageVersion: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var components: [Int]

    public init(_ components: [Int]) { self.components = components }

    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == " " })
            .prefix(4)
            .compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        components = parts
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// Trailing zero components are insignificant: 36.6.11 == 36.6.11.0.
    private var normalized: [Int] {
        var parts = components
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        return parts
    }

    public static func == (lhs: PackageVersion, rhs: PackageVersion) -> Bool { lhs.normalized == rhs.normalized }
    public func hash(into hasher: inout Hasher) { hasher.combine(normalized) }

    public static func < (lhs: PackageVersion, rhs: PackageVersion) -> Bool {
        for i in 0..<max(lhs.components.count, rhs.components.count) {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

/// An Android system image, installed or available from the SDK repository.
public struct SystemImage: Hashable, Codable, Sendable, Identifiable {
    /// sdkmanager package path, e.g. "system-images;android-34;google_apis;arm64-v8a".
    public var packagePath: String
    public var platform: AndroidPlatform
    /// Primary tag id directory name, e.g. "google_apis_playstore_ps16k" is the directory, tags hold the semantic ids.
    public var tagDirectory: String
    public var tagIDs: [String]
    public var tagDisplay: String
    public var abi: String
    public var revision: String
    public var description: String
    public var extensionLevel: Int?
    public var minimumEmulatorVersion: PackageVersion?
    public var isInstalled: Bool
    /// Installation directory when installed.
    public var installPath: String?
    /// Download size reported by the repository, when known.
    public var downloadSizeBytes: Int64?

    public var id: String { packagePath }

    public init(packagePath: String, platform: AndroidPlatform, tagDirectory: String, tagIDs: [String],
                tagDisplay: String, abi: String, revision: String, description: String,
                extensionLevel: Int? = nil, minimumEmulatorVersion: PackageVersion? = nil,
                isInstalled: Bool, installPath: String? = nil, downloadSizeBytes: Int64? = nil) {
        self.packagePath = packagePath
        self.platform = platform
        self.tagDirectory = tagDirectory
        self.tagIDs = tagIDs
        self.tagDisplay = tagDisplay
        self.abi = abi
        self.revision = revision
        self.description = description
        self.extensionLevel = extensionLevel
        self.minimumEmulatorVersion = minimumEmulatorVersion
        self.isInstalled = isInstalled
        self.installPath = installPath
        self.downloadSizeBytes = downloadSizeBytes
    }

    /// Parses "system-images;android-34;google_apis;arm64-v8a".
    public static func components(of packagePath: String) -> (platform: AndroidPlatform, tag: String, abi: String)? {
        let parts = packagePath.split(separator: ";").map(String.init)
        guard parts.count == 4, parts[0] == "system-images", let platform = AndroidPlatform(sdkString: parts[1]) else {
            return nil
        }
        return (platform, parts[2], parts[3])
    }

    public var androidABI: AndroidABI? { AndroidABI(rawValue: abi) }

    /// Google Play images ship the Play Store and are signed release builds (no root via adb).
    public var hasGooglePlay: Bool {
        tagIDs.contains { $0.contains("playstore") } || tagDirectory.contains("playstore")
    }

    public var hasGoogleAPIs: Bool {
        hasGooglePlay || tagIDs.contains { $0.hasPrefix("google_apis") }
    }

    /// Android 15+ (API 35+) requires OpenGL ES 3.1. The emulator's Mac GPU path offers ES 3.0, so it renders those
    /// images in software ("API level 35 requires GLES 3.1, forcing software rendering"; same for 36 and 37): several
    /// cores while the screen is on. Android 14 and older run on the Mac GPU. Tested on emulator 37.2.12, M4 Pro.
    public static let firstAPILevelNeedingES31 = 35
    public var rendersOnMacGPU: Bool { platform.apiLevel < Self.firstAPILevelNeedingES31 }

    public var usesSixteenKBPages: Bool {
        tagIDs.contains("page_size_16kb") || tagDirectory.hasSuffix("_ps16k")
    }

    /// Form factor implied by the tag.
    public var formFactor: DeviceFormFactor {
        let tags = ([tagDirectory] + tagIDs).joined(separator: " ")
        if tags.contains("android-tv") || tags.contains("google-tv") { return .tv }
        if tags.contains("wear") { return .wear }
        if tags.contains("automotive") { return .automotive }
        if tags.contains("android-desktop") { return .desktop }
        if tags.contains("android-xr") || tags.contains("xr") { return .xr }
        return .phone
    }

    /// Automated Test Device images strip UI apps; they are not suitable as interactive phones.
    public var isAutomatedTestDevice: Bool {
        tagIDs.contains { $0.hasSuffix("_atd") } || tagDirectory.hasSuffix("_atd")
    }

    /// Human-readable title, e.g. "Android 14 · Google Play".
    public var title: String {
        let variant: String
        if hasGooglePlay {
            variant = "Google Play"
        } else if hasGoogleAPIs {
            variant = "Google APIs"
        } else if isAutomatedTestDevice {
            variant = "Automated Test Device"
        } else {
            variant = tagDisplay.isEmpty ? "AOSP" : tagDisplay
        }
        return "\(platform.marketingName) · \(variant)"
    }
}

public enum DeviceFormFactor: String, Codable, Sendable, CaseIterable {
    case phone, foldable, tablet, tv, wear, automotive, desktop, xr

    public var displayName: String {
        switch self {
        case .phone: return "Phone"
        case .foldable: return "Foldable"
        case .tablet: return "Tablet"
        case .tv: return "TV"
        case .wear: return "Wear OS"
        case .automotive: return "Automotive"
        case .desktop: return "Desktop"
        case .xr: return "XR"
        }
    }
}
