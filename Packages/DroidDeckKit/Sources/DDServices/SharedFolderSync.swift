import Foundation
import CoreServices
import Observation
import DDCore
import DDPlatform
import DDPersistence
import DDADB

/// Where a file from the Mac folder goes on the device.
public enum SharedFolderRouting {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "dng", "avif"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp", "webm", "mkv", "avi"]
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "amr"]

    public static func remotePath(for relativePath: String, layout: SharedFolderLayout) -> String {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        switch layout {
        case .mirror:
            return "/sdcard/DroidDeck/" + relativePath
        case .byMediaType:
            if imageExtensions.contains(ext) { return "/sdcard/Pictures/DroidDeck/" + relativePath }
            if videoExtensions.contains(ext) { return "/sdcard/Movies/DroidDeck/" + relativePath }
            if audioExtensions.contains(ext) { return "/sdcard/Music/DroidDeck/" + relativePath }
            return "/sdcard/Download/DroidDeck/" + relativePath
        }
    }

    public static func isMedia(_ relativePath: String) -> Bool {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext) || videoExtensions.contains(ext) || audioExtensions.contains(ext)
    }

    /// Files that are hidden, system metadata, or still being written by a browser/Finder.
    public static func shouldIgnore(_ relativePath: String) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        if relativePath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return true }
        let partial = ["download", "crdownload", "part", "partial", "tmp", "icloud"]
        return name == "Icon\r" || partial.contains((name as NSString).pathExtension.lowercased())
    }
}

/// Files chosen on the Mac (Upload button or drag and drop), resolved to device paths with the
/// same routing as shared folders. Folders are expanded recursively and keep their structure;
/// hidden files and unfinished downloads are skipped.
public struct UploadPlan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Photos and videos: shown by the Gallery / Photos and in app pickers such as TikTok's.
        case visual
        case audio
        case other
    }

    public struct Item: Sendable, Equatable {
        public let local: URL
        public let remote: String
        public let kind: Kind
    }

    public let items: [Item]

    public init(urls: [URL], fileManager: FileManager = .default) {
        var items: [Item] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                if let item = Self.item(url, relative: url.lastPathComponent) { items.append(item) }
                continue
            }
            let root = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var found: [Item] = []
            for case let file as URL in enumerator {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let components = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                guard components.starts(with: root), components.count > root.count else { continue }
                let relative = ([url.lastPathComponent] + components.dropFirst(root.count)).joined(separator: "/")
                if let item = Self.item(file, relative: relative) { found.append(item) }
            }
            items += found.sorted { $0.remote < $1.remote }
        }
        self.items = items
    }

    private static func item(_ local: URL, relative: String) -> Item? {
        guard !SharedFolderRouting.shouldIgnore(relative) else { return nil }
        let ext = (relative as NSString).pathExtension.lowercased()
        let kind: Kind = SharedFolderRouting.imageExtensions.contains(ext) || SharedFolderRouting.videoExtensions.contains(ext)
            ? .visual : SharedFolderRouting.audioExtensions.contains(ext) ? .audio : .other
        return Item(local: local, remote: SharedFolderRouting.remotePath(for: relative, layout: .byMediaType), kind: kind)
    }

    /// Where to find what was uploaded, in the words the device's own apps use.
    public var summary: String {
        let visual = items.filter { $0.kind == .visual }.count
        let audio = items.filter { $0.kind == .audio }.count
        let other = items.count - visual - audio
        var places: [String] = []
        if visual > 0 { places.append("photos & videos in Gallery › DroidDeck") }
        if audio > 0 { places.append("audio in Music › DroidDeck") }
        if other > 0 { places.append("files in Files › Downloads › DroidDeck") }
        return "Added \(items.count) file\(items.count == 1 ? "" : "s") — " + places.joined(separator: ", ")
    }
}

/// Recursive file-system watcher built on FSEvents.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "droiddeck.folderwatcher", qos: .utility)
    private let onChange: @Sendable () -> Void

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    func invalidate() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { invalidate() }
}

