import Foundation
import Testing
@testable import DDServices
import DDCore
import DDPersistence
import DDEmulatorGRPC
import DDRuntime

@Suite("Display geometry")
struct DisplayGeometryTests {
    // Pixel 9 Pro skin: 1408×2974 frame, 1280×2856 display at (60, 61).
    let frame = DeviceFrameGeometry(frameSize: CGSize(width: 1408, height: 2974),
                                    display: CGRect(x: 60, y: 61, width: 1280, height: 2856), rotation: .portrait)

    @Test func portraitKeepsSkinCoordinates() {
        #expect(frame.rotatedDisplay == CGRect(x: 60, y: 61, width: 1280, height: 2856))
        #expect(frame.containerSize == CGSize(width: 1408, height: 2974))
    }

    @Test("Landscape openings stay inside the rotated frame with the same margins",
          arguments: [EmulatorSkinRotation.landscape, .reverseLandscape, .reversePortrait])
    func rotatedOpenings(rotation: EmulatorSkinRotation) {
        var g = frame
        g.rotation = rotation
        let r = g.rotatedDisplay
        let c = g.containerSize
        #expect(r.minX >= 0 && r.minY >= 0 && r.maxX <= c.width && r.maxY <= c.height)
        #expect(Set([r.width, r.height]) == Set([1280, 2856]))
        // Margins are a permutation of the portrait margins (60, 61, 68, 57).
        let margins = [r.minX, r.minY, c.width - r.maxX, c.height - r.maxY].map { Int($0) }.sorted()
        #expect(margins == [57, 60, 61, 68])
    }

    @Test func scaleFitsTheLimitingDimension() {
        #expect(abs(frame.scale(toFit: CGSize(width: 704, height: 5000)) - 0.5) < 0.0001)
    }

    @Test("Touch mapping round-trips the panel corners for every rotation", arguments: [
        EmulatorSkinRotation.portrait, .landscape, .reversePortrait, .reverseLandscape,
    ])
    func touchCorners(rotation: EmulatorSkinRotation) {
        let g = DisplayGeometry(deviceWidth: 1080, deviceHeight: 2400, rotation: rotation)
        let corners = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)].map { g.devicePoint(normalizedX: $0.0, normalizedY: $0.1) }
        // Each displayed corner maps to a distinct panel corner.
        let unique = Set(corners.map { "\($0.x),\($0.y)" })
        #expect(unique.count == 4)
        #expect(corners.allSatisfy { ($0.x == 0 || $0.x == 1079) && ($0.y == 0 || $0.y == 2399) })
    }
}

@Suite("Refresh policy")
struct RefreshPolicyTests {
    @Test func slowsDownInBackgroundAndOnBattery() {
        let ac = PowerConditions(onBattery: false, lowPowerMode: false)
        let battery = PowerConditions(onBattery: true, lowPowerMode: false)
        #expect(RefreshPolicy(appActive: true, hasTransitions: true, power: battery).fallbackInterval == .seconds(2))
        #expect(RefreshPolicy(appActive: true, hasTransitions: false, power: ac).fallbackInterval == .seconds(15))
        #expect(RefreshPolicy(appActive: true, hasTransitions: false, power: battery).fallbackInterval == .seconds(30))
        #expect(RefreshPolicy(appActive: false, hasTransitions: false, power: battery).fallbackInterval == .seconds(120))
        #expect(RefreshPolicy(appActive: false, hasTransitions: false, power: ac).metricsInterval(runningDevices: 3) == .seconds(60))
        #expect(RefreshPolicy(appActive: true, hasTransitions: false, power: ac).metricsInterval(runningDevices: 0) == .seconds(15))
    }
}

@Suite("Shared folder routing")
struct SharedFolderTests {
    @Test func mediaGoesWhereGalleryAndFilesLook() {
        #expect(SharedFolderRouting.remotePath(for: "trip/IMG_0001.HEIC", layout: .byMediaType) == "/sdcard/Pictures/DroidDeck/trip/IMG_0001.HEIC")
        #expect(SharedFolderRouting.remotePath(for: "clip.mov", layout: .byMediaType) == "/sdcard/Movies/DroidDeck/clip.mov")
        #expect(SharedFolderRouting.remotePath(for: "song.mp3", layout: .byMediaType) == "/sdcard/Music/DroidDeck/song.mp3")
        #expect(SharedFolderRouting.remotePath(for: "notes.pdf", layout: .byMediaType) == "/sdcard/Download/DroidDeck/notes.pdf")
        #expect(SharedFolderRouting.remotePath(for: "a/b.jpg", layout: .mirror) == "/sdcard/DroidDeck/a/b.jpg")
    }

