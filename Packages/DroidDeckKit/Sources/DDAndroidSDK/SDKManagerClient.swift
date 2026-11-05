import Foundation
import DDCore
import DDPlatform

/// Progress and prompts emitted while sdkmanager installs a package.
public enum SDKInstallEvent: Sendable, Equatable {
    case progress(percent: Int, message: String)
    /// sdkmanager is waiting for the user to accept or decline a license.
    case licenseRequired(id: String, text: String)
    case finished
}

public enum LicenseDecision: Sendable {
    case accept, decline
}

/// Wraps sdkmanager. Licenses are never accepted on the user's behalf: when sdkmanager
/// prompts, the license text is surfaced and the caller supplies the user's decision.
public struct SDKManagerClient: Sendable {
    public let installation: SDKInstallation

    public init(installation: SDKInstallation) {
        self.installation = installation
    }

    private func executable() throws -> URL {
        guard let tool = installation.sdkmanager else {
            throw DroidDeckError(.toolMissing, "Android SDK Command-line Tools are not installed.",
                                 recovery: "Install \"Android SDK Command-line Tools (latest)\" from Android Studio's SDK Manager.")
        }
        guard installation.javaHome != nil else {
            throw DroidDeckError(.toolMissing, "A Java runtime (17 or later) is required by sdkmanager.",
                                 recovery: "Install Android Studio, which bundles a compatible runtime.")
        }
        return tool.url
    }

    /// Fetches the remote repository listing (network access to dl.google.com).
    public func list() async throws -> SDKManagerListing {
        let result = try await installation.runner.run(
            try executable(), ["--sdk_root=\(installation.root.path)", "--list"], timeout: .seconds(120)
        )
        guard result.succeeded else {
            throw DroidDeckError(.toolFailed, "Couldn't check for images.",
                                 recovery: "Another SDK download may be in progress, or the network is unavailable. Try again shortly.",
                                 detail: result.diagnosticOutput)
        }
        return SystemImageCatalog.parseListing(result.stdoutString)
    }

    /// Installs a package, streaming progress. `decide` is awaited whenever a license prompt appears.
    public func install(
        package: String,
        decide: @escaping @Sendable (_ licenseID: String, _ text: String) async -> LicenseDecision,
        progress: @escaping @Sendable (SDKInstallEvent) -> Void
    ) async throws {
        try await runInteractive(arguments: ["--sdk_root=\(installation.root.path)", "--install", package],
                                 decide: decide, progress: progress)
    }

    public func uninstall(package: String) async throws {
        let result = try await installation.runner.run(
            try executable(), ["--sdk_root=\(installation.root.path)", "--uninstall", package], timeout: .seconds(300)
        )
        guard result.succeeded else {
            throw DroidDeckError(.toolFailed, "Could not remove \(package).", detail: result.diagnosticOutput)
        }
    }

    private func runInteractive(
        arguments: [String],
        decide: @escaping @Sendable (String, String) async -> LicenseDecision,
        progress: @escaping @Sendable (SDKInstallEvent) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = arguments
        process.environment = installation.environment
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        process.standardInput = stdin

        let parser = InstallOutputParser()
        let (events, continuation) = AsyncStream<String>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                continuation.finish()
            } else {
                continuation.yield(String(decoding: data, as: UTF8.self))
            }
        }
        try process.run()
        let declined = LockedBox(false)
        try await withTaskCancellationHandler {
            for await chunk in events {
                for event in parser.feed(chunk) {
                    switch event {
                    case .licenseRequired(let id, let text):
                        progress(event)
                        let decision = await decide(id, text)
                        if decision == .decline { declined.value = true }
                        try? stdin.fileHandleForWriting.write(contentsOf: Data((decision == .accept ? "y\n" : "N\n").utf8))
                    default:
                        progress(event)
                    }
                }
            }
        } onCancel: {
            ProcessRunner.terminate(process)
        }
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        if declined.value {
            throw DroidDeckError(.cancelled, "The license was declined, so nothing was installed.")
        }
        guard process.terminationStatus == 0 else {
            throw DroidDeckError(.toolFailed, "sdkmanager failed to install the package.",
                                 detail: Redactor.redact(parser.transcriptTail))
        }
        progress(.finished)
    }
}

/// Recognizes progress bars ("[====   ] 42% Downloading x.zip...") and license prompts in sdkmanager output.
final class InstallOutputParser: @unchecked Sendable {
    private var buffer = ""
    private var transcript = ""
    private let percentRegex = try! NSRegularExpression(pattern: #"(\d{1,3})%\s+([^\r\n\[]*)"#)
    private let licenseRegex = try! NSRegularExpression(pattern: #"License ([A-Za-z0-9._-]+):\s*\n-+\n([\s\S]*?)\n-+\s*\nAccept\? \(y/N\):\s*$"#)

    var transcriptTail: String { String(transcript.suffix(4000)) }

    func feed(_ chunk: String) -> [SDKInstallEvent] {
        buffer += chunk
        transcript += chunk
        var events: [SDKInstallEvent] = []
        let range = NSRange(chunk.startIndex..., in: chunk)
        if let match = percentRegex.matches(in: chunk, range: range).last,
           let pRange = Range(match.range(at: 1), in: chunk), let mRange = Range(match.range(at: 2), in: chunk),
           let percent = Int(chunk[pRange]) {
            events.append(.progress(percent: min(percent, 100), message: chunk[mRange].trimmingCharacters(in: .whitespaces)))
        }
        let bufferRange = NSRange(buffer.startIndex..., in: buffer)
        if let match = licenseRegex.firstMatch(in: buffer, range: bufferRange),
           let idRange = Range(match.range(at: 1), in: buffer), let textRange = Range(match.range(at: 2), in: buffer) {
            events.append(.licenseRequired(id: String(buffer[idRange]), text: String(buffer[textRange])))
            buffer = ""
        } else if buffer.count > 200_000 {
            buffer = String(buffer.suffix(100_000))
        }
        return events
    }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
