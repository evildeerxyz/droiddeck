import Foundation
import DDCore

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 }

    /// Combined output for error reporting, redacted and trimmed.
    public var diagnosticOutput: String {
        let text = [stdoutString, stderrString].filter { !$0.isEmpty }.joined(separator: "\n")
        return Redactor.redact(String(text.suffix(4000))).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ProcessOutputEvent: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exited(Int32)
}

public enum ProcessRunnerError: Error, Sendable, CustomStringConvertible {
    case launchFailed(String, String)
    case timedOut(String, Duration)
    case cancelled(String)

    public var description: String {
        switch self {
        case .launchFailed(let tool, let reason): return "Could not launch \(tool): \(reason)"
        case .timedOut(let tool, let after): return "\(tool) did not finish within \(after)"
        case .cancelled(let tool): return "\(tool) was cancelled"
        }
    }
}

/// Runs external tools with an explicit environment. GUI apps inherit a minimal
/// PATH, so callers always pass absolute executable URLs.
public struct ProcessRunner: Sendable {
    public var environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func with(environment overrides: [String: String]) -> ProcessRunner {
        var copy = self
        copy.environment.merge(overrides) { _, new in new }
        return copy
    }

    /// Runs to completion and collects output. Cancelling the task terminates the process.
    public func run(
        _ executable: URL,
        _ arguments: [String],
        input: Data? = nil,
        timeout: Duration? = .seconds(120),
        currentDirectory: URL? = nil
    ) async throws -> ProcessResult {
        let toolName = executable.lastPathComponent
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = input == nil ? FileHandle.nullDevice : stdinPipe

        let collector = OutputCollector()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            collector.append(data, isStdout: true)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            collector.append(data, isStdout: false)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                collector.setContinuation(continuation)
                process.terminationHandler = { proc in
                    collector.processExited(code: proc.terminationStatus)
                    // A forked daemon (e.g. the adb server) can inherit the pipes and keep
                    // them open; stop waiting for EOF after a short grace period.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        collector.forceFinish()
                    }
                }
                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    collector.fail(ProcessRunnerError.launchFailed(toolName, error.localizedDescription))
                    return
                }
                collector.setPID(process.processIdentifier)
                if let input {
                    let handle = stdinPipe.fileHandleForWriting
                    DispatchQueue.global().async {
                        try? handle.write(contentsOf: input)
                        try? handle.close()
                    }
                }
                if let timeout {
                    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                        guard process.isRunning else { return }
                        collector.fail(ProcessRunnerError.timedOut(toolName, timeout))
                        ProcessRunner.terminate(process)
                    }
                }
            }
        } onCancel: {
            collector.fail(ProcessRunnerError.cancelled(toolName))
            ProcessRunner.terminate(process)
        }
    }

    /// Streams output line by line. Terminating the stream terminates the process.
    public func lines(
        _ executable: URL,
        _ arguments: [String],
        currentDirectory: URL? = nil
    ) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            let splitter = LineSplitter()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                for line in splitter.feed(data, stdout: true) { continuation.yield(.stdout(line)) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                for line in splitter.feed(data, stdout: false) { continuation.yield(.stderr(line)) }
            }
            process.terminationHandler = { proc in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    for line in splitter.flush() { continuation.yield(line.stdout ? .stdout(line.text) : .stderr(line.text)) }
                    continuation.yield(.exited(proc.terminationStatus))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in ProcessRunner.terminate(process) }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: ProcessRunnerError.launchFailed(executable.lastPathComponent, error.localizedDescription))
            }
        }
    }

    /// Streams raw stdout bytes. Terminating the stream terminates the process.
    public func chunks(_ executable: URL, _ arguments: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    continuation.yield(data)
                }
            }
            process.terminationHandler = { _ in continuation.finish() }
            continuation.onTermination = { _ in ProcessRunner.terminate(process) }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: ProcessRunnerError.launchFailed(executable.lastPathComponent, error.localizedDescription))
            }
        }
    }

    /// SIGTERM, then SIGKILL if the process is still alive after a grace period.
    public static func terminate(_ process: Process, grace: TimeInterval = 3) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Thread-safe accumulation of output and single resumption of the continuation.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutEOF = false
    private var stderrEOF = false
    private var exitCode: Int32?
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var pendingFailure: Error?
    private var finished = false
    private var pid: Int32 = 0

    func setContinuation(_ c: CheckedContinuation<ProcessResult, Error>) {
        lock.lock()
        if let pendingFailure, !finished {
            finished = true
            lock.unlock()
            c.resume(throwing: pendingFailure)
            return
        }
        continuation = c
        lock.unlock()
    }

    func setPID(_ pid: Int32) { lock.withLock { self.pid = pid } }

    func append(_ data: Data, isStdout: Bool) {
        lock.lock()
        if data.isEmpty {
            if isStdout { stdoutEOF = true } else { stderrEOF = true }
        } else if isStdout {
            stdout.append(data)
        } else {
            stderr.append(data)
        }
        let ready = stdoutEOF && stderrEOF && exitCode != nil
        lock.unlock()
        if ready { forceFinish() }
    }

    func processExited(code: Int32) {
        lock.lock()
        exitCode = code
        let ready = stdoutEOF && stderrEOF
        lock.unlock()
        if ready { forceFinish() }
    }

    func forceFinish() {
        lock.lock()
        guard !finished, let code = exitCode, let continuation else { lock.unlock(); return }
        finished = true
        let result = ProcessResult(exitCode: code, stdout: stdout, stderr: stderr)
        lock.unlock()
        continuation.resume(returning: result)
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard let continuation else {
            pendingFailure = error
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.resume(throwing: error)
    }
}

