import Foundation
import DDCore
import DDPlatform

public struct ADBDevice: Sendable, Equatable, Identifiable, Hashable {
    public enum State: String, Sendable {
        case device, offline, unauthorized, recovery, bootloader, sideload, authorizing, connecting, unknown
    }

    public var serial: String
    public var state: State
    public var product: String?
    public var model: String?
    public var device: String?
    public var transportID: String?

    public var id: String { serial }

    /// True for Android Emulator consoles ("emulator-<port>"). Other emulators may reuse
    /// this naming, so callers must confirm ownership via the emulator console.
    public var isEmulatorSerial: Bool { serial.hasPrefix("emulator-") }

    public var consolePort: Int? {
        guard isEmulatorSerial else { return nil }
        return Int(serial.dropFirst("emulator-".count))
    }

    /// Network-attached devices (Wi-Fi debugging) use host:port serials.
    public var isNetworkDevice: Bool { serial.contains(":") }
}

public struct InstallOptions: Sendable, Equatable {
    public var replaceExisting = true
    public var allowDowngrade = false
    public var allowTestPackages = false
    public var grantAllPermissions = false
    /// Android 14+ blocks apps targeting very old SDKs unless this is set.
    public var bypassLowTargetSDKBlock = false

    public init() {}

    var arguments: [String] {
        var args: [String] = []
        if replaceExisting { args.append("-r") }
        if allowDowngrade { args.append("-d") }
        if allowTestPackages { args.append("-t") }
        if grantAllPermissions { args.append("-g") }
        if bypassLowTargetSDKBlock { args.append("--bypass-low-target-sdk-block") }
        return args
    }
}

/// Quotes arguments for the device's /system/bin/sh.
public enum ShellQuote {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// adb command-line client. All calls name an explicit serial; DroidDeck never relies on a default device.
public struct ADBClient: Sendable {
    public let executable: URL
    public let runner: ProcessRunner

    public init(executable: URL, runner: ProcessRunner) {
        self.executable = executable
        self.runner = runner
    }

    private func run(_ args: [String], timeout: Duration? = .seconds(60), input: Data? = nil) async throws -> ProcessResult {
        try await runner.run(executable, args, input: input, timeout: timeout)
    }

