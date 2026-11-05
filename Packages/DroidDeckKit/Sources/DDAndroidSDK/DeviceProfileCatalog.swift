import Foundation
import DDCore
import DDPlatform

/// Loads Google's hardware definitions from the SDK's sdklib jars
/// (com/android/sdklib/devices/*.xml) and the user's ~/.android/devices.xml.
public enum DeviceProfileCatalog {
    static let definitionFiles = ["nexus.xml", "devices.xml", "wear.xml", "tv.xml", "automotive.xml", "desktop.xml", "xr.xml"]

    public struct Source: Sendable {
        public var name: String
        public var jar: URL
    }

    /// Jars to read, newest definitions first. Android Studio usually ships newer
    /// profiles (e.g. the Pixel 10 family) than standalone command-line tools.
    public static func sources(sdkRoot: URL) -> [Source] {
        var sources: [Source] = []
        for app in ["/Applications/Android Studio.app", "\(NSHomeDirectory())/Applications/Android Studio.app"] {
            let jar = URL(fileURLWithPath: app).appending(path: "Contents/plugins/android/lib/sdklib.jar")
            if FileManager.default.fileExists(atPath: jar.path) { sources.append(Source(name: "Android Studio", jar: jar)) }
        }
        if let cmdline = SDKLocator.commandLineToolsDirectory(root: sdkRoot) {
            let jar = cmdline.appending(path: "lib/sdklib/sdklib.core.jar")
            if FileManager.default.fileExists(atPath: jar.path) { sources.append(Source(name: "Command-line Tools", jar: jar)) }
        }
        return sources
    }

    public static func load(sdkRoot: URL, runner: ProcessRunner = ProcessRunner()) async -> [DeviceProfile] {
        var profiles: [String: DeviceProfile] = [:]
        for source in sources(sdkRoot: sdkRoot) {
            for file in definitionFiles {
                guard let result = try? await runner.run(
                    URL(fileURLWithPath: "/usr/bin/unzip"),
                    ["-p", source.jar.path, "com/android/sdklib/devices/\(file)"],
                    timeout: .seconds(30)
                ), result.succeeded else { continue }
                for profile in parse(xml: result.stdout, source: source.name) where profiles[profile.id] == nil {
                    profiles[profile.id] = profile
                }
            }
        }
        let userFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".android/devices.xml")
        if let data = try? Data(contentsOf: userFile) {
            for profile in parse(xml: data, source: "User") { profiles[profile.id] = profile }
        }
        return profiles.values.sorted(by: sortOrder)
    }

    /// Pixel phones newest first, then other manufacturers, then other form factors.
    static func sortOrder(_ a: DeviceProfile, _ b: DeviceProfile) -> Bool {
        func rank(_ p: DeviceProfile) -> Int {
            switch p.formFactor {
            case .phone: return 0
            case .foldable: return 1
            case .tablet: return 2
            default: return 3
            }
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        let aPixel = a.id.hasPrefix("pixel"), bPixel = b.id.hasPrefix("pixel")
        if aPixel != bPixel { return aPixel }
        // Newest generation first: "Pixel 10 Pro" (10) before "Pixel 9a" (9) before "Pixel XL" (none).
        let ga = generation(a.name), gb = generation(b.name)
        if ga != gb { return ga > gb }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    static func generation(_ name: String) -> Int {
        let digits = name.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    public static func parse(xml: Data, source: String) -> [DeviceProfile] {
        let delegate = DeviceXMLDelegate(source: source)
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.profiles
    }
}

private final class DeviceXMLDelegate: NSObject, XMLParserDelegate {
    let source: String
    var profiles: [DeviceProfile] = []

    private var inDevice = false
    private var path: [String] = []
    private var text = ""
    private var fields: [String: String] = [:]
    private var ramUnit = "MiB"
    private var cameras: [String] = []
    private var tagIDs: [String] = []

    init(source: String) { self.source = source }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "device" {
            inDevice = true
            fields = [:]
            cameras = []
            tagIDs = []
            ramUnit = "MiB"
        }
        if name == "ram" { ramUnit = attributes["unit"] ?? "MiB" }
        path.append(name)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast(); text = "" }
        guard inDevice else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = path.dropLast().last ?? ""
        switch name {
        case "location" where parent == "camera": cameras.append(value)
        case "tag-id": tagIDs.append(value)
        case "device":
            inDevice = false
            if let profile = makeProfile() { profiles.append(profile) }
        default:
            // Keep the first occurrence (hardware-level values precede state overrides).
            if fields[name] == nil, !value.isEmpty { fields[name] = value }
        }
    }

    private func makeProfile() -> DeviceProfile? {
        guard let id = fields["id"], let name = fields["name"],
              let width = fields["x-dimension"].flatMap(Int.init),
              let height = fields["y-dimension"].flatMap(Int.init) else { return nil }
        let diagonal = fields["diagonal-length"].flatMap(Double.init) ?? 0
        let ram: Megabytes? = fields["ram"].flatMap(Double.init).map { value in
            switch ramUnit.lowercased() {
            case "gib", "gb": return Megabytes(Int(value * 1024))
            case "kib", "kb": return Megabytes(Int(value / 1024))
            default: return Megabytes(Int(value))
            }
        }
        let (minAPI, maxAPI) = parseAPIRange(fields["api-level"])
        return DeviceProfile(
            id: id,
            name: name,
            manufacturer: fields["manufacturer"] ?? "Generic",
            formFactor: formFactor(id: id, diagonal: diagonal),
            screenWidth: width,
            screenHeight: height,
            diagonalInches: diagonal,
            xdpi: fields["xdpi"].flatMap(Double.init) ?? 0,
            ydpi: fields["ydpi"].flatMap(Double.init) ?? 0,
            densityBucket: fields["pixel-density"] ?? "",
            ram: ram,
            playStoreEnabled: fields["playstore-enabled"] == "true",
            skinName: fields["skin"].flatMap { $0.isEmpty || $0 == "_no_skin" ? nil : $0 },
            sensors: (fields["sensors"] ?? "").split(separator: " ").map(String.init),
            hasFrontCamera: cameras.contains("front"),
            hasBackCamera: cameras.contains("back"),
            hasHardwareKeyboard: (fields["keyboard"] ?? "nokeys") != "nokeys",
            minimumAPILevel: minAPI,
            maximumAPILevel: maxAPI,
            source: source
        )
    }

    private func formFactor(id: String, diagonal: Double) -> DeviceFormFactor {
        let tags = tagIDs.joined(separator: " ")
        if tags.contains("android-wear") { return .wear }
        if tags.contains("android-tv") || tags.contains("google-tv") { return .tv }
        if tags.contains("android-automotive") { return .automotive }
        if tags.contains("android-desktop") { return .desktop }
        if tags.contains("android-xr") { return .xr }
        if id.contains("fold") { return .foldable }
        return diagonal >= 7 ? .tablet : .phone
    }

    /// "35-" (35 and up), "-30" (up to 30), "21-29", "34".
    private func parseAPIRange(_ raw: String?) -> (Int?, Int?) {
        guard let raw, !raw.isEmpty else { return (nil, nil) }
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        if parts.count == 1 { return (parts[0], parts[0]) }
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }
}