/// Splits arbitrary chunks into UTF-8 lines per stream.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [Bool: Data] = [true: Data(), false: Data()]

    func feed(_ data: Data, stdout: Bool) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var buffer = buffers[stdout] ?? Data()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        buffers[stdout] = buffer
        return lines
    }

    func flush() -> [(text: String, stdout: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        var out: [(String, Bool)] = []
        for key in [true, false] {
            if let data = buffers[key], !data.isEmpty {
                out.append((String(decoding: data, as: UTF8.self), key))
            }
            buffers[key] = Data()
        }
        return out
    }
}

/// A long-running child process (the emulator) whose output goes to a log file.
public final class LaunchedProcess: @unchecked Sendable {
    public let pid: Int32
    public let logFile: URL
    private let process: Process
    private let exit = ExitState()

    public var isRunning: Bool { process.isRunning }
    public var terminationStatus: Int32? { exit.status }

    public init(executable: URL, arguments: [String], environment: [String: String], logFile: URL) throws {
        try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logFile)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        let exit = self.exit
        process.terminationHandler = { proc in
            try? handle.close()
            exit.record(proc.terminationStatus)
        }
        try process.run()
        self.process = process
        self.logFile = logFile
        pid = process.processIdentifier
    }

    public func waitForExit() async -> Int32 { await exit.wait() }

    public func terminate() { ProcessRunner.terminate(process) }
    public func kill() { if process.isRunning { Darwin.kill(pid, SIGKILL) } }

    /// The last lines of the process log, redacted.
    public func logTail(maxBytes: Int = 8000) -> String {
        guard let data = try? Data(contentsOf: logFile) else { return "" }
        return Redactor.redact(String(decoding: data.suffix(maxBytes), as: UTF8.self))
    }
}

final class ExitState: @unchecked Sendable {
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    var status: Int32? { lock.withLock { exitStatus } }

    func record(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: status) }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

public enum ProcessLiveness {
    /// True when a process with this pid exists (even if owned by another user).
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

/// macOS scheduling class for a process DroidDeck launched.
public enum ProcessPriority {
    /// Background ("darwinbg"): lowest CPU priority, throttled disk I/O and, on Apple silicon, the
    /// efficiency cores. Invisible to the guest. Returns false if macOS refused.
    @discardableResult
    public static func setBackground(_ pid: Int32, _ background: Bool) -> Bool {
        setpriority(PRIO_DARWIN_PROCESS, id_t(pid), background ? PRIO_DARWIN_BG : 0) == 0
    }

    public static func isBackground(_ pid: Int32) -> Bool {
        errno = 0
        let value = getpriority(PRIO_DARWIN_PROCESS, id_t(pid))
        return errno == 0 && value != 0
    }
}
