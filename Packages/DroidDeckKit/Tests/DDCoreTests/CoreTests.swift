import Testing
@testable import DDCore

@Suite("Units and versions")
struct UnitTests {
    @Test("Megabyte parsing accepts every format seen in real config.ini files",
          arguments: [
              ("2048", 2048), ("2G", 2048), ("2048M", 2048), ("6G", 6144), ("512M", 512),
              ("66MB", 66), ("10G", 10240), ("1.5G", 1536), ("8192 MB", 8192),
          ])
    func parse(raw: String, expected: Int) {
        #expect(Megabytes.parse(raw) == Megabytes(expected))
    }

    @Test func rejectsGarbage() {
        #expect(Megabytes.parse("") == nil)
        #expect(Megabytes.parse("lots") == nil)
        #expect(Megabytes.parse("12X") == nil)
    }

    @Test func formatting() {
        #expect(Megabytes(4096).description == "4 GB")
        #expect(Megabytes(1536).description == "1.5 GB")
        #expect(Megabytes(512).description == "512 MB")
    }

    @Test func platformParsingAndOrdering() throws {
        let p34 = try #require(AndroidPlatform(sdkString: "android-34"))
        let p361 = try #require(AndroidPlatform(sdkString: "android-36.1"))
        let p370 = try #require(AndroidPlatform(sdkString: "android-37.0"))
        #expect(p34 < p361 && p361 < p370)
        #expect(p34.marketingName == "Android 14")
        #expect(p361.marketingName == "Android 16 (API 36.1)")
        #expect(p370.sdkString == "android-37.0")
        #expect(AndroidPlatform(sdkString: "android-Baklava")?.apiLevel == 36)
    }

    @Test("Every platform form seen in sdkmanager --list parses and round-trips",
          arguments: ["android-35-ext14", "android-37.2-beta3", "android-CANARY", "android-canary-20261007", "android-36.1", "android-21"])
    func platformForms(raw: String) throws {
        let platform = try #require(AndroidPlatform(sdkString: raw))
        #expect(platform.sdkString == raw)
    }

    @Test func previewsSortBeforeTheirStableRelease() throws {
        let beta = try #require(AndroidPlatform(sdkString: "android-37.2-beta3"))
        let stable = try #require(AndroidPlatform(sdkString: "android-37.2"))
        let ext = try #require(AndroidPlatform(sdkString: "android-35-ext14"))
        #expect(beta.isPreview && !stable.isPreview)
        #expect(beta < stable)
        #expect(ext.apiLevel == 35 && ext.extensionLevel == 14)
        #expect(beta.marketingName == "Android 17 (API 37.2) beta3")
    }

    @Test func packageVersions() {
        #expect(PackageVersion("36.6.11")! > PackageVersion("35.4.9")!)
        #expect(PackageVersion("34.2.16")! < PackageVersion("34.2.16.1")!)
        #expect(PackageVersion("36.6.11")! == PackageVersion("36.6.11.0")!)
    }

    @Test func systemImagePackagePath() throws {
        let parts = try #require(SystemImage.components(of: "system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a"))
        #expect(parts.platform.apiLevel == 37)
        #expect(parts.tag == "google_apis_playstore_ps16k")
        #expect(parts.abi == "arm64-v8a")
    }
}

@Suite("AVD naming")
struct NamingTests {
    @Test func validation() {
        #expect(AVDNaming.isValid("Pixel_9_Pro"))
        #expect(AVDNaming.isValid("dev-1.2"))
        #expect(!AVDNaming.isValid("My Phone"))
        #expect(!AVDNaming.isValid("../evil"))
        #expect(!AVDNaming.isValid(""))
        #expect(!AVDNaming.isValid("-flag"))
    }

    @Test func suggestionsAreValidAndUnique() {
        #expect(AVDNaming.suggest(from: "Pixel 9 Pro (Work)", existing: []) == "Pixel_9_Pro_Work")
        #expect(AVDNaming.suggest(from: "Pixel 9 Pro", existing: ["Pixel_9_Pro"]) == "Pixel_9_Pro_2")
        #expect(AVDNaming.suggest(from: "Pixel 9 Pro", existing: ["pixel_9_pro", "Pixel_9_Pro_2"]) == "Pixel_9_Pro_3")
        #expect(AVDNaming.suggest(from: "📱", existing: []) == "Device")
        #expect(AVDNaming.isValid(AVDNaming.suggest(from: "Ünïcode ✓ name", existing: [])))
    }
}

@Suite("Configuration validation")
struct ValidationTests {
    static let image = SystemImage(
        packagePath: "system-images;android-34;google_apis_playstore;arm64-v8a",
        platform: AndroidPlatform(apiLevel: 34), tagDirectory: "google_apis_playstore",
        tagIDs: ["google_apis_playstore"], tagDisplay: "Google Play", abi: "arm64-v8a", revision: "14",
        description: "", minimumEmulatorVersion: PackageVersion("34.2.16"), isInstalled: true
    )

    static let host = HostResources(
        architecture: .arm64, physicalMemory: .gigabytes(48), logicalCPUs: 12, performanceCPUs: 8,
        availableDiskBytes: 100 * 1_073_741_824
    )

    func validator(host: HostResources = host, image: SystemImage? = image, emulator: String = "36.6.11") -> ConfigurationValidator {
        ConfigurationValidator(
            host: host,
            limits: .androidEmulator(host: host.architecture, hostPhysicalMemory: host.physicalMemory),
            existingAVDNames: ["Existing"],
            image: image,
            emulatorVersion: PackageVersion(emulator)
        )
    }

