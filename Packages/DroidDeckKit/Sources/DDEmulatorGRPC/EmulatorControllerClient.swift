import Foundation

/// Typed client for `android.emulation.control.EmulatorController`.
///
/// The emulator must be started with `-grpc <port> -grpc-use-token`; the port
/// and token are published in the emulator's discovery file
/// (`~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`).
public actor EmulatorControllerClient {
    private static let service = "/android.emulation.control.EmulatorController/"
    private let channel: GRPCChannel

    public init(port: UInt16, token: String?) {
        channel = GRPCChannel(port: port, bearerToken: token)
    }

    public func close() async {
        await channel.shutdown()
    }

    private func call(_ method: String, _ request: [UInt8] = [], timeout: Duration = .seconds(10)) async throws -> [UInt8] {
        try await channel.unary(path: Self.service + method, request: request, timeout: timeout)
    }

    // MARK: Status

    public func status() async throws -> EmulatorStatus {
        try EmulatorStatus.decode(try await call("getStatus"))
    }

    // MARK: Display

    public func screenshot(_ request: EmulatorImageRequest) async throws -> EmulatorImage {
        try EmulatorImage.decode(try await call("getScreenshot", request.encode(), timeout: .seconds(20)))
    }

    /// Streams frames. Only the newest frame is buffered: a slow consumer drops frames rather than queueing them.
    public func streamScreenshots(_ request: EmulatorImageRequest) async throws -> AsyncThrowingStream<EmulatorImage, Error> {
        let raw = try await channel.serverStreaming(
            path: Self.service + "streamScreenshot",
            request: request.encode(),
            bufferingPolicy: .bufferingNewest(1)
        )
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await message in raw {
                        continuation.yield(try EmulatorImage.decode(message))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Input

    /// Sends one input event with a unary RPC.
    ///
    /// Verified against emulator 36.6.11: unary `sendTouch`/`sendKey` are applied,
    /// whereas events written to `streamInputEvent` are consumed but not applied.
    /// Callers must serialize calls (await each one) to preserve ordering.
    public func send(_ event: EmulatorInputEvent) async throws {
        var w = ProtoWriter()
        switch event {
        case .touch:
            event.writeTouch(into: &w)
            _ = try await call("sendTouch", w.bytes)
        case .mouse:
            event.writeMouse(into: &w)
            _ = try await call("sendMouse", w.bytes)
        case .key, .text, .evdevKey:
            event.writeKeyboard(into: &w)
            _ = try await call("sendKey", w.bytes)
        case .wheel:
            throw GRPCStatusError(code: GRPCStatusError.unimplemented, message: "wheel input is delivered as touch gestures")
        }
    }

    // MARK: Location, battery, sensors

    public func setGPS(_ state: EmulatorGPSState) async throws {
        _ = try await call("setGps", state.encode())
    }

    public func gps() async throws -> EmulatorGPSState {
        try EmulatorGPSState.decode(try await call("getGps"))
    }

    public func setBattery(_ state: EmulatorBatteryState) async throws {
        _ = try await call("setBattery", state.encode())
    }

    public func battery() async throws -> EmulatorBatteryState {
        try EmulatorBatteryState.decode(try await call("getBattery"))
    }

    public func setSensor(_ sensor: EmulatorSensor, values: [Float]) async throws {
        _ = try await call("setSensor", EmulatorValueCodec.sensorValue(sensor, values: values))
    }

    public func sensor(_ sensor: EmulatorSensor) async throws -> [Float] {
        let response = try await call("getSensor", EmulatorValueCodec.sensorValue(sensor, values: []))
        return try EmulatorValueCodec.decodeValues(response).values
    }

    public func setPhysicalModel(_ model: EmulatorPhysicalModel, values: [Float]) async throws {
        _ = try await call("setPhysicalModel", EmulatorValueCodec.physicalModel(model, values: values))
    }

    public func physicalModel(_ model: EmulatorPhysicalModel) async throws -> [Float] {
        let response = try await call("getPhysicalModel", EmulatorValueCodec.physicalModel(model, values: []))
        return try EmulatorValueCodec.decodeValues(response).values
    }

    // MARK: Clipboard

    public func setClipboard(_ text: String) async throws {
        var w = ProtoWriter()
        w.string(1, text)
        _ = try await call("setClipboard", w.bytes)
    }

    /// Device clipboard changes (server stream). Used to share text from Android back to the Mac.
    public func clipboardChanges() async throws -> AsyncThrowingStream<String, Error> {
        let raw = try await channel.serverStreaming(path: Self.service + "streamClipboard", request: [])
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in raw {
                        var reader = ProtoReader(message)
                        var text = ""
                        while let (field, value) = try reader.next() {
                            guard field == 1 else { continue }
                            text = value.string
                        }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func clipboard() async throws -> String {
        var reader = ProtoReader(try await call("getClipboard"))
        var text = ""
        while let (field, value) = try reader.next() {
            guard field == 1 else { continue }
            text = value.string
        }
        return text
    }

    // MARK: VM state

    public func setVMState(_ state: EmulatorVMState) async throws {
        var w = ProtoWriter()
        w.int32(1, state.rawValue)
        _ = try await call("setVmState", w.bytes)
    }

    public func vmState() async throws -> EmulatorVMState {
        var reader = ProtoReader(try await call("getVmState"))
        var state = EmulatorVMState.unknown
        while let (field, value) = try reader.next() {
            guard field == 1 else { continue }
            state = EmulatorVMState(rawValue: value.int32) ?? .unknown
        }
        return state
    }
}
