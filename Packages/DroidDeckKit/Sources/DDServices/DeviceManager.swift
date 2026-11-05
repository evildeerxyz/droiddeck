import Foundation
import Observation
import DDCore
import DDPlatform
import DDPersistence
import DDAndroidSDK
import DDADB
import DDRuntime
import DDEmulatorGRPC

/// A virtual device as presented to the UI: runtime record + DroidDeck metadata + live state.
public struct ManagedDevice: Identifiable, Equatable, Sendable {
    public var device: VirtualDevice
    public var metadata: DeviceMetadata
    public var state: DeviceLifecycleState
    public var instance: RunningInstance?
    public var capabilities: CapabilityReport

    public var isPaused = false

    public var id: String { device.name }
    /// The name chosen in DroidDeck, or the AVD's own display name.
    public var displayName: String {
        let chosen = metadata.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return chosen.isEmpty ? device.displayName : chosen
    }
    public var group: String? { metadata.group }
    public var statusLabel: String { isPaused && state.isRunning ? "Paused" : state.label }
}

/// A device reachable through adb that DroidDeck does not run (physical phones, other emulators).
public struct ConnectedDevice: Identifiable, Equatable, Sendable {
    public var adb: ADBDevice
    public var capabilities: CapabilityReport
    public var title: String {
        if let model = adb.model { return model.replacingOccurrences(of: "_", with: " ") }
        return adb.serial
    }
    public var kindDescription: String {
        if adb.isEmulatorSerial { return "Emulator not managed by DroidDeck" }
        if adb.isNetworkDevice { return "Wi-Fi debugging" }
        return "USB device"
    }
    public var id: String { adb.serial }
}

/// Owns the device registry and lifecycle. Views call these methods; they never launch processes.
@MainActor
@Observable
public final class DeviceManager {
    public private(set) var detection: RuntimeDetection?
    public private(set) var adapter: AndroidEmulatorAdapter?
    public private(set) var devices: [ManagedDevice] = []
    public private(set) var connectedDevices: [ConnectedDevice] = []
    public private(set) var unmanagedEmulators: [RunningInstance] = []
    public private(set) var isBootstrapping = false
    public private(set) var bootstrapError: DroidDeckError?
    public private(set) var lastRefresh: Date?

    public let tasks: TaskCenter
    public let paths: AppPaths
    private let registryStore: JSONDocumentStore<[String: DeviceMetadata]>
    private let preferencesStore: JSONDocumentStore<AppPreferences>
    public private(set) var preferences = AppPreferences()
    private var metadata: [String: DeviceMetadata] = [:]
    private var transitions: [String: DeviceLifecycleState] = [:]
    private var pollTask: Task<Void, Never>?
    private var trackTask: Task<Void, Never>?
    private var monitors: [DirectoryMonitor] = []
    private var trackedADBDevices: [ADBDevice]?
    private var refreshScheduled = false
    private var isRefreshing = false
    /// Devices whose virtual machine is paused (no guest CPU use).
    public private(set) var pausedDevices: Set<String> = []
    /// Devices whose screen DroidDeck turned off because no window showed them; woken when shown again.
    public private(set) var asleepOffScreen: Set<String> = []
    /// Devices with a DroidDeck window visible right now (reported by the display view).
    private var onScreen: Set<String> = []
    private var sleepTimers: [String: Task<Void, Never>] = [:]
    /// How long a device stays awake after its window is closed, hidden or covered.
    public static let offScreenSleepDelay: Duration = .seconds(30)
    public private(set) var appActive = true
    public private(set) var power = PowerConditions.current()
    /// Called after each refresh so dependent services react to changes instead of polling.
    public var onRefresh: (@MainActor () -> Void)?

