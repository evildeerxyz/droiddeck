import Foundation

/// gRPC status as reported in trailers (https://grpc.github.io/grpc/core/md_doc_statuscodes.html).
public struct GRPCStatusError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int
    public let message: String

    public static let cancelled = 1
    public static let invalidArgument = 3
    public static let deadlineExceeded = 4
    public static let notFound = 5
    public static let failedPrecondition = 9
    public static let unimplemented = 12
    public static let internalError = 13
    public static let unavailable = 14
    public static let unauthenticated = 16

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String {
        let name: String
        switch code {
        case 1: name = "CANCELLED"
        case 3: name = "INVALID_ARGUMENT"
        case 4: name = "DEADLINE_EXCEEDED"
        case 5: name = "NOT_FOUND"
        case 7: name = "PERMISSION_DENIED"
        case 9: name = "FAILED_PRECONDITION"
        case 12: name = "UNIMPLEMENTED"
        case 13: name = "INTERNAL"
        case 14: name = "UNAVAILABLE"
        case 16: name = "UNAUTHENTICATED"
        default: name = "STATUS \(code)"
        }
        return message.isEmpty ? name : "\(name): \(message)"
    }
}

/// Incrementally splits a byte stream into length-prefixed gRPC messages.
struct GRPCMessageFramer {
    private var buffer: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) throws -> [[UInt8]] {
        buffer.append(contentsOf: bytes)
        var messages: [[UInt8]] = []
        var offset = 0
        while buffer.count - offset >= 5 {
            let compressed = buffer[offset]
            let length = Int(buffer[offset + 1]) << 24 | Int(buffer[offset + 2]) << 16
                | Int(buffer[offset + 3]) << 8 | Int(buffer[offset + 4])
            guard buffer.count - offset - 5 >= length else { break }
            guard compressed == 0 else {
                throw GRPCStatusError(code: GRPCStatusError.internalError, message: "compressed messages are not supported")
            }
            messages.append(Array(buffer[(offset + 5)..<(offset + 5 + length)]))
            offset += 5 + length
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return messages
    }

    static func frame(_ message: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0]
        out.appendUInt32(UInt32(message.count))
        out.append(contentsOf: message)
        return out
    }
}

/// Interprets HTTP/2 events for one gRPC call and produces messages and a final status.
final class GRPCCallState: @unchecked Sendable {
    private var framer = GRPCMessageFramer()
    private var sawResponseHeaders = false
    private let lock = NSLock()

    enum Output {
        case messages([[UInt8]])
        case finished(Error?)
    }

    func handle(_ event: HTTP2StreamEvent) -> [Output] {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .headers(let headers, let endStream):
            if !sawResponseHeaders {
                sawResponseHeaders = true
                if let status = headers.first(where: { $0.name == ":status" })?.value, status != "200" {
                    return [.finished(GRPCStatusError(code: GRPCStatusError.unavailable, message: "HTTP status \(status)"))]
                }
                // Trailers-only response carries grpc-status in the first HEADERS.
                if endStream { return [.finished(Self.status(from: headers))] }
                return []
            }
            return [.finished(Self.status(from: headers))]
        case .data(let bytes, let endStream):
            var outputs: [Output] = []
            do {
                let messages = try framer.append(bytes)
                if !messages.isEmpty { outputs.append(.messages(messages)) }
            } catch {
                outputs.append(.finished(error))
                return outputs
            }
            if endStream {
                outputs.append(.finished(GRPCStatusError(code: GRPCStatusError.internalError, message: "stream ended without trailers")))
            }
            return outputs
        case .reset(let code):
            let status = code == 0x8 ? GRPCStatusError.cancelled : GRPCStatusError.unavailable
            return [.finished(GRPCStatusError(code: status, message: "stream reset (\(code))"))]
        case .connectionClosed(let error):
            return [.finished(GRPCStatusError(code: GRPCStatusError.unavailable, message: error.description))]
        }
    }

    static func status(from headers: [HeaderField]) -> Error? {
        guard let raw = headers.first(where: { $0.name == "grpc-status" })?.value, let code = Int(raw) else {
            return GRPCStatusError(code: GRPCStatusError.internalError, message: "missing grpc-status")
        }
        if code == 0 { return nil }
        let message = headers.first(where: { $0.name == "grpc-message" })?.value.removingPercentEncoding ?? ""
        return GRPCStatusError(code: code, message: message)
    }
}

