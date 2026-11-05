import Foundation
import DDCore
import DDPlatform

public struct SDKTool: Sendable, Equatable {
    public var url: URL
    public var version: PackageVersion?

    public init(url: URL, version: PackageVersion?) {
        self.url = url
        self.version = version
    }
}

/// A located Android SDK and the tools DroidDeck uses from it.
public struct SDKInstallation: Sendable, Equatable {
    public var root: URL
    public var emulator: SDKTool?
    public var adb: SDKTool?
    public var avdmanager: SDKTool?
    public var sdkmanager: SDKTool?
    public var mksdcard: URL?
    public var aapt2: URL?
    public var javaHome: URL?
    public var avdHome: URL
    /// Other adb binaries found on the system with a different version (they restart each other's server).
    public var conflictingADBs: [SDKTool]

    /// Environment for every SDK tool DroidDeck launches.
    public var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_HOME"] = root.path
        env["ANDROID_SDK_ROOT"] = root.path
        env["ANDROID_AVD_HOME"] = avdHome.path
        if let javaHome {
            env["JAVA_HOME"] = javaHome.path
            env["PATH"] = javaHome.appending(path: "bin").path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        }
        return env
    }

    public var runner: ProcessRunner { ProcessRunner(environment: environment) }

    public var systemImagesDirectory: URL { root.appending(path: "system-images") }
    public var skinsDirectory: URL { root.appending(path: "skins") }
}

public enum SDKLocator {
    public static var defaultAVDHome: URL {
        if let custom = ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".android/avd")
    }

    /// Candidate SDK roots in priority order.
    public static func candidates(preferred: URL?) -> [URL] {
        var urls: [URL] = []
        if let preferred { urls.append(preferred) }
        let env = ProcessInfo.processInfo.environment
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let value = env[key], !value.isEmpty { urls.append(URL(fileURLWithPath: value)) }
        }
        urls.append(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Android/sdk"))
        urls.append(URL(fileURLWithPath: "/opt/homebrew/share/android-commandlinetools"))
        urls.append(URL(fileURLWithPath: "/usr/local/share/android-commandlinetools"))
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Returns the first candidate that contains the emulator or platform-tools.
    public static func locate(preferredRoot: URL? = nil, avdHome: URL? = nil) async -> SDKInstallation? {
        let fm = FileManager.default
        for root in candidates(preferred: preferredRoot) {
            let emulator = root.appending(path: "emulator/emulator")
            let adb = root.appending(path: "platform-tools/adb")
            guard fm.isExecutableFile(atPath: emulator.path) || fm.isExecutableFile(atPath: adb.path) else { continue }
            return await inspect(root: root, avdHome: avdHome ?? defaultAVDHome)
        }
        return nil
    }

    public static func inspect(root: URL, avdHome: URL) async -> SDKInstallation {
        let fm = FileManager.default
        func tool(_ relative: String, versionFrom properties: String) -> SDKTool? {
            let url = root.appending(path: relative)
            guard fm.isExecutableFile(atPath: url.path) else { return nil }
            return SDKTool(url: url, version: packageRevision(root.appending(path: properties)))
        }
        let cmdlineDir = commandLineToolsDirectory(root: root)
        let avdmanager = cmdlineDir.flatMap { dir -> SDKTool? in
            let url = dir.appending(path: "bin/avdmanager")
            guard fm.isExecutableFile(atPath: url.path) else { return nil }
            return SDKTool(url: url, version: packageRevision(dir.appending(path: "source.properties")))
        }
        let sdkmanager = cmdlineDir.flatMap { dir -> SDKTool? in
            let url = dir.appending(path: "bin/sdkmanager")
            guard fm.isExecutableFile(atPath: url.path) else { return nil }
            return SDKTool(url: url, version: packageRevision(dir.appending(path: "source.properties")))
        }
        let adb = tool("platform-tools/adb", versionFrom: "platform-tools/source.properties")
        let mksdcard = root.appending(path: "emulator/mksdcard")
        return SDKInstallation(
            root: root,
            emulator: tool("emulator/emulator", versionFrom: "emulator/source.properties"),
            adb: adb,
            avdmanager: avdmanager,
            sdkmanager: sdkmanager,
            mksdcard: fm.isExecutableFile(atPath: mksdcard.path) ? mksdcard : nil,
            aapt2: latestBuildTool(root: root, named: "aapt2"),
            javaHome: await locateJavaHome(),
            avdHome: avdHome,
            conflictingADBs: await conflictingADBs(than: adb)
        )
    }

    /// Prefers cmdline-tools/latest, then the highest numbered version directory.
    static func commandLineToolsDirectory(root: URL) -> URL? {
        let base = root.appending(path: "cmdline-tools")
        let latest = base.appending(path: "latest")
        if FileManager.default.fileExists(atPath: latest.appending(path: "bin/avdmanager").path) { return latest }
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return versions
            .compactMap { name -> (PackageVersion, URL)? in
                guard let v = PackageVersion(name) else { return nil }
                return (v, base.appending(path: name))
            }
            .max { $0.0 < $1.0 }?.1
    }

    static func latestBuildTool(root: URL, named name: String) -> URL? {
        let base = root.appending(path: "build-tools")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return versions
            .compactMap { v -> (PackageVersion, URL)? in
                guard let version = PackageVersion(v) else { return nil }
                let url = base.appending(path: "\(v)/\(name)")
                return FileManager.default.isExecutableFile(atPath: url.path) ? (version, url) : nil
            }
            .max { $0.0 < $1.0 }?.1
    }

    public static func packageRevision(_ propertiesFile: URL) -> PackageVersion? {
        guard let ini = try? INIFile(contentsOf: propertiesFile), let revision = ini["Pkg.Revision"] else { return nil }
        return PackageVersion(revision)
    }

    /// cmdline-tools require Java 17+. Android Studio's bundled runtime is preferred.
    static func locateJavaHome() async -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["JAVA_HOME"], fm.isExecutableFile(atPath: env + "/bin/java") {
            return URL(fileURLWithPath: env)
        }
        for app in ["/Applications/Android Studio.app", "\(NSHomeDirectory())/Applications/Android Studio.app",
                    "/Applications/Android Studio Preview.app"] {
            let jbr = URL(fileURLWithPath: app).appending(path: "Contents/jbr/Contents/Home")
            if fm.isExecutableFile(atPath: jbr.appending(path: "bin/java").path) { return jbr }
        }
        let result = try? await ProcessRunner().run(URL(fileURLWithPath: "/usr/libexec/java_home"), ["-v", "17+"], timeout: .seconds(10))
        if let result, result.succeeded {
            let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Homebrew or other adb binaries with a different version kill each other's server.
    static func conflictingADBs(than primary: SDKTool?) async -> [SDKTool] {
        var found: [SDKTool] = []
        for path in ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"] {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: url.path),
                  url.path != primary?.url.resolvingSymlinksInPath().path else { continue }
            let output = try? await ProcessRunner().run(url, ["version"], timeout: .seconds(10))
            let version = output?.stdoutString
                .split(separator: "\n")
                .first { $0.hasPrefix("Version ") }
                .flatMap { line in
                    // "Version 37.0.0-14910828": the build number after '-' is not part of the package version.
                    PackageVersion(String(line.dropFirst("Version ".count).split(separator: "-").first ?? ""))
                }
            if version != primary?.version {
                found.append(SDKTool(url: URL(fileURLWithPath: path), version: version))
            }
        }
        return found
    }
}