    public init(paths: AppPaths = AppPaths(), tasks: TaskCenter? = nil) {
        self.paths = paths
        self.tasks = tasks ?? TaskCenter(historyStore: OperationHistoryStore(url: paths.history))
        registryStore = JSONDocumentStore(url: paths.registry, default: { [:] })
        preferencesStore = JSONDocumentStore(url: paths.preferences, default: { AppPreferences() })
    }

    public var sdk: SDKInstallation? { adapter?.installation }
    public var adb: ADBClient? { adapter?.adb }
    public var host: HostEnvironment { adapter?.host ?? .current() }

    public var groups: [String] {
        Array(Set(devices.compactMap(\.group))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public var runningDevices: [ManagedDevice] { devices.filter { $0.instance != nil } }

    public func device(named name: String) -> ManagedDevice? { devices.first { $0.id == name } }

    // MARK: Bootstrap

    public func bootstrap() async {
        isBootstrapping = true
        defer { isBootstrapping = false }
        preferences = await preferencesStore.load()
        metadata = await registryStore.load()
        let avdHome = preferences.avdHomeOverride.map { URL(fileURLWithPath: $0) }
        guard let sdk = await SDKLocator.locate(preferredRoot: preferences.sdkPathOverride.map { URL(fileURLWithPath: $0) },
                                                avdHome: avdHome) else {
            bootstrapError = DroidDeckError(
                .sdkMissing, "No Android SDK was found.",
                recovery: "Install Android Studio (it installs the SDK in ~/Library/Android/sdk), or choose your SDK folder in Settings.")
            adapter = nil
            detection = RuntimeDetection(runtimeName: "Android Emulator", host: .current(), installation: nil, checks: [
                CompatibilityCheck(id: "sdk", title: "Android SDK", status: .error, detail: "Not found.",
                                   recovery: "Install Android Studio or set the SDK location in Settings."),
            ])
            return
        }
        do {
            let adapter = try AndroidEmulatorAdapter(installation: sdk)
            self.adapter = adapter
            bootstrapError = nil
            detection = await adapter.detect()
            try? await adapter.adb.startServer()
            await refresh()
            log.info("app", "Using Android SDK at \(sdk.root.path), AVD home \(sdk.avdHome.path)")
        } catch let error as DroidDeckError {
            bootstrapError = error
        } catch {
            bootstrapError = DroidDeckError(.sdkMissing, error.localizedDescription)
        }
    }

    public func updatePreferences(_ change: (inout AppPreferences) -> Void) async {
        var updated = preferences
        change(&updated)
        let sdkChanged = updated.sdkPathOverride != preferences.sdkPathOverride || updated.avdHomeOverride != preferences.avdHomeOverride
        preferences = updated
        try? await preferencesStore.save(updated)
        if sdkChanged { await bootstrap() }
        for device in devices { reconcileSleep(device.id) }
    }

    public func redetect() async {
        guard let adapter else { return await bootstrap() }
        detection = await adapter.detect()
    }

    /// Starts event-driven monitoring with a slow fallback poll.
    public func startMonitoring() {
        stopMonitoring()
        startTrackingADB()
        let schedule: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        if let monitor = DirectoryMonitor(url: EmulatorDiscovery.directory, onChange: schedule) { monitors.append(monitor) }
        if let home = sdk?.avdHome, let monitor = DirectoryMonitor(url: home, onChange: schedule) { monitors.append(monitor) }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.power = PowerConditions.current()
                await self.refresh()
                try? await Task.sleep(for: self.refreshPolicy.fallbackInterval)
            }
        }
    }