/// One-way sync from a Mac folder to a device's shared storage. New and changed files are
/// pushed and indexed by MediaStore so they show up in Gallery and Files without moving them.
public actor SharedFolderSyncEngine {
    public struct Status: Equatable, Sendable {
        public var lastSync: Date?
        public var syncedFiles: Int = 0
        public var pending: Int = 0
        public var lastError: String?
        public var isSyncing = false
    }

    struct IndexEntry: Codable, Equatable {
        var size: Int64
        var modified: Date
        var remotePath: String
    }

    public let deviceName: String
    private let localRoot: URL
    private var settings: SharedFolderSettings
    private let adb: ADBClient
    private var serial: String?
    private var index: [String: IndexEntry]
    private let indexURL: URL
    private var watcher: FolderWatcher?
    private var scheduled = false
    public private(set) var status = Status()
    private let onStatus: @Sendable (Status) -> Void

    public init(deviceName: String, settings: SharedFolderSettings, adb: ADBClient, indexDirectory: URL,
                onStatus: @escaping @Sendable (Status) -> Void) {
        self.deviceName = deviceName
        self.settings = settings
        self.localRoot = URL(fileURLWithPath: settings.localPath)
        self.adb = adb
        self.indexURL = indexDirectory.appending(path: "\(deviceName).json")
        self.onStatus = onStatus
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        index = (try? decoder.decode([String: IndexEntry].self, from: Data(contentsOf: indexURL))) ?? [:]
        status.syncedFiles = index.count
    }

    public func activate() throws {
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        watcher?.invalidate()
        watcher = FolderWatcher(path: localRoot.path) { [weak self] in
            Task { await self?.scheduleSync() }
        }
    }

    public func deactivate() {
        watcher?.invalidate()
        watcher = nil
    }

    /// Called when the device becomes reachable (or changes serial after a restart).
    public func deviceAvailable(serial: String?) async {
        let changed = serial != self.serial
        self.serial = serial
        if serial != nil && changed {
            await reconcileWithDevice()
            await sync()
        }
    }

    public func scheduleSync() async {
        guard !scheduled else { return }
        scheduled = true
        // Debounce bursts of events (e.g. dragging a folder of photos into Finder).
        try? await Task.sleep(for: .seconds(1))
        scheduled = false
        await sync()
    }

    /// Drops index entries whose remote file no longer exists (e.g. after a data wipe).
    private func reconcileWithDevice() async {
        guard let serial, !index.isEmpty else { return }
        let roots = Set(index.values.map { remoteRoot(of: $0.remotePath) })
        var present = Set<String>()
        for root in roots {
            let output = (try? await adb.shell(serial, "find \(ShellQuote.quote(root)) -type f 2>/dev/null", timeout: .seconds(60), allowFailure: true)) ?? ""
            present.formUnion(output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) })
        }
        index = index.filter { present.contains($0.value.remotePath) }
        saveIndex()
    }

    private func remoteRoot(of path: String) -> String {
        for root in ["/sdcard/Pictures/DroidDeck", "/sdcard/Movies/DroidDeck", "/sdcard/Music/DroidDeck",
                     "/sdcard/Download/DroidDeck", "/sdcard/DroidDeck"] where path.hasPrefix(root + "/") {
            return root
        }
        return (path as NSString).deletingLastPathComponent
    }

    public func sync() async {
        guard let serial, settings.enabled else { return }
        status.isSyncing = true
        publish()
        defer { status.isSyncing = false; status.lastSync = Date(); publish() }

        let local = scanLocal()
        var changed = local.filter { rel, info in
            guard let entry = index[rel] else { return true }
            return entry.size != info.size || abs(entry.modified.timeIntervalSince(info.modified)) > 1
        }
        status.pending = changed.count
        publish()

        // Only push files whose size is stable (not still being copied into the folder).
        if !changed.isEmpty {
            try? await Task.sleep(for: .seconds(1))
            let rescanned = scanLocal()
            changed = changed.filter { rescanned[$0.key]?.size == $0.value.size }
        }

        var errors: [String] = []
        for (rel, info) in changed.sorted(by: { $0.key < $1.key }) {
            let remote = SharedFolderRouting.remotePath(for: rel, layout: settings.layout)
            do {
                try await adb.makeDirectory(serial, path: (remote as NSString).deletingLastPathComponent)
                try await adb.push(serial, local: localRoot.appending(path: rel), remote: remote)
                if SharedFolderRouting.isMedia(rel) {
                    try await adb.scanMedia(serial, path: remote)
                }
                index[rel] = IndexEntry(size: info.size, modified: info.modified, remotePath: remote)
                status.pending = max(0, status.pending - 1)
                publish()
            } catch {
                errors.append("\(rel): \((error as? DroidDeckError)?.message ?? error.localizedDescription)")
            }
        }

        // Files removed from the Mac folder.
        let removed = index.keys.filter { local[$0] == nil }
        for rel in removed {
            guard let entry = index[rel] else { continue }
            if settings.propagateDeletions {
                do {
                    try await adb.remove(serial, path: entry.remotePath)
                    if SharedFolderRouting.isMedia(rel) { try await adb.scanMedia(serial, path: entry.remotePath) }
                } catch {
                    errors.append("\(rel): \((error as? DroidDeckError)?.message ?? error.localizedDescription)")
                    continue
                }
            }
            index[rel] = nil
        }
        saveIndex()
        status.syncedFiles = index.count
        status.lastError = errors.isEmpty ? nil : errors.prefix(3).joined(separator: "\n")
        if !changed.isEmpty || !removed.isEmpty {
            log.info("sync", "\(deviceName): pushed \(changed.count - errors.count), removed \(settings.propagateDeletions ? removed.count : 0)")
        }
    }

    private func scanLocal() -> [String: (size: Int64, modified: Date)] {
        var result: [String: (Int64, Date)] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: localRoot, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        let base = localRoot.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            var rel = url.standardizedFileURL.path
            guard rel.hasPrefix(base + "/") else { continue }
            rel.removeFirst(base.count + 1)
            if SharedFolderRouting.shouldIgnore(rel) { continue }
            result[rel] = (Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        return result
    }

    private func saveIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(index) {
            try? SafeFileOperations.writeAtomically(data, to: indexURL, permissions: 0o600)
        }
    }

    private func publish() { onStatus(status) }

    public func update(settings: SharedFolderSettings) {
        self.settings = settings
    }
}

