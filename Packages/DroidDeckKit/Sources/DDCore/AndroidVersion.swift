import Foundation

/// An Android platform identifier as used by SDK package paths. Observed forms
/// (sdkmanager --list, Oct 2026): "android-34", "android-36.1", "android-37.0",
/// "android-35-ext14", "android-37.2-beta3", "android-CANARY", "android-canary-20261007",
/// and the legacy codename form "android-Baklava".
public struct AndroidPlatform: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var apiLevel: Int
    /// Minor SDK version (Android 16 QPR and later), e.g. 1 in "36.1".
    public var minor: Int?
    /// SDK extension level variant, e.g. 14 in "35-ext14".
    public var extensionLevel: Int?
    /// Pre-release label: "beta3", "CANARY", "canary-20261007", or a codename.
    public var preview: String?

    public init(apiLevel: Int, minor: Int? = nil, extensionLevel: Int? = nil, preview: String? = nil) {
        self.apiLevel = apiLevel
        self.minor = minor
        self.extensionLevel = extensionLevel
        self.preview = preview
    }

    private static let numericPattern = try! NSRegularExpression(
        pattern: #"^(\d+)(?:\.(\d+))?(?:-ext(\d+))?(?:-([A-Za-z]+\d*))?$"#
    )

    public init?(sdkString: String) {
        var text = sdkString
        if text.hasPrefix("android-") { text.removeFirst("android-".count) }
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        if let match = Self.numericPattern.firstMatch(in: text, range: range) {
            func group(_ i: Int) -> String? {
                guard let r = Range(match.range(at: i), in: text) else { return nil }
                return String(text[r])
            }
            apiLevel = Int(group(1)!)!
            minor = group(2).flatMap(Int.init)
            extensionLevel = group(3).flatMap(Int.init)
            preview = group(4)
        } else if text.first!.isLetter {
            preview = text
            apiLevel = Self.codenameAPILevels[text.lowercased()] ?? 10_000
            minor = nil
            extensionLevel = nil
        } else {
            return nil
        }
    }

    public var isPreview: Bool { preview != nil }

    public var sdkString: String {
        if apiLevel == 10_000, let preview { return "android-\(preview)" }
        var text = "android-\(apiLevel)"
        if let minor { text += ".\(minor)" }
        if let extensionLevel { text += "-ext\(extensionLevel)" }
        if let preview { text += "-\(preview)" }
        return text
    }

    public var description: String { sdkString }

    public static func < (lhs: AndroidPlatform, rhs: AndroidPlatform) -> Bool {
        let l = (lhs.apiLevel, lhs.minor ?? 0, lhs.extensionLevel ?? 0, lhs.isPreview ? 0 : 1)
        let r = (rhs.apiLevel, rhs.minor ?? 0, rhs.extensionLevel ?? 0, rhs.isPreview ? 0 : 1)
        return l < r
    }

    /// e.g. "Android 14", "Android 16 (API 36.1)", "Android 17 (API 37.2) beta3", "Android Canary".
    public var marketingName: String {
        if apiLevel == 10_000 { return "Android \(preview ?? "Preview")" }
        guard let base = Self.marketingVersions[apiLevel] else {
            return "API \(apiLevel)" + (preview.map { " \($0)" } ?? "")
        }
        var name = "Android \(base)"
        if let minor, minor > 0 { name += " (API \(apiLevel).\(minor))" }
        if let extensionLevel { name += " ext \(extensionLevel)" }
        if let preview { name += " \(preview)" }
        return name
    }

    public var dessertName: String? { Self.desserts[apiLevel] }

    // Public Android release history (developer.android.com/tools/releases/platforms).
    static let marketingVersions: [Int: String] = [
        21: "5.0", 22: "5.1", 23: "6.0", 24: "7.0", 25: "7.1", 26: "8.0", 27: "8.1",
        28: "9", 29: "10", 30: "11", 31: "12", 32: "12L", 33: "13", 34: "14",
        35: "15", 36: "16", 37: "17",
    ]

    static let desserts: [Int: String] = [
        21: "Lollipop", 22: "Lollipop", 23: "Marshmallow", 24: "Nougat", 25: "Nougat",
        26: "Oreo", 27: "Oreo", 28: "Pie", 29: "Quince Tart", 30: "Red Velvet Cake",
        31: "Snow Cone", 32: "Snow Cone v2", 33: "Tiramisu", 34: "Upside Down Cake",
        35: "Vanilla Ice Cream", 36: "Baklava",
    ]

    static let codenameAPILevels: [String: Int] = ["baklava": 36]
}