    public func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        trackTask?.cancel()
        trackTask = nil
        monitors.forEach { $0.cancel() }
        monitors = []
    }

    public var refreshPolicy: RefreshPolicy {
        RefreshPolicy(appActive: appActive, hasTransitions: !transitions.filter { $0.value.isBusy }.isEmpty, power: power)
    }

    /// The UI reports activation so background refreshes slow down while DroidDeck is not in front.
    public func setAppActive(_ active: Bool) {
        appActive = active
        power = PowerConditions.current()
        if active { scheduleRefresh() }
    }

    private func startTrackingADB() {
        trackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let adb = self?.adb else { return }
                do {
                    for try await list in adb.trackDevices() {
                        self?.trackedADBDevices = list
                        self?.scheduleRefresh()
                    }
                } catch {}
                self?.trackedADBDevices = nil
                // The adb server restarted or is not running yet; reconnect shortly.
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Coalesces bursts of events into one refresh.
    public func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.refreshScheduled = false
            await self?.refresh()
        }
    }

    // MARK: Refresh

    public func refresh() async {
        guard let adapter, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let virtualDevices = await adapter.devices()
        let instances = await adapter.runningInstances()
        let adbDevices: [ADBDevice]
        if let tracked = trackedADBDevices {
            adbDevices = tracked
        } else {
            adbDevices = (try? await adapter.adb.devices()) ?? []
        }

        var managed: [ManagedDevice] = []
        var claimedSerials = Set<String>()
        for device in virtualDevices {
            let target = SafeFileOperations.canonical(device.avd.directory).path
            let instance = instances.first { $0.avdDirectory.map { SafeFileOperations.canonical($0).path } == target }
            if let instance { claimedSerials.insert(instance.adbSerial) }
            let meta = metadata[device.name] ?? DeviceMetadata(avdName: device.name, displayMode: preferences.defaultDisplayMode)
            var state: DeviceLifecycleState = instance.map { .running($0.details) } ?? .stopped
            if instance == nil { pausedDevices.remove(device.name) }
            if let transition = transitions[device.name] {
                switch transition {
                case .starting, .stopping: state = transition
                case .failed where instance == nil: state = transition
                default: break
                }
            }
            let caps = await adapter.capabilities(for: device, instance: instance)
            managed.append(ManagedDevice(device: device, metadata: meta, state: state, instance: instance, capabilities: caps,
                                         isPaused: pausedDevices.contains(device.name)))
        }
        devices = managed
        unmanagedEmulators = instances.filter { !claimedSerials.contains($0.adbSerial) }
        claimedSerials.formUnion(unmanagedEmulators.map(\.adbSerial))
        connectedDevices = adbDevices
            .filter { !claimedSerials.contains($0.serial) }
            .map { ConnectedDevice(adb: $0, capabilities: ADBDeviceCapabilities.report(for: $0)) }
        lastRefresh = Date()
        for device in devices { reconcileSleep(device.id) }
        onRefresh?()
    }

    private func setTransition(_ name: String, _ state: DeviceLifecycleState?) {
        transitions[name] = state
        if let index = devices.firstIndex(where: { $0.id == name }), let state {
            devices[index].state = state
        }
    }

    // MARK: Metadata

    public func metadata(for name: String) -> DeviceMetadata {
        metadata[name] ?? DeviceMetadata(avdName: name, displayMode: preferences.defaultDisplayMode)
    }

    public func updateMetadata(_ name: String, _ change: (inout DeviceMetadata) -> Void) {
        var meta = metadata(for: name)
        change(&meta)
        metadata[name] = meta
        if let index = devices.firstIndex(where: { $0.id == name }) { devices[index].metadata = meta }
        persistMetadata()
        reconcileSleep(name)
    }

    private func persistMetadata() {
        let snapshot = metadata
        let store = registryStore
        Task { try? await store.save(snapshot) }
    }

    // MARK: Lifecycle

    public func start(_ name: String, options overrides: LaunchOptions? = nil) {
        guard let adapter, let managed = device(named: name) else { return }
        guard managed.capabilities.supports(.startDevice) else { return }
        var options = overrides ?? LaunchOptions()
        if overrides == nil { options.displayMode = managed.metadata.displayMode }
        options.bootTimeout = .seconds(preferences.bootTimeoutSeconds)
        setTransition(name, .starting(phase: .launching))
        updateMetadata(name) { $0.lastStartedAt = Date() }
        let device = managed.device
        let manager = self
        let launchOptions = options
        tasks.run("Start \(managed.displayName)", device: name) { reporter in
            do {
                _ = try await adapter.start(device, options: launchOptions) { phase in
                    reporter.update(detail: phase.rawValue)
                    Task { @MainActor in manager.setTransition(name, .starting(phase: phase)) }
                }
                await MainActor.run { manager.transitions[name] = nil }
            } catch let error as DroidDeckError {
                await MainActor.run { manager.setTransition(name, error.kind == .cancelled ? nil : .failed(message: error.message)) }
                throw error
            } catch {
                await MainActor.run { manager.setTransition(name, nil) }
                throw error
            }
            await manager.refresh()
        }
    }

    public func stop(_ name: String, force: Bool = false) {
        guard let adapter, let managed = device(named: name), let instance = managed.instance else { return }
        setTransition(name, .stopping)
        let manager = self
        tasks.run("\(force ? "Force stop" : "Stop") \(managed.displayName)", device: name, cancellable: false) { _ in
            defer { Task { @MainActor in manager.transitions[name] = nil; await manager.refresh() } }
            try await adapter.stop(instance, force: force)
        }
    }

    public func stopUnmanaged(_ instance: RunningInstance) {
        guard let adapter else { return }
        let manager = self
        tasks.run("Stop \(instance.avdName)", cancellable: false) { _ in
            try await adapter.stop(instance, force: false)
            await manager.refresh()
        }
    }

    public func startAll(_ names: [String]) { names.forEach { start($0) } }
    public func stopAll(_ names: [String]) { names.forEach { stop($0) } }

    /// Stops every running device DroidDeck manages and waits for them to exit (used on quit).
    public func stopEverything() async {
        guard let adapter else { return }
        await withTaskGroup(of: Void.self) { group in
            for device in runningDevices {
                guard let instance = device.instance else { continue }
                group.addTask { try? await adapter.stop(instance, force: false) }
            }
        }
    }

    public func create(_ configuration: DeviceConfiguration, profile: DeviceProfile?, image: SystemImage,
                       group: String?, startAfterCreation: Bool) async throws {
        guard let adapter else { throw DroidDeckError(.sdkMissing, "The Android SDK is not available.") }
        _ = try await tasks.perform("Create \(configuration.displayName)", device: configuration.avdName) { _ in
            try await adapter.create(configuration, profile: profile, image: image)
        }
        updateMetadata(configuration.avdName) {
            $0.createdByDroidDeck = true
            $0.createdAt = Date()
            $0.group = group
            $0.displayMode = preferences.defaultDisplayMode
        }
        await refresh()
        if startAfterCreation { start(configuration.avdName) }
    }

    public func update(_ name: String, configuration: DeviceConfiguration, profile: DeviceProfile?) async throws {
        guard let adapter, let managed = device(named: name) else { return }
        _ = try await tasks.perform("Update \(managed.displayName)", device: name) { _ in
            try await adapter.update(managed.device, to: configuration, profile: profile)
        }
        await refresh()
    }

    public func clone(_ name: String, as newName: String, displayName: String, includeUserData: Bool) async throws {
        guard let adapter, let managed = device(named: name) else { return }
        _ = try await tasks.perform("Duplicate \(managed.displayName)", device: name) { _ in
            try await adapter.clone(managed.device, as: newName, displayName: displayName, includeUserData: includeUserData)
        }
        let source = metadata(for: name)
        updateMetadata(newName) {
            $0.group = source.group
            $0.createdByDroidDeck = true
            $0.createdAt = Date()
            $0.displayMode = source.displayMode
            $0.keyBindings = source.keyBindings
        }
        await refresh()
    }

    public func delete(_ name: String) async throws {
        guard let adapter, let managed = device(named: name) else { return }
        _ = try await tasks.perform("Delete \(managed.displayName)", device: name) { _ in
            try await adapter.delete(managed.device)
        }
        metadata[name] = nil
        persistMetadata()
        await refresh()
    }

    /// Rewrites a unit-suffixed hw.ramSize the emulator ignores ("2G") as plain megabytes.
    public func repairRAMFormat(_ name: String) async throws {
        guard let adapter, let managed = device(named: name) else { return }
        guard managed.instance == nil else { throw DroidDeckError(.deviceBusy, "Stop the device first.") }
        try adapter.repository.normalizeRAMValue(managed.device.avd)
        await refresh()
    }

    /// Pauses the virtual machine: Android freezes and the emulator stops using CPU.
    public func pause(_ name: String) {
        guard let adb, let instance = device(named: name)?.instance else { return }
        let manager = self
        tasks.run("Pause \(device(named: name)?.displayName ?? name)", device: name, cancellable: false) { _ in
            _ = try await adb.emu(instance.adbSerial, ["avd", "pause"])
            await MainActor.run { _ = manager.pausedDevices.insert(name) }
        }
    }

    public func resume(_ name: String) {
        guard let adb, let instance = device(named: name)?.instance else { return }
        let manager = self
        tasks.run("Resume \(device(named: name)?.displayName ?? name)", device: name, cancellable: false) { _ in
            _ = try await adb.emu(instance.adbSerial, ["avd", "resume"])
            await MainActor.run { _ = manager.pausedDevices.remove(name) }
        }
    }

    // MARK: Tags

    /// Every tag in use, one per name, sorted by name.
    public var allTags: [DeviceTag] {
        var library: [String: DeviceTag] = [:]
        for device in devices {
            for tag in device.metadata.tags where library[tag.id] == nil { library[tag.id] = tag }
        }
        return library.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func devices(taggedWith id: String) -> [ManagedDevice] {
        devices.filter { $0.metadata.tags.contains { $0.id == id } }
    }

    /// Adds a tag to devices. A name that already exists keeps its color.
    public func addTag(_ tag: DeviceTag, to names: [String]) {
        let library = allTags
        for name in names { updateMetadata(name) { $0.tags = $0.tags.adding(tag, library: library) } }
    }

    public func removeTag(_ id: String, from names: [String]) {
        for name in names { updateMetadata(name) { $0.tags = $0.tags.removing(id) } }
    }

    /// Renames and/or recolors a tag on every device. Renaming onto another tag's name merges into it.
    public func updateTag(_ id: String, name: String? = nil, color: DeviceTag.Color? = nil) {
        let target = name.map(DeviceTag.key)
        let existingColor = target.flatMap { key in key == id ? nil : allTags.first { $0.id == key }?.color }
        for device in devices(taggedWith: id) {
            updateMetadata(device.id) { $0.tags = $0.tags.updating(id, name: name, color: existingColor ?? color) }
        }
    }

    public func deleteTag(_ id: String) {
        removeTag(id, from: devices(taggedWith: id).map(\.id))
    }

    // MARK: Display sleep for devices that aren't on screen

    /// Called by the display view when a device's window becomes visible, or is hidden, covered or closed.
    /// `justOpened` marks the first appearance of a display: its screen may have been turned off in an
    /// earlier DroidDeck session, so it is checked and woken (like picking up a phone).
    public func setOnScreen(_ name: String, _ visible: Bool, justOpened: Bool = false) {
        if visible { onScreen.insert(name) } else { onScreen.remove(name) }
        // A device on screen always gets normal priority back (it may have been backgrounded by an
        // earlier DroidDeck session that quit while the device slept).
        if visible, let pid = device(named: name)?.instance?.pid { ProcessPriority.setBackground(pid, false) }
        if visible, justOpened, !asleepOffScreen.contains(name) { wakeIfScreenOff(name) }
        reconcileSleep(name)
    }

    /// A device nobody is looking at sleeps its display, like a phone in a pocket: video apps such as
    /// TikTok stop playing and rendering, and the emulator drops from hundreds of percent CPU to a few
    /// (measured: ~200%+ busy with the screen on, 5–30% with it off). Apps stay open and VPNs stay
    /// connected; the device wakes as soon as its window is shown. Idempotent, so refresh can call it.
    func reconcileSleep(_ name: String) {
        guard let managed = device(named: name), managed.state.isRunning, let instance = managed.instance else {
            cancelSleep(name)
            asleepOffScreen.remove(name)
            return
        }
        let allowed = preferences.sleepDevicesNotOnScreen && !managed.metadata.keepAwakeInBackground
            && instance.displayMode == .embedded
        if onScreen.contains(name) || !allowed {
            cancelSleep(name)
            if asleepOffScreen.remove(name) != nil, !managed.isPaused { wakeDisplay(instance) }
            return
        }
        guard !managed.isPaused, !asleepOffScreen.contains(name), sleepTimers[name] == nil else { return }
        let manager = self
        sleepTimers[name] = Task {
            try? await Task.sleep(for: Self.offScreenSleepDelay)
            guard !Task.isCancelled else { return }
            await manager.sleepDisplay(name)
        }
    }

    private func cancelSleep(_ name: String) {
        sleepTimers.removeValue(forKey: name)?.cancel()
    }

    private func sleepDisplay(_ name: String) async {
        sleepTimers[name] = nil
        guard let adb, let managed = device(named: name), managed.state.isRunning, !managed.isPaused,
              !onScreen.contains(name), let instance = managed.instance else { return }
        do {
            try await adb.keyevent(instance.adbSerial, 223) // KEYCODE_SLEEP: screen off even if an app keeps it awake
            asleepOffScreen.insert(name)
            // Android does its heavy maintenance (app optimization, updates) when idle with the screen off
            // and "charging", which an emulator always is. Background priority keeps that on the
            // efficiency cores instead of heating the Mac.
            let backgrounded = ProcessPriority.setBackground(instance.pid, true)
            log.info("power", "Turned off the screen of \(name): no window shows it\(backgrounded ? "; background priority" : "")")
        } catch {
            log.info("power", "Could not turn off the screen of \(name): \(error)")
        }
    }

    private func wakeIfScreenOff(_ name: String) {
        guard let adb, let managed = device(named: name), managed.state.isRunning, !managed.isPaused,
              let serial = managed.instance?.adbSerial else { return }
        let manager = self
        Task {
            let power = (try? await adb.shell(serial, "dumpsys power | grep -m1 mWakefulness=", timeout: .seconds(10), allowFailure: true)) ?? ""
            if power.contains("Asleep") || power.contains("Dozing"), let instance = manager.device(named: name)?.instance {
                manager.wakeDisplay(instance)
            }
        }
    }

    private func wakeDisplay(_ instance: RunningInstance) {
        guard let adb else { return }
        ProcessPriority.setBackground(instance.pid, false) // full speed before waking, so it wakes instantly
        let serial = instance.adbSerial
        Task {
            try? await adb.keyevent(serial, 224) // KEYCODE_WAKEUP
            _ = try? await adb.shell(serial, "wm dismiss-keyguard", timeout: .seconds(10), allowFailure: true)
        }
    }

    public func skinIsBroken(_ name: String) -> Bool {
        guard let sdk, let managed = device(named: name) else { return false }
        return adapter?.repository.skinConfigurationIsBroken(managed.device.avd, sdkRoot: sdk.root) ?? false
    }

    public func repairSkin(_ name: String) async throws {
        guard let adapter, let sdk, let managed = device(named: name) else { return }
        guard managed.instance == nil else { throw DroidDeckError(.deviceBusy, "Stop the device first.") }
        try adapter.repository.repairSkin(managed.device.avd, sdkRoot: sdk.root)
        if case .failed = managed.state { setTransition(name, nil) }
        await refresh()
    }

    // MARK: Snapshots

    public func snapshots(_ name: String) async -> [SnapshotInfo] {
        guard let adapter, let managed = device(named: name) else { return [] }
        return await adapter.snapshots(of: managed.device)
    }

    public func saveSnapshot(_ name: String, snapshot: String) async throws {
        guard let adapter, let instance = device(named: name)?.instance else { return }
        _ = try await tasks.perform("Save snapshot \(snapshot)", device: name) { _ in
            try await adapter.saveSnapshot(snapshot, on: instance)
        }
    }

    public func loadSnapshot(_ name: String, snapshot: String) async throws {
        guard let adapter, let instance = device(named: name)?.instance else { return }
        _ = try await tasks.perform("Restore snapshot \(snapshot)", device: name) { _ in
            try await adapter.loadSnapshot(snapshot, on: instance)
        }
    }

    public func deleteSnapshot(_ name: String, snapshot: String) async throws {
        guard let adapter, let managed = device(named: name) else { return }
        _ = try await tasks.perform("Delete snapshot \(snapshot)", device: name) { _ in
            try await adapter.deleteSnapshot(snapshot, of: managed.device, instance: managed.instance)
        }
    }

    // MARK: Text, keyboard, identity, storage

    /// Sets the Mac clipboard text on the device and pastes it into the focused field.
    public func pasteToDevice(_ name: String, text: String) {
        guard let adb, let instance = device(named: name)?.instance else { return }
        let serial = instance.adbSerial
        let displayName = device(named: name)?.displayName ?? name
        let target = name
        let manager = self
        tasks.run("Paste text to \(displayName)", device: name) { _ in
            if let controller = await manager.controller(for: target) {
                try? await controller.setClipboard(text)
            }
            try await adb.keyevent(serial, 279) // KEYCODE_PASTE
        }
    }

    /// Copies files and folders from the Mac into the device's shared storage: photos and videos
    /// where the Gallery (and app pickers) look, everything else in Downloads. Media is indexed so
    /// it shows up immediately. Tracked in Activity; returns what was copied.
    public func uploadFiles(_ urls: [URL], to name: String) async throws -> UploadPlan {
        guard let adb, let managed = device(named: name), let instance = managed.instance else {
            throw DroidDeckError(.deviceBusy, "Start the device to upload files.")
        }
        let serial = instance.adbSerial
        return try await tasks.perform("Upload files to \(managed.displayName)", device: name) { reporter in
            let plan = UploadPlan(urls: urls)
            guard !plan.items.isEmpty else {
                throw DroidDeckError(.fileOperationFailed, "There was nothing to upload.",
                                     recovery: "Hidden files and unfinished downloads are skipped.")
            }
            var createdFolders = Set<String>()
            for (index, item) in plan.items.enumerated() {
                try Task.checkCancellation()
                reporter.update(progress: Double(index) / Double(plan.items.count), detail: item.local.lastPathComponent)
                let folder = (item.remote as NSString).deletingLastPathComponent
                if createdFolders.insert(folder).inserted { try await adb.makeDirectory(serial, path: folder) }
                try await adb.push(serial, local: item.local, remote: item.remote)
                if item.kind != .other { try? await adb.scanMedia(serial, path: item.remote) }
            }
            reporter.update(progress: 1)
            return plan
        }
    }

    /// Hardware keyboard controls whether typing (and the Mac keyboard) reaches the device.
    /// Verified: with it off the emulator ignores key events. Requires the device to be stopped.
    public func setHardwareKeyboard(_ name: String, enabled: Bool) async throws {
        guard let adapter, let managed = device(named: name) else { return }
        guard managed.device.configuration.hardwareKeyboard != enabled else { return }
        guard managed.instance == nil else { throw DroidDeckError(.deviceBusy, "Stop the device first.") }
        var newConfig = managed.device.configuration
        newConfig.hardwareKeyboard = enabled
        let config = newConfig
        let device = managed.device
        _ = try await tasks.perform("\(enabled ? "Enable" : "Disable") keyboard on \(managed.displayName)", device: name) { _ in
            try await adapter.update(device, to: config, profile: nil)
        }
        await refresh()
    }

    /// Mac GPU (fast, a few percent CPU) or software rendering (slower and much hungrier, but avoids
    /// GPU-path glitches such as occasional static in TikTok videos). Needs the device stopped. The Quick
    /// Boot snapshot is discarded because a snapshot saved under one renderer can't be restored under the other.
    public func setGPUMode(_ name: String, _ mode: GPUMode) async throws {
        guard let adapter, let managed = device(named: name) else { return }
        guard managed.device.configuration.gpuMode != mode else { return }
        guard managed.instance == nil else { throw DroidDeckError(.deviceBusy, "Stop the device first.") }
        var newConfig = managed.device.configuration
        newConfig.gpuMode = mode
        let config = newConfig
        let device = managed.device
        _ = try await tasks.perform("Use \(mode == .software ? "software rendering" : "the Mac GPU") on \(managed.displayName)", device: name) { _ in
            try await adapter.update(device, to: config, profile: nil)
            try? adapter.repository.deleteQuickBootSnapshot(device.avd)
        }
        await refresh()
    }

    /// Cosmetic: sets the user-facing "Device name" in Android Settings (the same name any phone
    /// owner can set). It does NOT change ro.product.model or any hardware/build identifier.
    public func setAndroidDeviceName(_ name: String, to newName: String) {
        guard let adb, let instance = device(named: name)?.instance else { return }
        let serial = instance.adbSerial
        let quoted = ShellQuote.quote(newName)
        tasks.run("Set device name to \(newName)", device: name) { _ in
            try await adb.shell(serial, "settings put global device_name \(quoted); settings put secure bluetooth_name \(quoted); settings put system device_name \(quoted)",
                                timeout: .seconds(15), allowFailure: true)
        }
    }

    public func storageBreakdown(_ name: String) async -> AVDRepository.StorageBreakdown? {
        guard let adapter, let managed = device(named: name) else { return nil }
        let repo = adapter.repository
        let avd = managed.device.avd
        return await Task.detached(priority: .utility) { repo.storage(of: avd) }.value
    }

    /// Reclaims disk space without losing apps or data: drops the Quick Boot snapshot and/or
    /// the removable SD card. The device must be stopped.
    public func reclaimSpace(_ name: String, quickBoot: Bool, sdCard: Bool) async throws {
        guard let adapter, let managed = device(named: name) else { return }
        guard managed.instance == nil else { throw DroidDeckError(.deviceBusy, "Stop the device first.") }
        _ = try await tasks.perform("Reclaim space on \(managed.displayName)", device: name) { _ in
            if quickBoot { try adapter.repository.deleteQuickBootSnapshot(managed.device.avd) }
            if sdCard { try adapter.repository.removeSDCard(managed.device.avd) }
        }
        await refresh()
    }

    // MARK: Control

    public func controller(for name: String) async -> EmulatorControllerClient? {
        guard let adapter, let instance = device(named: name)?.instance else { return nil }
        return await adapter.controller(for: instance)
    }

    /// The adb serial for a managed device or a connected device id.
    public func serial(for id: String) -> String? {
        if let managed = device(named: id) { return managed.instance?.adbSerial }
        return connectedDevices.first { $0.id == id }?.adb.serial
    }

    public func capabilities(for id: String) -> CapabilityReport {
        device(named: id)?.capabilities ?? connectedDevices.first { $0.id == id }?.capabilities ?? CapabilityReport()
    }

    public func emulatorLogFile(_ name: String) async -> URL? {
        await adapter?.logFile(for: name)
    }
}
