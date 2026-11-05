import Foundation
import os

/// Removes secrets from text before it is logged, displayed, or exported.
///
/// Known secret sources on this platform:
/// - emulator discovery files (`grpc.token=…`) and gRPC error messages, which echo the bearer token;
/// - the emulator console auth token (`auth <token>`);
/// - JWTs and base64-encoded JSON blobs passed on other emulators' command lines.
public enum Redactor {
    public enum Level: Sendable {
        /// Secrets only. Used for in-app logs.
        case secrets
        /// Secrets plus personal data (emails, home directory). Used for exported diagnostics.
        case export
    }

    private static let secretRules: [(NSRegularExpression, String)] = [
        (#"(grpc\.token\s*=\s*)\S+"#, "$1<redacted>"),
        (#"(?i)(authorization\s*[:=]\s*)\S+(\s+\S+)?"#, "$1<redacted>"),
        (#"(?i)\bbearer\s+[A-Za-z0-9+/=._~-]+"#, "Bearer <redacted>"),
        (#"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, "<jwt redacted>"),
        (#"eyJ[A-Za-z0-9+/=_-]{16,}"#, "<token redacted>"),
        (#"(?im)^(\s*auth\s+)\S+"#, "$1<redacted>"),
        (#"(?i)\b(password|passwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|token)(["']?\s*[:=]\s*["']?)[^\s"'&,;]+"#, "$1$2<redacted>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static let personalRules: [(NSRegularExpression, String)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func redact(_ text: String, level: Level = .secrets) -> String {
        var result = text
        let rules = level == .export ? secretRules + personalRules : secretRules
        for (regex, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        if level == .export {
            result = result.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        return result
    }
}

public struct LogEntry: Sendable, Identifiable, Hashable {
    public enum Level: String, Sendable, CaseIterable, Comparable {
        case debug, info, notice, warning, error

        public static func < (a: Level, b: Level) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public let id: UUID
    public let date: Date
    public let level: Level
    public let category: String
    public let message: String

    public init(date: Date = Date(), level: Level, category: String, message: String) {
        id = UUID()
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}

/// Application log: os_log, a rotating file in ~/Library/Logs/DroidDeck, and an
/// in-memory ring buffer for the Diagnostics view. Every message is redacted first.
public final class AppLog: @unchecked Sendable {
    public static let shared = AppLog()

    private let subsystem = "app.droiddeck"
    private let lock = NSLock()
    private var buffer: [LogEntry] = []
    private let capacity = 5000
    private var loggers: [String: Logger] = [:]
    private var subscribers: [UUID: AsyncStream<LogEntry>.Continuation] = [:]
    private let fileQueue = DispatchQueue(label: "droiddeck.log.file", qos: .utility)
    public let logDirectory: URL
    private let maxFileBytes: UInt64 = 5 * 1_048_576

    public init(logDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DroidDeck")) {
        self.logDirectory = logDirectory
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    public var logFile: URL { logDirectory.appending(path: "DroidDeck.log") }

    public func log(_ level: LogEntry.Level, _ category: String, _ message: String) {
        let safe = Redactor.redact(message)
        let entry = LogEntry(level: level, category: category, message: safe)
        lock.lock()
        buffer.append(entry)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        let logger = loggers[category] ?? Logger(subsystem: subsystem, category: category)
        loggers[category] = logger
        let targets = Array(subscribers.values)
        lock.unlock()

        switch level {
        case .debug: logger.debug("\(safe, privacy: .public)")
        case .info: logger.info("\(safe, privacy: .public)")
        case .notice: logger.notice("\(safe, privacy: .public)")
        case .warning: logger.warning("\(safe, privacy: .public)")
        case .error: logger.error("\(safe, privacy: .public)")
        }
        targets.forEach { $0.yield(entry) }
        if level >= .info { appendToFile(entry) }
    }

    public func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    public func info(_ category: String, _ message: String) { log(.info, category, message) }
    public func notice(_ category: String, _ message: String) { log(.notice, category, message) }
    public func warning(_ category: String, _ message: String) { log(.warning, category, message) }
    public func error(_ category: String, _ message: String) { log(.error, category, message) }

    public func recentEntries() -> [LogEntry] { lock.withLock { buffer } }

    public func stream() -> AsyncStream<LogEntry> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LogEntry>.makeStream(bufferingPolicy: .bufferingNewest(500))
        lock.withLock { subscribers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    private func appendToFile(_ entry: LogEntry) {
        let file = logFile
        let line = "\(entry.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))) [\(entry.level.rawValue)] \(entry.category): \(entry.message)\n"
        let limit = maxFileBytes
        fileQueue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? UInt64, size > limit {
                let rotated = file.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: file, to: rotated)
            }
            if !fm.fileExists(atPath: file.path) {
                fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
    }
}

public let log = AppLog.shared