    /// Event-driven device list (`adb track-devices -l`): yields the full list on every change,
    /// so callers do not have to poll. Messages are a 4-hex-digit length followed by the payload.
    public func trackDevices() -> AsyncThrowingStream<[ADBDevice], Error> {
        let chunks = runner.chunks(executable, ["track-devices", "-l"])
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = TrackDevicesParser()
                do {
                    for try await chunk in chunks {
                        for payload in parser.feed(chunk) {
                            continuation.yield(Self.parseDevices(payload))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func startServer() async throws {
        let result = try await run(["start-server"], timeout: .seconds(30))
        guard result.succeeded else {
            throw DroidDeckError(.adbUnavailable, "The adb server could not start.", detail: result.diagnosticOutput)
        }
    }

    public func devices() async throws -> [ADBDevice] {
        let result = try await run(["devices", "-l"], timeout: .seconds(30))
        guard result.succeeded else {
            throw DroidDeckError(.adbUnavailable, "adb could not list devices.", detail: result.diagnosticOutput)
        }
        return Self.parseDevices(result.stdoutString)
    }

    static func parseDevices(_ text: String) -> [ADBDevice] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            var device = ADBDevice(serial: parts[0], state: ADBDevice.State(rawValue: parts[1]) ?? .unknown)
            for field in parts.dropFirst(2) {
                let kv = field.split(separator: ":", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "product": device.product = kv[1]
                case "model": device.model = kv[1]
                case "device": device.device = kv[1]
                case "transport_id": device.transportID = kv[1]
                default: break
                }
            }
            return device
        }
    }

    /// Runs a shell command. adb propagates the remote exit status.
    @discardableResult
    public func shell(_ serial: String, _ command: String, timeout: Duration? = .seconds(60), allowFailure: Bool = false) async throws -> String {
        let result = try await run(["-s", serial, "shell", command], timeout: timeout)
        if !result.succeeded && !allowFailure {
            throw DroidDeckError(.toolFailed, "The device command failed.", detail: result.diagnosticOutput)
        }
        return result.stdoutString
    }

    public func getprop(_ serial: String, _ key: String) async throws -> String {
        try await shell(serial, "getprop \(ShellQuote.quote(key))", timeout: .seconds(15), allowFailure: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func properties(_ serial: String) async throws -> [String: String] {
        let output = try await shell(serial, "getprop", timeout: .seconds(20), allowFailure: true)
        var props: [String: String] = [:]
        // [ro.build.version.sdk]: [34]
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("["), let sep = line.range(of: "]: [") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<sep.lowerBound])
            var value = String(line[sep.upperBound...])
            if value.hasSuffix("]") { value.removeLast() }
            props[key] = value
        }
        return props
    }

    /// Polls `sys.boot_completed` until it is "1".
    public func waitForBoot(_ serial: String, timeout: Duration, onPhase: @Sendable (DeviceLifecycleState.StartPhase) -> Void = { _ in }) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var sawDevice = false
        while clock.now < deadline {
            try Task.checkCancellation()
            let state = try? await run(["-s", serial, "get-state"], timeout: .seconds(10))
            if state?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "device" {
                if !sawDevice { sawDevice = true; onPhase(.booting) }
                if (try? await getprop(serial, "sys.boot_completed")) == "1" {
                    // Shared storage (/sdcard) is mounted slightly after boot completes.
                    try await waitForSharedStorage(serial, until: deadline)
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw DroidDeckError(.bootTimeout, "Android did not finish booting within \(timeout).",
                             recovery: "Try a cold boot, or give the device more RAM/CPU.")
    }

    private func waitForSharedStorage(_ serial: String, until deadline: ContinuousClock.Instant) async throws {
        let clock = ContinuousClock()
        while clock.now < deadline {
            let probe = try? await shell(serial, "test -d /sdcard/Download && echo ready", timeout: .seconds(10), allowFailure: true)
            if probe?.contains("ready") == true { return }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    public func emu(_ serial: String, _ command: [String], timeout: Duration = .seconds(30)) async throws -> String {
        let result = try await run(["-s", serial, "emu"] + command, timeout: timeout)
        let output = result.stdoutString
        // The console reports failures as "KO: <reason>".
        if !result.succeeded || output.contains("KO:") {
            throw DroidDeckError(.toolFailed, "The emulator console rejected \"\(command.first ?? "")\".",
                                 detail: Redactor.redact(output + result.stderrString))
        }
        return Self.consoleBody(output)
    }

    /// Console replies end with an "OK" line; CRLF line endings are normalized.
    static func consoleBody(_ output: String) -> String {
        var lines = output.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last == "OK" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    public func keyevent(_ serial: String, _ keycode: Int) async throws {
        try await shell(serial, "input keyevent \(keycode)", timeout: .seconds(15))
    }

    public func screenshotPNG(_ serial: String) async throws -> Data {
        let result = try await run(["-s", serial, "exec-out", "screencap", "-p"], timeout: .seconds(30))
        guard result.succeeded, result.stdout.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw DroidDeckError(.toolFailed, "Could not capture a screenshot.", detail: result.diagnosticOutput)
        }
        return result.stdout
    }

    public func reboot(_ serial: String) async throws {
        _ = try await run(["-s", serial, "reboot"], timeout: .seconds(30))
    }

    // MARK: Apps

    public func install(_ serial: String, apks: [URL], options: InstallOptions) async throws -> String {
        guard !apks.isEmpty else { throw DroidDeckError(.installFailed, "No APK selected.") }
        let command = apks.count == 1 ? ["install"] : ["install-multiple"]
        let result = try await run(["-s", serial] + command + options.arguments + apks.map(\.path), timeout: .seconds(600))
        let output = result.stdoutString + result.stderrString
        if result.succeeded && output.contains("Success") { return output }
        throw InstallFailure.diagnose(output: output)
    }

    public func uninstall(_ serial: String, package: String, keepData: Bool) async throws {
        let args = ["-s", serial, "uninstall"] + (keepData ? ["-k"] : []) + [package]
        let result = try await run(args, timeout: .seconds(120))
        guard result.succeeded, result.stdoutString.contains("Success") else {
            throw DroidDeckError(.toolFailed, "Could not uninstall \(package).", detail: result.diagnosticOutput)
        }
    }

    public func packages(_ serial: String, thirdPartyOnly: Bool) async throws -> [String] {
        let output = try await shell(serial, "pm list packages" + (thirdPartyOnly ? " -3" : ""), timeout: .seconds(30))
        return output.split(separator: "\n")
            .compactMap { $0.hasPrefix("package:") ? String($0.dropFirst(8)).trimmingCharacters(in: .whitespaces) : nil }
            .sorted()
    }

    public struct PackageDetails: Sendable, Equatable {
        public var package: String
        public var versionName: String?
        public var versionCode: String?
        public var targetSDK: Int?
        public var firstInstallTime: String?
        public var lastUpdateTime: String?
    }

    public func packageDetails(_ serial: String, package: String) async throws -> PackageDetails {
        let output = try await shell(serial, "dumpsys package \(ShellQuote.quote(package))", timeout: .seconds(30), allowFailure: true)
        func field(_ name: String) -> String? {
            for line in output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(name + "=") { return String(trimmed.dropFirst(name.count + 1)).components(separatedBy: " ").first }
            }
            return nil
        }
        let targetSDK = output.range(of: #"targetSdk=(\d+)"#, options: .regularExpression)
            .flatMap { Int(output[$0].dropFirst("targetSdk=".count)) }
        return PackageDetails(package: package, versionName: field("versionName"), versionCode: field("versionCode"),
                              targetSDK: targetSDK, firstInstallTime: field("firstInstallTime"), lastUpdateTime: field("lastUpdateTime"))
    }

    /// Launches the app's launcher activity.
    public func launch(_ serial: String, package: String) async throws {
        let resolved = try await shell(serial, "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER \(ShellQuote.quote(package))",
                                       timeout: .seconds(20), allowFailure: true)
        guard let component = resolved.split(separator: "\n").last.map(String.init), component.contains("/") else {
            throw DroidDeckError(.toolFailed, "\(package) has no launcher activity.")
        }
        let output = try await shell(serial, "am start -n \(ShellQuote.quote(component.trimmingCharacters(in: .whitespaces)))",
                                     timeout: .seconds(20), allowFailure: true)
        if output.contains("Error") {
            throw DroidDeckError(.toolFailed, "Could not launch \(package).", detail: output)
        }
    }

    public func forceStop(_ serial: String, package: String) async throws {
        try await shell(serial, "am force-stop \(ShellQuote.quote(package))", timeout: .seconds(20))
    }

    public func clearData(_ serial: String, package: String) async throws {
        let output = try await shell(serial, "pm clear \(ShellQuote.quote(package))", timeout: .seconds(60), allowFailure: true)
        guard output.contains("Success") else {
            throw DroidDeckError(.toolFailed, "Could not clear data for \(package).", detail: output)
        }
    }

    // MARK: Files

    public func push(_ serial: String, local: URL, remote: String) async throws {
        let result = try await run(["-s", serial, "push", local.path, remote], timeout: .seconds(1800))
        guard result.succeeded else {
            throw DroidDeckError(.fileOperationFailed, "Could not copy \(local.lastPathComponent) to the device.", detail: result.diagnosticOutput)
        }
    }

    public func pull(_ serial: String, remote: String, local: URL) async throws {
        let result = try await run(["-s", serial, "pull", remote, local.path], timeout: .seconds(1800))
        guard result.succeeded else {
            throw DroidDeckError(.fileOperationFailed, "Could not copy \(remote) from the device.", detail: result.diagnosticOutput)
        }
    }

    public func listDirectory(_ serial: String, path: String) async throws -> [RemoteFile] {
        let output = try await shell(serial, "ls -la \(ShellQuote.quote(path))", timeout: .seconds(30), allowFailure: true)
        if output.contains("No such file or directory") || output.contains("Permission denied") && !output.contains("\n") {
            throw DroidDeckError(.fileOperationFailed, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return RemoteFile.parseListing(output, directory: path)
    }

    public func makeDirectory(_ serial: String, path: String) async throws {
        try await shell(serial, "mkdir -p \(ShellQuote.quote(path))", timeout: .seconds(20))
    }

    public func remove(_ serial: String, path: String) async throws {
        guard path.hasPrefix("/sdcard/") || path.hasPrefix("/storage/emulated/") || path.hasPrefix("/data/local/tmp/") else {
            throw DroidDeckError(.permission, "DroidDeck only deletes files in shared storage or /data/local/tmp.")
        }
        try await shell(serial, "rm -rf \(ShellQuote.quote(path))", timeout: .seconds(120))
    }

    public func move(_ serial: String, from: String, to: String) async throws {
        try await shell(serial, "mv \(ShellQuote.quote(from)) \(ShellQuote.quote(to))", timeout: .seconds(60))
    }

    /// Asks MediaStore to index a file so it appears in Gallery/Files immediately with full metadata.
    public func scanMedia(_ serial: String, path: String) async throws {
        let uri = "file://" + path
        try await shell(serial, "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(ShellQuote.quote(uri))",
                        timeout: .seconds(20), allowFailure: true)
    }

    // MARK: Logcat

    public func logcat(_ serial: String, tail: Int = 2000) -> AsyncThrowingStream<LogcatEntry, Error> {
        let events = runner.lines(executable, ["-s", serial, "logcat", "-v", "threadtime", "-T", String(tail)])
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case .stdout(let line) = event, let entry = LogcatEntry.parse(line) {
                            continuation.yield(entry)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func clearLogcat(_ serial: String) async throws {
        _ = try await run(["-s", serial, "logcat", "-c"], timeout: .seconds(20))
    }
}

/// Splits the `track-devices` byte stream into message payloads.
struct TrackDevicesParser {
    private var buffer = Data()

    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var messages: [String] = []
        while buffer.count >= 4 {
            let header = String(decoding: buffer.prefix(4), as: UTF8.self)
            guard let length = Int(header, radix: 16) else {
                buffer.removeAll() // Out of sync; wait for the next message.
                break
            }
            guard buffer.count >= 4 + length else { break }
            let payload = buffer.dropFirst(4).prefix(length)
            messages.append(String(decoding: payload, as: UTF8.self))
            buffer.removeFirst(4 + length)
        }
        return messages
    }
}

public struct RemoteFile: Sendable, Equatable, Identifiable, Hashable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int64
    public var modified: String

    public var id: String { path }

    /// Parses toybox `ls -la` output:
    /// "drwxrws--- 2 u0_a160 media_rw 3452 2026-10-28 12:27 DroidDeck"
    static func parseListing(_ text: String, directory: String) -> [RemoteFile] {
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        return text.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard let first = line.first, "-dl".contains(first) else { return nil }
            let fields = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true).map(String.init)
            guard fields.count == 8 else { return nil }
            var name = fields[7]
            if first == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            guard name != ".", name != ".." else { return nil }
            return RemoteFile(name: name, path: base + name, isDirectory: first == "d", isSymlink: first == "l",
                              size: Int64(fields[4]) ?? 0, modified: "\(fields[5]) \(fields[6])")
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }
}

public struct LogcatEntry: Sendable, Identifiable, Hashable {
    public enum Priority: String, Sendable, CaseIterable, Comparable {
        case verbose = "V", debug = "D", info = "I", warning = "W", error = "E", fatal = "F", silent = "S"
        public static func < (a: Priority, b: Priority) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public let id = UUID()
    public var timestamp: String
    public var pid: Int
    public var tid: Int
    public var priority: Priority
    public var tag: String
    public var message: String

    private static let regex = try! NSRegularExpression(
        pattern: #"^(\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\s+(\d+)\s+(\d+)\s+([VDIWEFS])\s+(.*?)\s*: (.*)$"#
    )

    /// Parses `logcat -v threadtime` lines.
    public static func parse(_ line: String) -> LogcatEntry? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = regex.firstMatch(in: line, range: range) else { return nil }
        func g(_ i: Int) -> String { Range(m.range(at: i), in: line).map { String(line[$0]) } ?? "" }
        return LogcatEntry(timestamp: g(1), pid: Int(g(2)) ?? 0, tid: Int(g(3)) ?? 0,
                           priority: Priority(rawValue: g(4)) ?? .info, tag: g(5), message: g(6))
    }

    public static func == (a: LogcatEntry, b: LogcatEntry) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