/// A gRPC channel to a single local endpoint. Reconnects lazily after failures.
public actor GRPCChannel {
    public let host: String
    public let port: UInt16
    private let bearerToken: String?
    private var connection: HTTP2Connection?

    public init(host: String = "127.0.0.1", port: UInt16, bearerToken: String?) {
        self.host = host
        self.port = port
        self.bearerToken = bearerToken
    }

    private func liveConnection() async throws -> HTTP2Connection {
        if let connection, !connection.isUnusable {
            return connection
        }
        let fresh = try await HTTP2Connection.connect(host: host, port: port)
        connection = fresh
        return fresh
    }

    public func shutdown() {
        connection?.close()
        connection = nil
    }

    private func requestHeaders(path: String) -> [HeaderField] {
        var headers = [
            HeaderField(":method", "POST"),
            HeaderField(":scheme", "http"),
            HeaderField(":path", path),
            HeaderField(":authority", "\(host):\(port)"),
            HeaderField("content-type", "application/grpc"),
            HeaderField("te", "trailers"),
            HeaderField("user-agent", "DroidDeck/1.0 grpc-swift-minimal"),
        ]
        if let bearerToken {
            headers.append(HeaderField("authorization", "Bearer \(bearerToken)", sensitive: true))
        }
        return headers
    }

    /// Unary call: one request, one response.
    public func unary(path: String, request: [UInt8], timeout: Duration = .seconds(10)) async throws -> [UInt8] {
        let connection = try await liveConnection()
        let state = GRPCCallState()
        let box = UnaryResultBox()
        let streamID = try await connection.openStream(headers: requestHeaders(path: path), endStream: false) { event in
            for output in state.handle(event) {
                switch output {
                case .messages(let messages): box.store(messages.first)
                case .finished(let error): box.finish(error)
                }
            }
        }
        connection.send(streamID: streamID, data: GRPCMessageFramer.frame(request), endStream: true)
        return try await withTaskCancellationHandler {
            try await box.wait(timeout: timeout)
        } onCancel: {
            connection.cancel(streamID: streamID)
            box.finish(GRPCStatusError(code: GRPCStatusError.cancelled, message: "cancelled"))
        }
    }

    /// Server-streaming call. Terminating the returned sequence cancels the RPC.
    /// Use `.bufferingNewest(n)` for lossy streams such as video frames.
    public func serverStreaming(
        path: String,
        request: [UInt8],
        bufferingPolicy: AsyncThrowingStream<[UInt8], Error>.Continuation.BufferingPolicy = .unbounded
    ) async throws -> AsyncThrowingStream<[UInt8], Error> {
        let connection = try await liveConnection()
        let state = GRPCCallState()
        let (stream, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream(bufferingPolicy: bufferingPolicy)
        let streamID = try await connection.openStream(headers: requestHeaders(path: path), endStream: false) { event in
            for output in state.handle(event) {
                switch output {
                case .messages(let messages): messages.forEach { continuation.yield($0) }
                case .finished(let error): continuation.finish(throwing: error)
                }
            }
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination { connection.cancel(streamID: streamID) }
        }
        connection.send(streamID: streamID, data: GRPCMessageFramer.frame(request), endStream: true)
        return stream
    }

    /// Client-streaming call. Messages are delivered in order on a single HTTP/2 stream.
    public func clientStreaming(path: String) async throws -> GRPCClientStream {
        let connection = try await liveConnection()
        let state = GRPCCallState()
        let box = UnaryResultBox()
        let streamID = try await connection.openStream(headers: requestHeaders(path: path), endStream: false) { event in
            for output in state.handle(event) {
                switch output {
                case .messages(let messages): box.store(messages.first)
                case .finished(let error): box.finish(error)
                }
            }
        }
        return GRPCClientStream(connection: connection, streamID: streamID, result: box)
    }
}

/// Writer half of a client-streaming call.
public final class GRPCClientStream: Sendable {
    private let connection: HTTP2Connection
    private let streamID: UInt32
    private let result: UnaryResultBox

    init(connection: HTTP2Connection, streamID: UInt32, result: UnaryResultBox) {
        self.connection = connection
        self.streamID = streamID
        self.result = result
    }

    /// True after the server has ended the call (error or completion).
    public var isFinished: Bool { result.isFinished }

    public func send(_ message: [UInt8]) {
        connection.send(streamID: streamID, data: GRPCMessageFramer.frame(message), endStream: false)
    }

    public func finish(timeout: Duration = .seconds(5)) async throws {
        connection.send(streamID: streamID, data: [], endStream: true)
        _ = try await result.wait(timeout: timeout)
    }

    public func cancel() {
        connection.cancel(streamID: streamID)
        result.finish(GRPCStatusError(code: GRPCStatusError.cancelled, message: "cancelled"))
    }
}

/// Collects the single response message and terminal status of a call.
final class UnaryResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var message: [UInt8]?
    private var outcome: Result<[UInt8], Error>?
    private var waiter: CheckedContinuation<[UInt8], Error>?

    var isFinished: Bool { lock.withLock { outcome != nil } }

    func store(_ value: [UInt8]?) {
        lock.withLock { if message == nil { message = value } }
    }

    func finish(_ error: Error?) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        let result: Result<[UInt8], Error> = error.map { .failure($0) } ?? .success(message ?? [])
        outcome = result
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func wait(timeout: Duration) async throws -> [UInt8] {
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(GRPCStatusError(code: GRPCStatusError.deadlineExceeded, message: "no response within \(timeout)"))
        }
        defer { deadline.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
