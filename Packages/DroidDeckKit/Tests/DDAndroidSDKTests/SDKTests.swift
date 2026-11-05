import Foundation
import Testing
@testable import DDAndroidSDK
import DDCore
import DDPlatform

// Fixtures are excerpts of real tool output captured on macOS 27 / SDK cmdline-tools 20.0.
private let listingFixture = """
Loading package information...                                                  \r[====    ] 25% Fetch remote repository...       \r[=======================================] 100% Computing updates...
Installed packages:
  Path                                                             | Version       | Description                                         | Location
  -------                                                          | -------       | -------                                             | -------
  emulator                                                         | 36.6.11       | Android Emulator                                    | emulator
  system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a | 5             | 16 KB Page Size Google Play ARM 64 v8a System Image | system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a

Available Packages:
  Path                                                                            | Version           | Description
  -------                                                                         | -------           | -------
  system-images;android-36.1;google_apis_playstore;arm64-v8a                      | 4                 | Google Play ARM 64 v8a System Image
  system-images;android-37.0;google_apis_playstore;arm64-v8a                      | 8                 | Google Play ARM 64 v8a System Image
  system-images;android-37.0;google_apis_playstore;x86_64                         | 8                 | Google Play Intel x86_64 Atom System Image
  system-images;android-37.2-beta3;google_apis_playstore;arm64-v8a                | 1                 | Google Play ARM 64 v8a System Image
  system-images;android-35-ext14;google_apis_playstore;arm64-v8a                  | 1                 | Google Play ARM 64 v8a System Image
  system-images;android-36.1;android-wear-signed;arm64-v8a                        | 1                 | Wear OS 6.1 ARM 64 v8a System Image (signed)

Available Updates:
  ID                                                               | Installed | Available
  -------                                                          | -------   | -------
  emulator                                                         | 36.6.11   | 37.2.12
"""

@Suite("sdkmanager listing")
struct ListingTests {
    @Test func parsesAllThreeTables() {
        let listing = SystemImageCatalog.parseListing(listingFixture)
        #expect(listing.installed.map(\.path) == ["emulator", "system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a"])
        #expect(listing.available.count == 6)
        #expect(listing.updates == [SDKPackageListing(path: "emulator", version: "36.6.11", description: "", extra: "37.2.12")])
    }

    @Test func mergeMarksAvailabilityAndFindsLatestStable() {
        let listing = SystemImageCatalog.parseListing(listingFixture)
        let merged = SystemImageCatalog.merge(installed: [], listing: listing)
        #expect(merged.allSatisfy { !$0.isInstalled })
        let latest = SystemImageCatalog.latestStablePlatform(in: merged, abis: [.arm64v8a])
        #expect(latest == AndroidPlatform(apiLevel: 37, minor: 0))
        let beta = merged.first { $0.platform.isPreview }
        #expect(beta?.hasGooglePlay == true)
        #expect(merged.first { $0.tagDirectory == "android-wear-signed" }?.formFactor == .wear)
    }

    @Test func tagDirectoriesMapToTagIDs() {
        #expect(SystemImageCatalog.tagIDs(forDirectory: "google_apis_playstore_ps16k") == ["google_apis_playstore", "page_size_16kb"])
    }
}