    @Test func partialAndHiddenFilesAreSkipped() {
        #expect(SharedFolderRouting.shouldIgnore(".DS_Store"))
        #expect(SharedFolderRouting.shouldIgnore("video.mp4.crdownload"))
        #expect(SharedFolderRouting.shouldIgnore(".hidden/photo.jpg"))
        #expect(!SharedFolderRouting.shouldIgnore("Holiday/photo.jpg"))
    }

    @Test func uploadExpandsFoldersAndRoutesByType() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString)")
        let trip = root.appending(path: "Trip")
        try FileManager.default.createDirectory(at: trip.appending(path: "day2"), withIntermediateDirectories: true)
        for path in ["Trip/a.jpg", "Trip/day2/b.MP4", "Trip/.DS_Store", "Trip/c.mp4.crdownload", "notes.pdf", "song.m4a"] {
            try Data("x".utf8).write(to: root.appending(path: path))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = UploadPlan(urls: [trip, root.appending(path: "notes.pdf"), root.appending(path: "song.m4a"),
                                     root.appending(path: "missing.jpg")])
        #expect(plan.items.map(\.remote) == [
            "/sdcard/Movies/DroidDeck/Trip/day2/b.MP4",
            "/sdcard/Pictures/DroidDeck/Trip/a.jpg",
            "/sdcard/Download/DroidDeck/notes.pdf",
            "/sdcard/Music/DroidDeck/song.m4a",
        ])
        #expect(plan.items.map(\.kind) == [.visual, .visual, .other, .audio])
        #expect(plan.summary == "Added 4 files — photos & videos in Gallery › DroidDeck, audio in Music › DroidDeck, files in Files › Downloads › DroidDeck")
    }
}

@Suite("Automation trust")
struct AutomationTests {
    @Test func importedWorkflowsAreNeverApproved() throws {
        var workflow = Workflow(name: "Demo", steps: [.shell("rm -rf /sdcard/x"), .tap(x: 0.5, y: 0.5)], origin: .createdInDroidDeck)
        workflow.approve()
        let url = FileManager.default.temporaryDirectory.appending(path: "wf-\(UUID().uuidString).json")
        try workflow.exportData().write(to: url)
        let imported = try Workflow.importing(from: url)
        #expect(imported.origin == .imported)
        #expect(!imported.isApproved)
        #expect(imported.steps.first?.isSensitive == true)
    }

    @Test func editingInvalidatesApproval() {
        var workflow = Workflow(name: "Demo", steps: [.wait(seconds: 1)], origin: .createdInDroidDeck)
        workflow.approve()
        #expect(workflow.isApproved)
        workflow.steps.append(.shell("reboot"))
        #expect(!workflow.isApproved)
    }

    @Test func runnerRefusesUnapprovedWorkflows() async {
        let workflow = Workflow(name: "Imported", steps: [.screenshot], origin: .imported)
        let runner = WorkflowRunner(adb: .init(executable: URL(fileURLWithPath: "/usr/bin/false"), runner: .init()),
                                    controller: nil, screenshotDirectory: FileManager.default.temporaryDirectory)
        await #expect(throws: DroidDeckError.self) {
            try await runner.run(workflow, serial: "emulator-5554") { _, _ in }
        }
    }
}

@Suite("Network interpretation")
struct NetworkTests {
    @Test func parsesVPNFromDumpsys() {
        let text = """
          NetworkAgentInfo{network{100} ni{WIFI CONNECTED} lp{{InterfaceName: wlan0 DnsAddresses: [ /10.0.2.3,/10.0.2.4 ] }} nc{[ Transports: WIFI Capabilities: INTERNET&NOT_VPN ]}}
          NetworkAgentInfo{network{101} ni{VPN CONNECTED} lp{{InterfaceName: tun0 DnsAddresses: [ /103.86.96.100 ] }} nc{[ Transports: VPN Capabilities: INTERNET OwnerUid: 10170 ]}}
        """
        let summary = NetworkDiagnostics.parseConnectivity(text)
        #expect(summary.vpnActive)
        #expect(summary.vpnOwnerUID == "10170")
        #expect(summary.dnsServers == ["103.86.96.100"])
    }

