import Foundation
import Network

/// Events delivered for a single HTTP/2 stream, in order, on the connection's queue.
public enum HTTP2StreamEvent: Sendable {
    case headers([HeaderField], endStream: Bool)
    case data([UInt8], endStream: Bool)
    case reset(errorCode: UInt32)
    case connectionClosed(HTTP2Error)
}

public enum HTTP2Error: Error, Sendable, Equatable, CustomStringConvertible {
    case connectionFailed(String)
    case connectTimedOut
    case protocolError(String)
    case goAway(errorCode: UInt32)
    case closed

    public var description: String {
        switch self {
        case .connectionFailed(let reason): return "Connection failed: \(reason)"
        case .connectTimedOut: return "Connection timed out"
        case .protocolError(let reason): return "HTTP/2 protocol error: \(reason)"
        case .goAway(let code): return "Server closed the connection (GOAWAY \(code))"
        case .closed: return "Connection closed"
        }
    }
}

/// A minimal HTTP/2 client (RFC 9113) over cleartext TCP with prior knowledge,
/// sufficient for gRPC against the Android Emulator's local gRPC endpoint.
///
/// Thread-safety: all mutable state is confined to `queue`. Public methods hop onto it.
public final class HTTP2Connection: @unchecked Sendable {
    public typealias StreamHandler = @Sendable (HTTP2StreamEvent) -> Void

    // Our receive-side parameters.
    static let localMaxFrameSize = 1 << 20               // SETTINGS_MAX_FRAME_SIZE we advertise
    static let localInitialStreamWindow = 16 << 20        // SETTINGS_INITIAL_WINDOW_SIZE we advertise
    static let localConnectionWindow = 64 << 20
    static let windowUpdateThreshold = 4 << 20

    private enum FrameType: UInt8 {
        case data = 0, headers = 1, priority = 2, rstStream = 3, settings = 4
        case pushPromise = 5, ping = 6, goAway = 7, windowUpdate = 8, continuation = 9
    }

    private final class StreamState {
        let handler: StreamHandler
        var sendWindow: Int
        var pending: [UInt8] = []
        var pendingEndStream = false
        var localClosed = false
        var recvUnacked = 0
        init(handler: @escaping StreamHandler, sendWindow: Int) {
            self.handler = handler
            self.sendWindow = sendWindow
        }
    }

    private let queue: DispatchQueue
    private let connection: NWConnection
    private var streams: [UInt32: StreamState] = [:]
    private var nextStreamID: UInt32 = 1
    private let encoder = HPACKEncoder()
    private var decoder = HPACKDecoder()
    private var readBuffer: [UInt8] = []
    private var readOffset = 0
    private var peerMaxFrameSize = 16_384
    private var peerInitialWindow = 65_535
    private var connectionSendWindow = 65_535
    private var connectionRecvUnacked = 0
    private var headerAccumulator: (streamID: UInt32, block: [UInt8], endStream: Bool)?
    private var goAwayReceived = false
    private(set) var closedError: HTTP2Error?
    private var closeObservers: [@Sendable (HTTP2Error) -> Void] = []

    private let unusableFlag = LockedFlag()
    /// True once the connection can no longer open streams (closed, failed, or GOAWAY received).
    public var isUnusable: Bool { unusableFlag.value }

    private init(host: String, port: UInt16) {
        queue = DispatchQueue(label: "droiddeck.http2.\(host):\(port)", qos: .userInitiated)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
    }

    /// Opens a TCP connection and performs the HTTP/2 connection preface.
    public static func connect(host: String, port: UInt16, timeout: Duration = .seconds(5)) async throws -> HTTP2Connection {
        let conn = HTTP2Connection(host: host, port: port)
        try await conn.start(timeout: timeout)
        return conn
    }