    func config(ram: Int = 4096, cores: Int = 4, name: String = "Test_Device", storage: Int = 8192) -> DeviceConfiguration {
        DeviceConfiguration(
            avdName: name, displayName: "Test Device", systemImagePackage: Self.image.packagePath,
            profileID: "pixel_9_pro", ram: Megabytes(ram), cpuCores: cores, dataPartition: Megabytes(storage),
            screenWidth: 1280, screenHeight: 2856, screenDensity: 480
        )
    }

    @Test("All RAM presets are valid on a 48 GB Apple Silicon Mac", arguments: RAMPreset.allCases)
    func presets(preset: RAMPreset) {
        let result = validator().validate(config(ram: preset.megabytes.value))
        #expect(result.isValid, "\(result.errors)")
    }

    @Test func ramAboveMeasuredArm64CeilingIsRejected() {
        let result = validator().validate(config(ram: 32 * 1024))
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.field == .ram && $0.message.contains("31 GB") })
        #expect(validator().validate(config(ram: 31 * 1024)).isValid)
    }

    @Test func ramMustLeaveHeadroomForMacOS() {
        let small = HostResources(architecture: .arm64, physicalMemory: .gigabytes(16), logicalCPUs: 8,
                                  performanceCPUs: 4, availableDiskBytes: 100 * 1_073_741_824)
        let result = validator(host: small).validate(config(ram: 16 * 1024))
        #expect(result.errors.contains { $0.field == .ram })
        let warning = validator(host: small).validate(config(ram: 12 * 1024))
        #expect(warning.isValid)
        #expect(warning.warnings.contains { $0.field == .ram })
    }

    @Test func intelLimitsAreMarkedUnverified() {
        let intel = HostResources(architecture: .x86_64, physicalMemory: .gigabytes(64), logicalCPUs: 16,
                                  performanceCPUs: 0, availableDiskBytes: 100 * 1_073_741_824)
        let limits = RuntimeLimits.androidEmulator(host: .x86_64, hostPhysicalMemory: intel.physicalMemory)
        #expect(!limits.maximumRAMVerified)
        let x86 = SystemImage(packagePath: "system-images;android-34;google_apis;x86_64", platform: AndroidPlatform(apiLevel: 34),
                              tagDirectory: "google_apis", tagIDs: ["google_apis"], tagDisplay: "Google APIs",
                              abi: "x86_64", revision: "1", description: "", isInstalled: true)
        let result = validator(host: intel, image: x86).validate(config(ram: 20 * 1024))
        #expect(result.isValid)
        #expect(result.warnings.contains { $0.message.contains("not been verified") })
    }

    @Test func architectureMismatchIsAnError() {
        let x86 = SystemImage(packagePath: "system-images;android-34;google_apis;x86_64", platform: AndroidPlatform(apiLevel: 34),
                              tagDirectory: "google_apis", tagIDs: ["google_apis"], tagDisplay: "Google APIs",
                              abi: "x86_64", revision: "1", description: "", isInstalled: true)
        let result = validator(image: x86).validate(config())
        #expect(result.errors.contains { $0.field == .image && $0.message.contains("x86 64-bit") })
    }

    @Test func outdatedEmulatorIsAnError() {
        let result = validator(emulator: "33.1.0").validate(config())
        #expect(result.errors.contains { $0.message.contains("34.2.16") })
    }

    @Test func cpuLimits() {
        #expect(!validator().validate(config(cores: 16)).isValid)
        #expect(validator().validate(config(cores: 10)).warnings.contains { $0.field == .cpu })
        #expect(!validator().validate(config(cores: 0)).isValid)
    }

    @Test func duplicateNamesAreCaseInsensitive() {
        #expect(validator().validate(config(name: "existing")).errors.contains { $0.field == .name })
    }

    @Test func lowDiskBlocksCreation() {
        let full = HostResources(architecture: .arm64, physicalMemory: .gigabytes(48), logicalCPUs: 12,
                                 performanceCPUs: 8, availableDiskBytes: 1_073_741_824)
        #expect(validator(host: full).validate(config()).errors.contains { $0.field == .storage })
    }

    @Test func smallStorageWarnsAboutEmulatorMinimum() {
        #expect(validator().validate(config(storage: 4096)).warnings.contains { $0.field == .storage })
    }

    @Test func runningDevicesRaiseMemoryPressureWarning() {
        var busy = Self.host
        busy.runningDevicesRAM = .gigabytes(32)
        let result = validator(host: busy).validate(config(ram: 8192))
        #expect(result.warnings.contains { $0.field == .host })
    }
}

@Suite("Capabilities")
struct CapabilityTests {
    @Test func disabledCapabilitiesCarryReasons() {
        var report = CapabilityReport()
        report.enable(.startDevice, .embeddedDisplay)
        report.disable(.embeddedDisplay, because: "gRPC endpoint unavailable")
        #expect(report.supports(.startDevice))
        #expect(!report.supports(.embeddedDisplay))
        #expect(report.reason(.embeddedDisplay) == "gRPC endpoint unavailable")
        #expect(report.reason(.snapshots) == "Not supported by this runtime.")
    }
}

@Suite("Mac GPU rendering")
struct MacGPURenderingTests {
    @Test func android15AndNewerRenderOnTheCPU() throws {
        for (path, gpu) in [("system-images;android-34;google_apis;arm64-v8a", true),
                            ("system-images;android-34;google_apis_playstore;arm64-v8a", true),
                            ("system-images;android-35;google_apis_playstore;arm64-v8a", false),
                            ("system-images;android-36;google_apis_playstore;arm64-v8a", false),
                            ("system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a", false)] {
            let parts = try #require(SystemImage.components(of: path))
            #expect((parts.platform.apiLevel < SystemImage.firstAPILevelNeedingES31) == gpu, "\(path)")
        }
    }
}
