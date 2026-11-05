import Foundation
import CryptoKit
import DDCore
import DDPlatform
import DDADB
import DDEmulatorGRPC

/// One step of an automation workflow. Coordinates are normalized (0...1) to the screen.
public enum WorkflowStep: Codable, Sendable, Equatable, Hashable {
    case launchApp(package: String)
    case stopApp(package: String)
    case installAPK(path: String)
    case tap(x: Double, y: Double)
    case swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, milliseconds: Int)
    case typeText(String)
    case keyEvent(code: Int)
    case wait(seconds: Double)
    case screenshot
    case setLocation(latitude: Double, longitude: Double)
    case pushFile(localPath: String, remotePath: String)
    /// Arbitrary device shell command. Always highlighted during review.
    case shell(String)

    public var title: String {
        switch self {
        case .launchApp(let p): return "Launch \(p)"
        case .stopApp(let p): return "Force stop \(p)"
        case .installAPK(let path): return "Install \((path as NSString).lastPathComponent)"
        case .tap(let x, let y): return String(format: "Tap at %.0f%%, %.0f%%", x * 100, y * 100)
        case .swipe(let fx, let fy, let tx, let ty, let ms):
            return String(format: "Swipe %.0f%%,%.0f%% → %.0f%%,%.0f%% (%d ms)", fx * 100, fy * 100, tx * 100, ty * 100, ms)
        case .typeText(let text): return "Type \"\(text.prefix(40))\""
        case .keyEvent(let code): return "Key \(code)"
        case .wait(let s): return "Wait \(s.formatted()) s"
        case .screenshot: return "Take screenshot"
        case .setLocation(let lat, let lon): return String(format: "Set location %.4f, %.4f", lat, lon)
        case .pushFile(let local, let remote): return "Copy \((local as NSString).lastPathComponent) → \(remote)"
        case .shell(let command): return "Shell: \(command)"
        }
    }

    /// Steps that can change the device or read local files beyond simple input.
    public var isSensitive: Bool {
        switch self {
        case .shell, .installAPK, .pushFile: return true
        default: return false
        }
    }
}

public struct Workflow: Codable, Sendable, Identifiable, Equatable {
    public enum Origin: String, Codable, Sendable { case createdInDroidDeck, imported }

    public var id: UUID
    public var name: String
    public var steps: [WorkflowStep]
    public var origin: Origin
    /// Hash of the steps the user reviewed and approved. Any change invalidates approval.
    public var approvedHash: String?
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, steps: [WorkflowStep], origin: Origin, approvedHash: String? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.steps = steps
        self.origin = origin
        self.approvedHash = approvedHash
        self.updatedAt = updatedAt
    }

    public var contentHash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(steps)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Workflows run only after the user has approved exactly these steps.
    public var isApproved: Bool { approvedHash == contentHash }

    public mutating func approve() { approvedHash = contentHash }

    /// Imports a workflow file. Imported workflows are never approved on import.
    public static func importing(from url: URL) throws -> Workflow {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var workflow = try decoder.decode(Workflow.self, from: data)
        workflow.id = UUID()
        workflow.origin = .imported
        workflow.approvedHash = nil
        return workflow
    }

    public func exportData() throws -> Data {
        var copy = self
        copy.approvedHash = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(copy)
    }
}

public actor WorkflowStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load() -> [Workflow] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Workflow.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ workflow: Workflow) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try SafeFileOperations.writeAtomically(try encoder.encode(workflow), to: directory.appending(path: "\(workflow.id.uuidString).json"))
    }

    public func delete(_ workflow: Workflow) throws {
        let url = directory.appending(path: "\(workflow.id.uuidString).json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// Executes approved workflows step by step with progress and cancellation.
public struct WorkflowRunner: Sendable {
    public let adb: ADBClient
    public let controller: EmulatorControllerClient?
    public let screenshotDirectory: URL

    public init(adb: ADBClient, controller: EmulatorControllerClient?, screenshotDirectory: URL) {
        self.adb = adb
        self.controller = controller
        self.screenshotDirectory = screenshotDirectory
    }

    public func run(_ workflow: Workflow, serial: String, progress: @Sendable (Int, WorkflowStep) -> Void) async throws {
        guard workflow.isApproved else {
            throw DroidDeckError(.permission, "Review and approve \"\(workflow.name)\" before running it.",
                                 recovery: "Imported or changed workflows must be approved step by step.")
        }
        let size = try await screenSize(serial)
        for (index, step) in workflow.steps.enumerated() {
            try Task.checkCancellation()
            progress(index, step)
            log.info("automation", "\(workflow.name) step \(index + 1): \(step.title)")
            try await execute(step, serial: serial, size: size)
        }
    }

    /// `wm size` → "Physical size: 1080x2400" (and "Override size: …" when set).
    func screenSize(_ serial: String) async throws -> (width: Int, height: Int) {
        let output = try await adb.shell(serial, "wm size", timeout: .seconds(10), allowFailure: true)
        let line = output.split(separator: "\n").last { $0.contains("size:") } ?? ""
        let dims = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces).split(separator: "x").compactMap { Int($0) } ?? []
        guard dims.count == 2 else { throw DroidDeckError(.toolFailed, "Could not read the device's screen size.", detail: output) }
        return (dims[0], dims[1])
    }

    private func execute(_ step: WorkflowStep, serial: String, size: (width: Int, height: Int)) async throws {
        func px(_ x: Double, _ y: Double) -> (Int, Int) { (Int(x * Double(size.width)), Int(y * Double(size.height))) }
        switch step {
        case .launchApp(let package): try await adb.launch(serial, package: package)
        case .stopApp(let package): try await adb.forceStop(serial, package: package)
        case .installAPK(let path): _ = try await adb.install(serial, apks: [URL(fileURLWithPath: path)], options: InstallOptions())
        case .tap(let x, let y):
            let p = px(x, y)
            try await adb.shell(serial, "input tap \(p.0) \(p.1)", timeout: .seconds(15))
        case .swipe(let fx, let fy, let tx, let ty, let ms):
            let a = px(fx, fy), b = px(tx, ty)
            try await adb.shell(serial, "input swipe \(a.0) \(a.1) \(b.0) \(b.1) \(max(50, ms))", timeout: .seconds(30))
        case .typeText(let text):
            if let controller {
                try await controller.send(.text(text))
            } else {
                // `input text` needs spaces encoded as %s.
                try await adb.shell(serial, "input text \(ShellQuote.quote(text.replacingOccurrences(of: " ", with: "%s")))", timeout: .seconds(30))
            }
        case .keyEvent(let code): try await adb.keyevent(serial, code)
        case .wait(let seconds): try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        case .screenshot:
            let png = try await adb.screenshotPNG(serial)
            let name = "Automation \(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")).png"
            try SafeFileOperations.writeAtomically(png, to: screenshotDirectory.appending(path: name))
        case .setLocation(let lat, let lon):
            if let controller {
                try await controller.setGPS(EmulatorGPSState(latitude: lat, longitude: lon))
            } else {
                _ = try await adb.emu(serial, ["geo", "fix", String(lon), String(lat)])
            }
        case .pushFile(let local, let remote): try await adb.push(serial, local: URL(fileURLWithPath: local), remote: remote)
        case .shell(let command): try await adb.shell(serial, command, timeout: .seconds(120))
        }
    }
}