@Suite("Installed system images")
struct InstalledImageTests {
    @Test func readsSourceProperties() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dd-sdk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appending(path: "system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        Pkg.Desc=System Image Page Size 16k arm64-v8a with Google Play.
        Pkg.Revision=5
        Pkg.Dependencies=emulator#35.4.9
        AndroidVersion.ApiLevel=37.0
        AndroidVersion.ExtensionLevel=22
        SystemImage.Abi=arm64-v8a
        SystemImage.TagId=google_apis_playstore,page_size_16kb
        SystemImage.TagDisplay=Google APIs PlayStore,Page Size 16KB
        """.write(to: dir.appending(path: "source.properties"), atomically: true, encoding: .utf8)
        let images = SystemImageCatalog.installedImages(sdkRoot: root)
        let image = try #require(images.first)
        #expect(image.packagePath == "system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a")
        #expect(image.hasGooglePlay && image.usesSixteenKBPages)
        #expect(image.minimumEmulatorVersion == PackageVersion("35.4.9"))
        #expect(image.title == "Android 17 · Google Play")
        #expect(SystemImageCatalog.missingFiles(in: image).contains("system.img"))
    }
}

@Suite("License prompts")
struct LicensePromptTests {
    @Test("License text is surfaced only when sdkmanager asks for a decision")
    func detectsPrompt() {
        let parser = InstallOutputParser()
        #expect(parser.feed("[=====   ] 12% Downloading x.zip... \r").contains(.progress(percent: 12, message: "Downloading x.zip...")))
        #expect(parser.feed("License android-sdk-preview-license:\n---------------------------------------\nTerms line 1.\n").isEmpty)
        let events = parser.feed("Terms line 2.\n---------------------------------------\nAccept? (y/N): ")
        #expect(events == [.licenseRequired(id: "android-sdk-preview-license", text: "Terms line 1.\nTerms line 2.")])
    }
}

@Suite("Device profiles")
struct DeviceProfileTests {
    static let xml = """
    <?xml version="1.0"?>
    <d:devices xmlns:d="http://schemas.android.com/sdk/devices/7">
      <d:device>
        <d:name>Pixel 9 Pro</d:name>
        <d:id>pixel_9_pro</d:id>
        <d:manufacturer>Google</d:manufacturer>
        <d:playstore-enabled>true</d:playstore-enabled>
        <d:hardware>
          <d:screen>
            <d:diagonal-length>6.3</d:diagonal-length>
            <d:pixel-density>xxhdpi</d:pixel-density>
            <d:dimensions><d:x-dimension>1280</d:x-dimension><d:y-dimension>2856</d:y-dimension></d:dimensions>
            <d:xdpi>494</d:xdpi><d:ydpi>497</d:ydpi>
          </d:screen>
          <d:sensors> Accelerometer GPS Gyroscope </d:sensors>
          <d:camera><d:location>back</d:location></d:camera>
          <d:camera><d:location>front</d:location></d:camera>
          <d:keyboard>nokeys</d:keyboard>
          <d:ram unit="MiB">11548</d:ram>
          <d:skin>pixel_9_pro</d:skin>
        </d:hardware>
        <d:software><d:api-level>35-</d:api-level></d:software>
      </d:device>
      <d:device>
        <d:name>Pixel 10 Pro Fold</d:name>
        <d:id>pixel_10_pro_fold</d:id>
        <d:manufacturer>Google</d:manufacturer>
        <d:hardware><d:screen><d:diagonal-length>8.0</d:diagonal-length><d:pixel-density>390dpi</d:pixel-density>
          <d:dimensions><d:x-dimension>2076</d:x-dimension><d:y-dimension>2152</d:y-dimension></d:dimensions>
        </d:screen><d:ram unit="GiB">16</d:ram></d:hardware>
      </d:device>
    </d:devices>
    """

    @Test func parsesOfficialDefinitions() throws {
        let profiles = DeviceProfileCatalog.parse(xml: Data(Self.xml.utf8), source: "Test")
        let pixel = try #require(profiles.first { $0.id == "pixel_9_pro" })
        #expect(pixel.resolutionDescription == "1280 × 2856")
        #expect(pixel.lcdDensity == 480)
        #expect(pixel.ram == Megabytes(11548))
        #expect(pixel.hasFrontCamera && pixel.hasBackCamera && !pixel.hasHardwareKeyboard)
        #expect(pixel.playStoreEnabled)
        #expect(pixel.minimumAPILevel == 35 && pixel.maximumAPILevel == nil)
        #expect(pixel.formFactor == .phone)
        let fold = try #require(profiles.first { $0.id == "pixel_10_pro_fold" })
        #expect(fold.formFactor == .foldable)
        #expect(fold.lcdDensity == 390)
        #expect(fold.ram == .gigabytes(16))
    }
}

@Suite("Skins")
struct SkinTests {
    @Test func parsesPixelLayout() throws {
        let text = """
        parts {
          device {
            display {
              width 1280
              height 2856
              x 0
              y 0
              corner_radius 109
            }
          }
          portrait {
            background {
              image back.webp
            }
            foreground {
              mask mask.webp
              cutout hole
            }
          }
        }
        layouts {
          portrait {
            width 1408
            height 2974
            event EV_SW:0:1
            part1 {
              name portrait
              x 0
              y 0
            }
            part2 {
              name device
              x 60
              y 61
            }
          }
        }
        """
        let layout = try #require(SkinLayout.parse(text, directory: URL(fileURLWithPath: "/nonexistent/pixel_9_pro")))
        #expect(layout.frameWidth == 1408 && layout.frameHeight == 2974)
        #expect(layout.displayX == 60 && layout.displayY == 61)
        #expect(layout.displayWidth == 1280 && layout.displayHeight == 2856)
        #expect(layout.displayCornerRadius == 109)
    }
}

@Suite("AVD repository")
struct AVDRepositoryTests {
    func makeAVD(home: URL, name: String) throws {
        let dir = home.appending(path: "\(name).avd")
        try FileManager.default.createDirectory(at: dir.appending(path: "snapshots/default_boot"), withIntermediateDirectories: true)
        try "avd.ini.encoding=UTF-8\npath=\(dir.path)\npath.rel=avd/\(name).avd\ntarget=android-34\n"
            .write(to: home.appending(path: "\(name).ini"), atomically: true, encoding: .utf8)
        try """
        AvdId=\(name)
        PlayStore.enabled=no
        abi.type=arm64-v8a
        hw.ramSize=2G
        hw.cpu.ncore=4
        hw.lcd.width=1080
        hw.lcd.height=2400
        hw.lcd.density=420
        image.sysdir.1=system-images/android-34/google_apis/arm64-v8a/
        sdcard.size=512M
        custom.unmanaged=keep-me
        """.write(to: dir.appending(path: "config.ini"), atomically: true, encoding: .utf8)
        for file in ["userdata-qemu.img", "multiinstance.lock", "hardware-qemu.ini", "snapshots/default_boot/ram.bin"] {
            try Data("x".utf8).write(to: dir.appending(path: file))
        }
    }

    @Test func readsAndAppliesConfiguration() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "dd-avd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try makeAVD(home: home, name: "Test_Phone")
        let repo = AVDRepository(avdHome: home)
        let avd = try #require(repo.list().first)
        #expect(avd.systemImagePackage == "system-images;android-34;google_apis;arm64-v8a")
        #expect(avd.ram == Megabytes(2048))
        #expect(avd.ramValueIgnoredByEmulator)
        try repo.normalizeRAMValue(avd)
        #expect(repo.record(named: "Test_Phone")?.config["hw.ramSize"] == "2048")
        #expect(repo.record(named: "Test_Phone")?.ramValueIgnoredByEmulator == false)
        var config = repo.configuration(of: avd)
        config.ram = .gigabytes(8)
        config.cpuCores = 6
        config.displayName = "Test Phone"
        try repo.apply(config, image: nil, profile: nil, skinDirectory: nil, to: avd)
        let updated = try #require(repo.record(named: "Test_Phone"))
        #expect(updated.config["hw.ramSize"] == "8192")
        #expect(updated.config["disk.dataPartition.size"] == "6G")
        #expect(updated.config["hw.cpu.ncore"] == "6")
        #expect(updated.config["custom.unmanaged"] == "keep-me")
        #expect(updated.displayName == "Test Phone")
    }

    @Test("Clones drop locks and snapshots; user data only when requested")
    func cloneSafety() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "dd-avd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try makeAVD(home: home, name: "Source")
        let repo = AVDRepository(avdHome: home)
        let source = try #require(repo.record(named: "Source"))

        let withData = try await repo.clone(source, as: "Copy_Data", displayName: "Copy Data", includeUserData: true,
                                            mksdcard: nil, runner: ProcessRunner())
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: withData.directory.appending(path: "userdata-qemu.img").path))
        #expect(!fm.fileExists(atPath: withData.directory.appending(path: "multiinstance.lock").path))
        #expect(!fm.fileExists(atPath: withData.directory.appending(path: "hardware-qemu.ini").path))
        #expect(!fm.fileExists(atPath: withData.directory.appending(path: "snapshots").path))
        #expect(withData.config["AvdId"] == "Copy_Data")
        #expect(withData.displayName == "Copy Data")

        let fresh = try await repo.clone(source, as: "Copy_Fresh", displayName: "Copy Fresh", includeUserData: false,
                                         mksdcard: nil, runner: ProcessRunner())
        #expect(!fm.fileExists(atPath: fresh.directory.appending(path: "userdata-qemu.img").path))
        #expect(!fm.fileExists(atPath: fresh.directory.appending(path: "snapshots").path))
        // The source is untouched.
        #expect(fm.fileExists(atPath: source.directory.appending(path: "snapshots/default_boot/ram.bin").path))
        await #expect(throws: DroidDeckError.self) {
            _ = try await repo.clone(source, as: "Copy_Data", displayName: "x", includeUserData: false, mksdcard: nil, runner: ProcessRunner())
        }
        await #expect(throws: DroidDeckError.self) {
            _ = try await repo.clone(source, as: "../escape", displayName: "x", includeUserData: false, mksdcard: nil, runner: ProcessRunner())
        }
    }
}

@Suite("Direct AVD creation")
struct DirectCreationTests {
    func fakeSDK() throws -> (root: URL, image: SystemImage) {
        let root = FileManager.default.temporaryDirectory.appending(path: "dd-sdk-\(UUID().uuidString)")
        let imageDir = root.appending(path: "system-images/android-34/google_apis_playstore/arm64-v8a")
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        for f in ["system.img", "ramdisk.img", "build.prop", "kernel-ranchu", "userdata.img"] {
            try Data("x".utf8).write(to: imageDir.appending(path: f))
        }
        let image = SystemImage(packagePath: "system-images;android-34;google_apis_playstore;arm64-v8a",
                                platform: AndroidPlatform(apiLevel: 34), tagDirectory: "google_apis_playstore",
                                tagIDs: ["google_apis_playstore"], tagDisplay: "Google Play", abi: "arm64-v8a",
                                revision: "14", description: "", isInstalled: true, installPath: imageDir.path)
        return (root, image)
    }

    @Test("Writes a valid AVD without launching avdmanager")
    func createsBootableFiles() throws {
        let (root, image) = try fakeSDK()
        let home = root.appending(path: "avd")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = AVDRepository(avdHome: home)
        let config = DeviceConfiguration(avdName: "Fast_Phone", displayName: "Fast Phone",
                                         systemImagePackage: image.packagePath, profileID: "pixel_9_pro",
                                         ram: Megabytes(3072), cpuCores: 4, dataPartition: .gigabytes(8),
                                         sdCard: Megabytes(512), screenWidth: 1080, screenHeight: 2400, screenDensity: 420)
        let avd = try repo.createDirect(config, image: image, sdkRoot: root, profile: nil, skinDirectory: nil)
        #expect(avd.systemImagePackage == image.packagePath)
        #expect(avd.config["image.sysdir.1"] == "system-images/android-34/google_apis_playstore/arm64-v8a/")
        #expect(avd.config["hw.ramSize"] == "3072")              // plain MB, the value the emulator honors
        #expect(avd.config["disk.dataPartition.size"] == "8G")
        #expect(avd.config["abi.type"] == "arm64-v8a")
        #expect(avd.config["hw.cpu.arch"] == "arm64")
        #expect(avd.config["target"] == "android-34")
        #expect(avd.config.bool("PlayStore.enabled") == true)
        #expect(avd.ramValueIgnoredByEmulator == false)
        #expect(FileManager.default.fileExists(atPath: home.appending(path: "Fast_Phone.ini").path))
        #expect(FileManager.default.fileExists(atPath: avd.directory.appending(path: "userdata.img").path))
        #expect(repo.list().map(\.name) == ["Fast_Phone"])
    }

    @Test("Refuses a system image outside the SDK (path escape)")
    func rejectsImageOutsideSDK() throws {
        let (root, _) = try fakeSDK()
        let home = root.appending(path: "avd")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = SystemImage(packagePath: "x", platform: AndroidPlatform(apiLevel: 34), tagDirectory: "t",
                                  tagIDs: ["t"], tagDisplay: "", abi: "arm64-v8a", revision: "1", description: "",
                                  isInstalled: true, installPath: "/tmp/not-in-sdk")
        let config = DeviceConfiguration(avdName: "Bad", displayName: "Bad", systemImagePackage: "x", profileID: nil,
                                         ram: Megabytes(2048), cpuCores: 2, dataPartition: .gigabytes(6),
                                         screenWidth: 1080, screenHeight: 2400, screenDensity: 420)
        #expect(throws: DroidDeckError.self) {
            _ = try repo.createDirect(config, image: outside, sdkRoot: root, profile: nil, skinDirectory: nil)
        }
    }
    let repo = AVDRepository(avdHome: FileManager.default.temporaryDirectory.appending(path: "unused"))
}