    @Test func comparisonNeverOverclaimsIsolation() {
        func report(_ ip: String?, vpn: Bool) -> DeviceNetworkReport {
            DeviceNetworkReport(serial: "s", interfaces: [], hasTunnelInterface: vpn, vpnNetworkActive: vpn, vpnOwnerPackage: nil,
                                activeTransports: [], dnsServers: [], privateDNSMode: nil, installedVPNApps: [],
                                canReachInternet: true, canResolveNames: true, publicIP: ip, publicIPError: nil)
        }
        #expect(NetworkDiagnostics.comparison([report("1.1.1.1", vpn: true), report(nil, vpn: true)]).first?.contains("unverified") == true)
        #expect(NetworkDiagnostics.comparison([report("1.1.1.1", vpn: true), report("1.1.1.1", vpn: true)]).first?.contains("share") == true)
        let distinct = NetworkDiagnostics.comparison([report("1.1.1.1", vpn: true), report("2.2.2.2", vpn: false)])
        #expect(distinct.contains { $0.contains("point-in-time") })
        #expect(distinct.contains { $0.contains("Not every device") })
    }
}

@Suite("Persistence")
struct PersistenceTests {
    @Test func metadataSurvivesRoundTripAndToleratesMissingFields() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "dd-\(UUID().uuidString)/devices.json")
        let store = JSONDocumentStore<[String: DeviceMetadata]>(url: url, default: { [:] })
        var meta = DeviceMetadata(avdName: "A", group: "Work")
        meta.sharedFolder = SharedFolderSettings(enabled: true, localPath: "/tmp/x")
        meta.name = "TikTok 2"
        try await store.save(["A": meta])
        #expect(await store.load()["A"] == meta)
        try Data(#"{"B": {"avdName": "B"}}"#.utf8).write(to: url)
        let loaded = await store.load()
        #expect(loaded["B"]?.displayMode == .embedded)
        #expect(loaded["B"]?.showFrame == true)
        #expect(loaded["B"]?.name == nil)
    }

    @Test func corruptFilesAreKeptAsideNotOverwritten() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "preferences.json")
        try Data("{not json".utf8).write(to: url)
        let store = JSONDocumentStore<AppPreferences>(url: url, default: { AppPreferences() })
        #expect(await store.load() == AppPreferences())
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.contains("corrupt") })
    }
}

@Suite("Google Play detection")
struct GooglePlayTests {
    @Test("The licensing stub on Google APIs images is not the Play Store")
    func licenseStub() {
        #expect(!GooglePlayDiagnostics.isPlayStore(pmPathOutput: "package:/product/app/LicenseChecker/LicenseChecker.apk\n"))
        #expect(GooglePlayDiagnostics.isPlayStore(pmPathOutput: "package:/product/priv-app/Phonesky/Phonesky.apk\n"))
        #expect(GooglePlayDiagnostics.isPlayStore(pmPathOutput: "package:/data/app/~~x==/com.android.vending-y==/base.apk\n"))
        #expect(!GooglePlayDiagnostics.isPlayStore(pmPathOutput: ""))
    }
}

@Suite("Preferences store")
struct PreferencesStoreTests {
    @Test("Preferences round-trip and survive concurrent saves from several tasks")
    func concurrentSaves() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dd-prefs-\(UUID().uuidString)")
        let url = dir.appending(path: "preferences.json")
        let store = JSONDocumentStore<AppPreferences>(url: url, default: { AppPreferences() })
        var prefs = AppPreferences()
        prefs.onboardingCompleted = true
        prefs.sdkPathOverride = "/tmp/sdk with spaces"
        try await store.save(prefs)
        #expect(await store.load() == prefs)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    var p = AppPreferences()
                    p.bootTimeoutSeconds = 60 + i
                    try? await store.save(p)
                    _ = await store.load()
                }
            }
        }
        let data = try Data(contentsOf: url)
        #expect((try? JSONDecoder().decode(AppPreferences.self, from: data)) != nil, "file must always be valid JSON")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!files.contains { $0.contains("corrupt") })
    }
}