/// Coordinates sync engines for all devices with a shared folder enabled.
@MainActor
@Observable
public final class SharedFolderService {
    public private(set) var statuses: [String: SharedFolderSyncEngine.Status] = [:]
    private var engines: [String: SharedFolderSyncEngine] = [:]
    private let devices: DeviceManager
    private var observeTask: Task<Void, Never>?

    public init(devices: DeviceManager) {
        self.devices = devices
    }

    public func defaultFolder(for device: ManagedDevice) -> URL {
        devices.preferences.sharedFoldersDirectory.appending(path: device.displayName)
    }

    /// Enables syncing for a device, creating its Finder folder.
    public func enable(_ name: String, layout: SharedFolderLayout = .byMediaType) {
        guard let device = devices.device(named: name) else { return }
        let path = device.metadata.sharedFolder?.localPath ?? defaultFolder(for: device).path
        devices.updateMetadata(name) {
            $0.sharedFolder = SharedFolderSettings(enabled: true, localPath: path, layout: layout,
                                                   propagateDeletions: $0.sharedFolder?.propagateDeletions ?? false)
        }
        reconcile()
    }

    public func disable(_ name: String) {
        devices.updateMetadata(name) { $0.sharedFolder?.enabled = false }
        reconcile()
    }

    public func update(_ name: String, _ change: (inout SharedFolderSettings) -> Void) {
        devices.updateMetadata(name) { meta in
            if var settings = meta.sharedFolder {
                change(&settings)
                meta.sharedFolder = settings
            }
        }
        if let settings = devices.device(named: name)?.metadata.sharedFolder, let engine = engines[name] {
            Task { await engine.update(settings: settings); await engine.scheduleSync() }
        }
    }

    public func syncNow(_ name: String) {
        guard let engine = engines[name] else { return }
        Task { await engine.sync() }
    }

    /// Keeps engines in line with device metadata and running state. Call after refreshes.
    public func reconcile() {
        guard let adb = devices.adb else { return }
        for device in devices.devices {
            guard let settings = device.metadata.sharedFolder, settings.enabled else {
                if let engine = engines.removeValue(forKey: device.id) { Task { await engine.deactivate() } }
                continue
            }
            let engine: SharedFolderSyncEngine
            if let existing = engines[device.id] {
                engine = existing
            } else {
                let name = device.id
                let service = self
                engine = SharedFolderSyncEngine(deviceName: name, settings: settings, adb: adb,
                                                indexDirectory: devices.paths.syncIndexes) { status in
                    Task { @MainActor in service.statuses[name] = status }
                }
                engines[name] = engine
                Task { try? await engine.activate() }
            }
            let serial: String? = device.state.isRunning ? device.instance?.adbSerial : nil
            Task { await engine.deviceAvailable(serial: serial) }
        }
    }

    /// Reconciles after every device refresh (event-driven), not on a timer.
    public func startObserving() {
        observeTask?.cancel()
        let previous = devices.onRefresh
        devices.onRefresh = { [weak self] in
            previous?()
            self?.reconcile()
        }
        reconcile()
    }
}
