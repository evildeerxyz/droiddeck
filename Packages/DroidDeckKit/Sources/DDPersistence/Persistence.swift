import Foundation
import DDCore
import DDPlatform

/// Where DroidDeck keeps its own data. Device runtime files stay in the AVD home;
/// DroidDeck only stores metadata (groups, notes, preferences, history) here.
public struct AppPaths: Sendable {
    public var applicationSupport: URL

    /// DROIDDECK_SUPPORT_DIR relocates all DroidDeck data (used by UI tests to stay isolated).
    public init(applicationSupport: URL? = nil) {
        if let applicationSupport {
            self.applicationSupport = applicationSupport
        } else if let override = ProcessInfo.processInfo.environment["DROIDDECK_SUPPORT_DIR"], !override.isEmpty {
            self.applicationSupport = URL(fileURLWithPath: override)
        } else {
            self.applicationSupport = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/DroidDeck")
        }
    }

    public var registry: URL { applicationSupport.appending(path: "devices.json") }
    public var preferences: URL { applicationSupport.appending(path: "preferences.json") }
    public var history: URL { applicationSupport.appending(path: "history.jsonl") }
    public var automations: URL { applicationSupport.appending(path: "Automations") }
    public var syncIndexes: URL { applicationSupport.appending(path: "SyncIndexes") }
    public var logs: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DroidDeck") }

    public static var defaultSharedFoldersRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "DroidDeck")
    }
}

/// How files from a device's Finder folder are placed on the device.
public enum SharedFolderLayout: String, Codable, Sendable, CaseIterable {
    /// Images → Pictures/DroidDeck, videos → Movies/DroidDeck, audio → Music/DroidDeck, others → Download/DroidDeck.
    /// Gallery and Files apps show these immediately.
    case byMediaType
    /// Everything mirrored under /sdcard/DroidDeck preserving subfolders.
    case mirror

    public var displayName: String {
        switch self {
        case .byMediaType: return "Sort into Pictures, Movies, Music, Download"
        case .mirror: return "Mirror into /sdcard/DroidDeck"
        }
    }
}

public struct SharedFolderSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var localPath: String
    public var layout: SharedFolderLayout
    /// Remove files from the device when they are removed from the Mac folder. Off by default.
    public var propagateDeletions: Bool

    public init(enabled: Bool, localPath: String, layout: SharedFolderLayout = .byMediaType, propagateDeletions: Bool = false) {
        self.enabled = enabled
        self.localPath = localPath
        self.layout = layout
        self.propagateDeletions = propagateDeletions
    }
}

/// A keyboard key mapped to a touch on the device screen (gaming controls).
public struct KeyBinding: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case tap
        /// W/A/S/D-style joystick centered at (x, y) with `radius`.
        case joystickUp, joystickDown, joystickLeft, joystickRight
    }

    public var id: UUID
    public var key: String           // characters as typed, lowercase ("w", " ")
    public var kind: Kind
    /// Normalized device-screen coordinates (0...1).
    public var x: Double
    public var y: Double
    public var radius: Double

    public init(id: UUID = UUID(), key: String, kind: Kind, x: Double, y: Double, radius: Double = 0.08) {
        self.id = id
        self.key = key
        self.kind = kind
        self.x = x
        self.y = y
        self.radius = radius
    }
}

/// DroidDeck's metadata for one AVD, keyed by AVD name.
/// A colored label shared across devices, like Finder tags. Names are unique ignoring case and spacing.
public struct DeviceTag: Codable, Sendable, Hashable, Identifiable {
    public enum Color: String, Codable, Sendable, CaseIterable {
        case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray
    }

    public static let maxLength = 24

    public var name: String
    public var color: Color
    public var id: String { Self.key(name) }

    public init(name: String, color: Color) {
        self.name = Self.clean(name)
        self.color = color
    }

    /// Trimmed, single-spaced and at most `maxLength` characters.
    public static func clean(_ name: String) -> String {
        String(name.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(maxLength))
    }

    public static func key(_ name: String) -> String { clean(name).lowercased() }
}

extension Array where Element == DeviceTag {
    /// Adds a tag unless the name is already present. A name that exists in `library` keeps its color,
    /// so a tag looks the same on every device.
    public func adding(_ tag: DeviceTag, library: [DeviceTag] = []) -> [DeviceTag] {
        guard !tag.name.isEmpty, !contains(where: { $0.id == tag.id }) else { return self }
        return self + [library.first { $0.id == tag.id } ?? tag]
    }