@Suite("Device tags")
struct DeviceTagTests {
    @Test func namesAreCleanedAndMatchIgnoringCase() {
        let tag = DeviceTag(name: "  Main   account ", color: .red)
        #expect(tag.name == "Main account")
        #expect(tag.id == DeviceTag.key("main ACCOUNT"))
        #expect(DeviceTag(name: String(repeating: "x", count: 40), color: .red).name.count == DeviceTag.maxLength)
        #expect(DeviceTag(name: "   ", color: .red).name.isEmpty)
    }

    @Test func addingSkipsDuplicatesAndKeepsTheLibraryColor() {
        let library = [DeviceTag(name: "Warm-up", color: .green)]
        let tags = [DeviceTag]()
            .adding(DeviceTag(name: "warm-up", color: .red), library: library)
            .adding(DeviceTag(name: "WARM-UP", color: .blue), library: library)
            .adding(DeviceTag(name: "", color: .blue))
        #expect(tags == [DeviceTag(name: "Warm-up", color: .green)])
    }

    @Test func renamingOntoAnExistingNameMerges() {
        let tags = [DeviceTag(name: "VPN", color: .blue), DeviceTag(name: "Main", color: .red)]
        let renamed = tags.updating(DeviceTag.key("VPN"), name: "main", color: .red)
        #expect(renamed == [DeviceTag(name: "main", color: .red)])
        let recolored = tags.updating(DeviceTag.key("Main"), color: .purple)
        #expect(recolored.last?.color == .purple)
        #expect(tags.removing(DeviceTag.key("vpn")).map(\.name) == ["Main"])
    }

    @Test func olderSavedDevicesDecodeWithDefaults() throws {
        let old = #"{"avdName":"Pixel_9_Pro","notes":"","createdByDroidDeck":true,"displayMode":"embedded","showFrame":true,"keyBindings":[],"keyMappingEnabled":false}"#
        let meta = try JSONDecoder().decode(DeviceMetadata.self, from: Data(old.utf8))
        #expect(meta.tags.isEmpty)
        #expect(meta.keepAwakeInBackground == false)

        var tagged = meta
        tagged.tags = [DeviceTag(name: "Main", color: .pink)]
        let roundTrip = try JSONDecoder().decode(DeviceMetadata.self, from: JSONEncoder().encode(tagged))
        #expect(roundTrip.tags == tagged.tags)

        let prefs = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"onboardingCompleted":true}"#.utf8))
        #expect(prefs.sleepDevicesNotOnScreen)
    }
}

@Suite("Quick Boot snapshot failures")
struct SnapshotFailureTests {
    // Lines from real emulator 37.2.12 logs on this Mac.
    @Test func corruptedSnapshotIsDetected() {
        let hungAfterRestore = """
        INFO         | Loading snapshot 'default_boot'...
        qemu-system-aarch64: Missing section footer for 0000:00:0b.0/goldfish_address_space, expecting: 0x18
        WARNING      | Error -22 while loading VM state
        WARNING      | Failed to load snapshot 'default_boot'
        WARNING      | adb command '…adb -s emulator-5556 shell getprop sys.boot_completed ' failed: 'adb: device offline'
        """
        #expect(EmulatorLaunchDiagnosis.quickBootSnapshotFailed(log: hungAfterRestore))
    }

    @Test func firstBootWithoutSnapshotIsNormal() {
        let firstBoot = """
        INFO         | Loading snapshot 'default_boot'...
        WARNING      | Device 'encrypt' does not have the requested snapshot 'default_boot'
        WARNING      | Failed to load snapshot 'default_boot'
        INFO         | Boot completed in 40107 ms
        """
        #expect(!EmulatorLaunchDiagnosis.quickBootSnapshotFailed(log: firstBoot))
        #expect(!EmulatorLaunchDiagnosis.quickBootSnapshotFailed(log: "INFO         | Successfully loaded snapshot 'default_boot' using 1329 ms"))
    }
}