    private func start(timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeOnce(continuation)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendPreface()
                    self.receiveLoop()
                    resumed.resume(with: .success(()))
                case .waiting(let error):
                    // Loopback refusal surfaces as .waiting; treat as a hard failure.
                    resumed.resume(with: .failure(HTTP2Error.connectionFailed(error.localizedDescription)))
                    self.connection.cancel()
                case .failed(let error):
                    resumed.resume(with: .failure(HTTP2Error.connectionFailed(error.localizedDescription)))
                    self.fail(.connectionFailed(error.localizedDescription))
                case .cancelled:
                    self.fail(.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                if resumed.resume(with: .failure(HTTP2Error.connectTimedOut)) {
                    self?.connection.cancel()
                }
            }
        }
    }

    // MARK: Public API

    /// Opens a new stream by sending HEADERS. Returns the stream identifier.
    public func openStream(headers: [HeaderField], endStream: Bool, handler: @escaping StreamHandler) async throws -> UInt32 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let error = self.closedError {
                    continuation.resume(throwing: error)
                    return
                }
                if self.goAwayReceived {
                    continuation.resume(throwing: HTTP2Error.closed)
                    return
                }
                let id = self.nextStreamID
                self.nextStreamID += 2
                let state = StreamState(handler: handler, sendWindow: self.peerInitialWindow)
                state.localClosed = endStream
                self.streams[id] = state
                self.writeHeaders(streamID: id, block: self.encoder.encode(headers), endStream: endStream)
                continuation.resume(returning: id)
            }
        }
    }

    /// Queues DATA on a stream, respecting the peer's flow-control windows.
    public func send(streamID: UInt32, data: [UInt8], endStream: Bool) {
        queue.async {
            guard self.closedError == nil, let stream = self.streams[streamID], !stream.localClosed else { return }
            stream.pending.append(contentsOf: data)
            if endStream {
                stream.pendingEndStream = true
            }
            self.flush(streamID: streamID, stream: stream)
        }
    }

    /// Cancels a stream (RST_STREAM with CANCEL).
    public func cancel(streamID: UInt32) {
        queue.async {
            guard self.streams.removeValue(forKey: streamID) != nil else { return }
            var payload: [UInt8] = []
            payload.appendUInt32(0x8)
            self.writeFrame(.rstStream, flags: 0, streamID: streamID, payload: payload)
        }
    }

    public func close() {
        queue.async { self.fail(.closed) }
    }

    public func onClose(_ observer: @escaping @Sendable (HTTP2Error) -> Void) {
        queue.async {
            if let error = self.closedError {
                observer(error)
            } else {
                self.closeObservers.append(observer)
            }
        }
    }

    // MARK: Writing

    private func sendPreface() {
        var bytes = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        var settings: [UInt8] = []
        settings.appendSetting(0x2, 0)                                       // ENABLE_PUSH
        settings.appendSetting(0x4, UInt32(Self.localInitialStreamWindow))   // INITIAL_WINDOW_SIZE
        settings.appendSetting(0x5, UInt32(Self.localMaxFrameSize))          // MAX_FRAME_SIZE
        bytes.append(contentsOf: Self.frameHeader(length: settings.count, type: .settings, flags: 0, streamID: 0))
        bytes.append(contentsOf: settings)
        var increment: [UInt8] = []
        increment.appendUInt32(UInt32(Self.localConnectionWindow - 65_535))
        bytes.append(contentsOf: Self.frameHeader(length: 4, type: .windowUpdate, flags: 0, streamID: 0))
        bytes.append(contentsOf: increment)
        write(bytes)
    }

    private func writeHeaders(streamID: UInt32, block: [UInt8], endStream: Bool) {
        var offset = 0
        var first = true
        repeat {
            let chunk = min(block.count - offset, peerMaxFrameSize)
            let last = offset + chunk >= block.count
            var flags: UInt8 = last ? 0x4 : 0
            if first && endStream { flags |= 0x1 }
            writeFrame(first ? .headers : .continuation, flags: flags, streamID: streamID,
                       payload: Array(block[offset..<offset + chunk]))
            offset += chunk
            first = false
        } while offset < block.count
    }

    private func flush(streamID: UInt32, stream: StreamState) {
        while !stream.pending.isEmpty {
            let allowed = min(stream.pending.count, peerMaxFrameSize, stream.sendWindow, connectionSendWindow)
            guard allowed > 0 else {
                trace("blocked stream=\(streamID) pending=\(stream.pending.count) streamWindow=\(stream.sendWindow) connWindow=\(connectionSendWindow)")
                return // Wait for WINDOW_UPDATE.
            }
            let chunk = Array(stream.pending.prefix(allowed))
            stream.pending.removeFirst(allowed)
            stream.sendWindow -= allowed
            connectionSendWindow -= allowed
            let end = stream.pending.isEmpty && stream.pendingEndStream
            writeFrame(.data, flags: end ? 0x1 : 0, streamID: streamID, payload: chunk)
            if end {
                stream.localClosed = true
            }
        }
        if stream.pendingEndStream && !stream.localClosed {
            writeFrame(.data, flags: 0x1, streamID: streamID, payload: [])
            stream.localClosed = true
        }
    }

    /// Set DROIDDECK_HTTP2_TRACE=1 to print frame-level traces (never includes header values).
    static let traceEnabled = ProcessInfo.processInfo.environment["DROIDDECK_HTTP2_TRACE"] == "1"

    private func trace(_ message: @autoclosure () -> String) {
        if Self.traceEnabled { print("[http2] \(message())") }
    }

    private func writeFrame(_ type: FrameType, flags: UInt8, streamID: UInt32, payload: [UInt8]) {
        trace("send \(type) stream=\(streamID) flags=\(flags) len=\(payload.count)")
        var bytes = Self.frameHeader(length: payload.count, type: type, flags: flags, streamID: streamID)
        bytes.append(contentsOf: payload)
        write(bytes)
    }

    private func write(_ bytes: [UInt8]) {
        guard closedError == nil else { return }
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error {
                self?.fail(.connectionFailed(error.localizedDescription))
            }
        })
    }

    private static func frameHeader(length: Int, type: FrameType, flags: UInt8, streamID: UInt32) -> [UInt8] {
        [
            UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
            type.rawValue, flags,
            UInt8((streamID >> 24) & 0x7F), UInt8((streamID >> 16) & 0xFF),
            UInt8((streamID >> 8) & 0xFF), UInt8(streamID & 0xFF),
        ]
    }

    // MARK: Reading

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.readBuffer.append(contentsOf: data)
                self.parseFrames()
            }
            if let error {
                self.fail(.connectionFailed(error.localizedDescription))
                return
            }
            if isComplete {
                self.fail(.closed)
                return
            }
            if self.closedError == nil {
                self.receiveLoop()
            }
        }
    }

    private func parseFrames() {
        while closedError == nil {
            let available = readBuffer.count - readOffset
            guard available >= 9 else { break }
            let base = readOffset
            let length = Int(readBuffer[base]) << 16 | Int(readBuffer[base + 1]) << 8 | Int(readBuffer[base + 2])
            guard length <= Self.localMaxFrameSize else {
                fatalProtocolError("frame of \(length) bytes exceeds advertised maximum", code: 0x6)
                return
            }
            guard available >= 9 + length else { break }
            let typeByte = readBuffer[base + 3]
            let flags = readBuffer[base + 4]
            let streamID = (UInt32(readBuffer[base + 5]) & 0x7F) << 24 | UInt32(readBuffer[base + 6]) << 16
                | UInt32(readBuffer[base + 7]) << 8 | UInt32(readBuffer[base + 8])
            let payload = Array(readBuffer[(base + 9)..<(base + 9 + length)])
            readOffset += 9 + length
            handleFrame(typeByte: typeByte, flags: flags, streamID: streamID, payload: payload)
        }
        if readOffset > 0 && (readOffset == readBuffer.count || readOffset > 1 << 20) {
            readBuffer.removeFirst(readOffset)
            readOffset = 0
        }
    }

    private func handleFrame(typeByte: UInt8, flags: UInt8, streamID: UInt32, payload: [UInt8]) {
        if let pending = headerAccumulator, typeByte != FrameType.continuation.rawValue || streamID != pending.streamID {
            fatalProtocolError("expected CONTINUATION for stream \(pending.streamID)", code: 0x1)
            return
        }
        guard let type = FrameType(rawValue: typeByte) else { return } // Unknown frame types are ignored.
        trace("recv \(type) stream=\(streamID) flags=\(flags) len=\(payload.count)\(type == .windowUpdate || type == .settings ? " payload=\(payload)" : "")")
        switch type {
        case .data:
            handleData(flags: flags, streamID: streamID, payload: payload)
        case .headers:
            var body = payload[...]
            if flags & 0x8 != 0 { // PADDED
                guard let pad = body.first, Int(pad) < body.count else { return fatalProtocolError("bad padding", code: 0x1) }
                body = body.dropFirst().dropLast(Int(pad))
            }
            if flags & 0x20 != 0 { body = body.dropFirst(5) } // PRIORITY
            headerAccumulator = (streamID, Array(body), flags & 0x1 != 0)
            if flags & 0x4 != 0 { finishHeaderBlock() }
        case .continuation:
            headerAccumulator?.block.append(contentsOf: payload)
            if flags & 0x4 != 0 { finishHeaderBlock() }
        case .rstStream:
            let code = payload.count >= 4 ? payload.readUInt32(at: 0) : 0
            if let stream = streams.removeValue(forKey: streamID) {
                stream.handler(.reset(errorCode: code))
            }
        case .settings:
            guard flags & 0x1 == 0 else { return } // ACK
            handleSettings(payload)
            writeFrame(.settings, flags: 0x1, streamID: 0, payload: [])
        case .ping:
            if flags & 0x1 == 0 {
                writeFrame(.ping, flags: 0x1, streamID: 0, payload: payload)
            }
        case .goAway:
            let lastStreamID = payload.count >= 4 ? payload.readUInt32(at: 0) & 0x7FFF_FFFF : 0
            let code = payload.count >= 8 ? payload.readUInt32(at: 4) : 0
            goAwayReceived = true
            unusableFlag.set()
            for (id, stream) in streams where id > lastStreamID {
                streams[id] = nil
                stream.handler(.connectionClosed(.goAway(errorCode: code)))
            }
            if code != 0 { fail(.goAway(errorCode: code)) }
        case .windowUpdate:
            guard payload.count >= 4 else { return }
            let increment = Int(payload.readUInt32(at: 0) & 0x7FFF_FFFF)
            if streamID == 0 {
                connectionSendWindow += increment
                for (id, stream) in streams where !stream.pending.isEmpty { flush(streamID: id, stream: stream) }
            } else if let stream = streams[streamID] {
                stream.sendWindow += increment
                flush(streamID: streamID, stream: stream)
            }
        case .pushPromise:
            fatalProtocolError("PUSH_PROMISE received although push is disabled", code: 0x1)
        case .priority:
            break
        }
    }

    private func handleData(flags: UInt8, streamID: UInt32, payload: [UInt8]) {
        // Flow control counts the whole payload including padding.
        connectionRecvUnacked += payload.count
        if connectionRecvUnacked >= Self.windowUpdateThreshold {
            var inc: [UInt8] = []
            inc.appendUInt32(UInt32(connectionRecvUnacked))
            writeFrame(.windowUpdate, flags: 0, streamID: 0, payload: inc)
            connectionRecvUnacked = 0
        }
        guard let stream = streams[streamID] else { return }
        var body = payload[...]
        if flags & 0x8 != 0 {
            guard let pad = body.first, Int(pad) < body.count else { return fatalProtocolError("bad padding", code: 0x1) }
            body = body.dropFirst().dropLast(Int(pad))
        }
        let endStream = flags & 0x1 != 0
        if !endStream {
            stream.recvUnacked += payload.count
            if stream.recvUnacked >= Self.windowUpdateThreshold {
                var inc: [UInt8] = []
                inc.appendUInt32(UInt32(stream.recvUnacked))
                writeFrame(.windowUpdate, flags: 0, streamID: streamID, payload: inc)
                stream.recvUnacked = 0
            }
        }
        if endStream {
            streams[streamID] = nil
        }
        stream.handler(.data(Array(body), endStream: endStream))
    }

    private func finishHeaderBlock() {
        guard let pending = headerAccumulator else { return }
        headerAccumulator = nil
        let headers: [HeaderField]
        do {
            headers = try decoder.decode(pending.block)
        } catch {
            fatalProtocolError("header decoding failed: \(error)", code: 0x9)
            return
        }
        guard let stream = streams[pending.streamID] else { return }
        if pending.endStream {
            streams[pending.streamID] = nil
        }
        stream.handler(.headers(headers, endStream: pending.endStream))
    }

    private func handleSettings(_ payload: [UInt8]) {
        var index = 0
        while index + 6 <= payload.count {
            let id = UInt16(payload[index]) << 8 | UInt16(payload[index + 1])
            let value = payload.readUInt32(at: index + 2)
            index += 6
            switch id {
            case 0x4:
                let delta = Int(value) - peerInitialWindow
                peerInitialWindow = Int(value)
                for (_, stream) in streams { stream.sendWindow += delta }
            case 0x5:
                peerMaxFrameSize = max(16_384, min(Int(value), 16_777_215))
            default:
                break // HEADER_TABLE_SIZE is irrelevant: our encoder never indexes.
            }
        }
        for (id, stream) in streams where !stream.pending.isEmpty { flush(streamID: id, stream: stream) }
    }

    private func fatalProtocolError(_ reason: String, code: UInt32) {
        var payload: [UInt8] = []
        payload.appendUInt32(0)
        payload.appendUInt32(code)
        writeFrame(.goAway, flags: 0, streamID: 0, payload: payload)
        fail(.protocolError(reason))
    }

    private func fail(_ error: HTTP2Error) {
        guard closedError == nil else { return }
        closedError = error
        unusableFlag.set()
        let active = streams
        streams.removeAll()
        for (_, stream) in active {
            stream.handler(.connectionClosed(error))
        }
        let observers = closeObservers
        closeObservers.removeAll()
        observers.forEach { $0(error) }
        connection.cancel()
    }
}

final class LockedFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// Resumes a continuation at most once; returns whether this call performed the resume.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with result: Result<T, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}

extension Array where Element == UInt8 {
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendSetting(_ id: UInt16, _ value: UInt32) {
        append(UInt8(id >> 8))
        append(UInt8(id & 0xFF))
        appendUInt32(value)
    }

    func readUInt32(at index: Int) -> UInt32 {
        UInt32(self[index]) << 24 | UInt32(self[index + 1]) << 16 | UInt32(self[index + 2]) << 8 | UInt32(self[index + 3])
    }
}