    public func removing(_ id: String) -> [DeviceTag] { filter { $0.id != id } }

    /// Renames and/or recolors one tag. Renaming onto a name already present merges the two.
    public func updating(_ id: String, name: String? = nil, color: DeviceTag.Color? = nil) -> [DeviceTag] {
        var seen = Set<String>()
        return compactMap { original in
            var tag = original
            if tag.id == id {
                if let name, !DeviceTag.clean(name).isEmpty { tag.name = DeviceTag.clean(name) }
                if let color { tag.color = color }
            }
            return seen.insert(tag.id).inserted ? tag : nil
        }
    }
}

public struct DeviceMetadata: Codable, Sendable, Equatable {
    public var avdName: String
    public var group: String?
    public var notes: String
    public var createdByDroidDeck: Bool
    public var createdAt: Date?
    public var lastStartedAt: Date?
    public var displayMode: DisplayMode
    public var showFrame: Bool
    public var sharedFolder: SharedFolderSettings?
    public var keyBindings: [KeyBinding]
    public var keyMappingEnabled: Bool
    /// Keep the display on while no DroidDeck window shows this device (e.g. for background playback).
    public var keepAwakeInBackground: Bool
    public var tags: [DeviceTag]
    /// The name shown in DroidDeck, chosen by the user. It can change while the device runs because
    /// it isn't written to the AVD; nil or blank shows the AVD's own display name.
    public var name: String?

    public init(avdName: String, group: String? = nil, notes: String = "", createdByDroidDeck: Bool = false,
                createdAt: Date? = nil, lastStartedAt: Date? = nil, displayMode: DisplayMode = .embedded,
                showFrame: Bool = true, sharedFolder: SharedFolderSettings? = nil,
                keyBindings: [KeyBinding] = [], keyMappingEnabled: Bool = false, keepAwakeInBackground: Bool = false,
                tags: [DeviceTag] = [], name: String? = nil) {
        self.name = name
        self.avdName = avdName
        self.group = group
        self.notes = notes
        self.createdByDroidDeck = createdByDroidDeck
        self.createdAt = createdAt
        self.lastStartedAt = lastStartedAt
        self.displayMode = displayMode
        self.showFrame = showFrame
        self.sharedFolder = sharedFolder
        self.keyBindings = keyBindings
        self.keyMappingEnabled = keyMappingEnabled
        self.keepAwakeInBackground = keepAwakeInBackground
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case avdName, group, notes, createdByDroidDeck, createdAt, lastStartedAt, displayMode, showFrame
        case sharedFolder, keyBindings, keyMappingEnabled, keepAwakeInBackground, tags, name
    }

    // Tolerant decoding: fields added in later versions get defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        avdName = try c.decode(String.self, forKey: .avdName)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdByDroidDeck = try c.decodeIfPresent(Bool.self, forKey: .createdByDroidDeck) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        lastStartedAt = try c.decodeIfPresent(Date.self, forKey: .lastStartedAt)
        displayMode = try c.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? .embedded
        showFrame = try c.decodeIfPresent(Bool.self, forKey: .showFrame) ?? true
        sharedFolder = try c.decodeIfPresent(SharedFolderSettings.self, forKey: .sharedFolder)
        keyBindings = try c.decodeIfPresent([KeyBinding].self, forKey: .keyBindings) ?? []
        keyMappingEnabled = try c.decodeIfPresent(Bool.self, forKey: .keyMappingEnabled) ?? false
        keepAwakeInBackground = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeInBackground) ?? false
        tags = try c.decodeIfPresent([DeviceTag].self, forKey: .tags) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }
}

public enum QuitBehavior: String, Codable, Sendable, CaseIterable {
    case ask, stopDevices, leaveRunning

    public var displayName: String {
        switch self {
        case .ask: return "Ask"
        case .stopDevices: return "Stop running devices"
        case .leaveRunning: return "Leave devices running"
        }
    }
}

public struct AppPreferences: Codable, Sendable, Equatable {
    public var sdkPathOverride: String?
    public var avdHomeOverride: String?
    public var defaultDisplayMode: DisplayMode = .embedded
    public var quitBehavior: QuitBehavior = .ask
    /// Public IP checks contact a third-party service; off until the user opts in.
    public var allowPublicIPLookup = false
    public var publicIPServiceHost = "api.ipify.org"
    public var screenshotFolder: String?
    public var sharedFoldersRoot: String?
    public var bootTimeoutSeconds = 300
    public var onboardingCompleted = false
    public var stopDevicesOnHighMemoryPressure = false
    /// Turn off the screen of devices with no DroidDeck window on screen, like a phone in a pocket.
    public var sleepDevicesNotOnScreen = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let defaults = AppPreferences()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sdkPathOverride = try c.decodeIfPresent(String.self, forKey: .sdkPathOverride)
        avdHomeOverride = try c.decodeIfPresent(String.self, forKey: .avdHomeOverride)
        defaultDisplayMode = try c.decodeIfPresent(DisplayMode.self, forKey: .defaultDisplayMode) ?? defaults.defaultDisplayMode
        quitBehavior = try c.decodeIfPresent(QuitBehavior.self, forKey: .quitBehavior) ?? defaults.quitBehavior
        allowPublicIPLookup = try c.decodeIfPresent(Bool.self, forKey: .allowPublicIPLookup) ?? defaults.allowPublicIPLookup
        publicIPServiceHost = try c.decodeIfPresent(String.self, forKey: .publicIPServiceHost) ?? defaults.publicIPServiceHost
        screenshotFolder = try c.decodeIfPresent(String.self, forKey: .screenshotFolder)
        sharedFoldersRoot = try c.decodeIfPresent(String.self, forKey: .sharedFoldersRoot)
        bootTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .bootTimeoutSeconds) ?? defaults.bootTimeoutSeconds
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        stopDevicesOnHighMemoryPressure = try c.decodeIfPresent(Bool.self, forKey: .stopDevicesOnHighMemoryPressure) ?? false
        sleepDevicesNotOnScreen = try c.decodeIfPresent(Bool.self, forKey: .sleepDevicesNotOnScreen) ?? defaults.sleepDevicesNotOnScreen
    }

    public var screenshotDirectory: URL {
        screenshotFolder.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Pictures/DroidDeck")
    }

    public var sharedFoldersDirectory: URL {
        sharedFoldersRoot.map { URL(fileURLWithPath: $0) } ?? AppPaths.defaultSharedFoldersRoot
    }
}

public struct OperationRecord: Codable, Sendable, Identifiable, Equatable {
    public enum Outcome: String, Codable, Sendable { case succeeded, failed, cancelled }

    public var id: UUID
    public var title: String
    public var deviceName: String?
    public var startedAt: Date
    public var finishedAt: Date
    public var outcome: Outcome
    public var message: String?

    public init(id: UUID = UUID(), title: String, deviceName: String?, startedAt: Date, finishedAt: Date,
                outcome: Outcome, message: String?) {
        self.id = id
        self.title = title
        self.deviceName = deviceName
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.message = message.map { Redactor.redact($0) }
    }
}

/// Atomic JSON persistence for small documents.
public actor JSONDocumentStore<Value: Codable & Sendable> {
    private let url: URL
    private let defaultValue: @Sendable () -> Value

    public init(url: URL, default defaultValue: @escaping @Sendable () -> Value) {
        self.url = url
        self.defaultValue = defaultValue
    }

    public func load() -> Value {
        guard let data = try? Data(contentsOf: url) else { return defaultValue() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            // Keep the unreadable file for inspection rather than overwriting it silently.
            let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: url, to: backup)
            log.error("persistence", "Could not read \(url.lastPathComponent); saved a copy as \(backup.lastPathComponent): \(error)")
            return defaultValue()
        }
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try SafeFileOperations.writeAtomically(try encoder.encode(value), to: url, permissions: 0o600)
    }
}

/// Append-only operation history (JSON lines), trimmed to the most recent entries.
public actor OperationHistoryStore {
    private let url: URL
    private let maxEntries: Int

    public init(url: URL, maxEntries: Int = 2000) {
        self.url = url
        self.maxEntries = maxEntries
    }

    public func append(_ record: OperationRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        }
        trimIfNeeded()
    }

    public func load(limit: Int = 500) -> [OperationRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).suffix(limit).compactMap { try? decoder.decode(OperationRecord.self, from: Data($0)) }.reversed()
    }

    private func trimIfNeeded() {
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        guard lines.count > maxEntries + 200 else { return }
        let kept = lines.suffix(maxEntries).map { Data($0) + Data([0x0A]) }.reduce(Data(), +)
        try? SafeFileOperations.writeAtomically(kept, to: url, permissions: 0o600)
    }
}
