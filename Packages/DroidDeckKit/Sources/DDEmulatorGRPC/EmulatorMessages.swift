import Foundation

// Hand-written encoders/decoders for the subset of
// $ANDROID_HOME/emulator/lib/emulator_controller.proto (package android.emulation.control)
// that DroidDeck uses. Field numbers are taken verbatim from that file.

public enum EmulatorImageFormat: Int32, Sendable {
    case png = 0
    case rgba8888 = 1
    case rgb888 = 2
}

/// `Rotation.SkinRotation`.
public enum EmulatorSkinRotation: Int32, Sendable {
    case portrait = 0
    case landscape = 1
    case reversePortrait = 2
    case reverseLandscape = 3

    /// Clockwise rotation, in quarter turns, applied by the emulator to the image.
    public var quarterTurns: Int { Int(rawValue) }
}

/// `ImageFormat` request/response metadata.
public struct EmulatorImageRequest: Sendable {
    public var format: EmulatorImageFormat
    public var width: UInt32
    public var height: UInt32
    public var display: UInt32
    /// `file:///…` handle for MMAP transport, or nil for in-band pixel bytes.
    public var mmapHandle: String?

    public init(format: EmulatorImageFormat, width: UInt32 = 0, height: UInt32 = 0, display: UInt32 = 0, mmapHandle: String? = nil) {
        self.format = format
        self.width = width
        self.height = height
        self.display = display
        self.mmapHandle = mmapHandle
    }

    func encode() -> [UInt8] {
        var w = ProtoWriter()
        w.int32(1, format.rawValue)
        w.uint32(3, width)
        w.uint32(4, height)
        w.uint32(5, display)
        if let mmapHandle {
            w.message(6) { t in
                t.int32(1, 1) // MMAP
                t.string(2, mmapHandle)
            }
        }
        return w.bytes
    }
}

/// `Image` response.
public struct EmulatorImage: Sendable {
    public var format: EmulatorImageFormat = .png
    public var width: Int = 0
    public var height: Int = 0
    public var rotation: EmulatorSkinRotation = .portrait
    public var pixels: [UInt8] = []
    public var sequence: UInt32 = 0
    public var timestampMicros: UInt64 = 0

    public init() {}

    static func decode(_ bytes: [UInt8]) throws -> EmulatorImage {
        var image = EmulatorImage()
        var reader = ProtoReader(bytes)
        while let (field, value) = try reader.next() {
            switch field {
            case 1: try image.decodeFormat(value.bytes)
            case 2 where image.width == 0: image.width = Int(value.uint32) // deprecated duplicate
            case 3 where image.height == 0: image.height = Int(value.uint32)
            case 4: image.pixels = Array(value.bytes)
            case 5: image.sequence = value.uint32
            case 6: image.timestampMicros = value.uint64
            default: break
            }
        }
        return image
    }

    private mutating func decodeFormat(_ bytes: ArraySlice<UInt8>) throws {
        var reader = ProtoReader(bytes)
        while let (field, value) = try reader.next() {
            switch field {
            case 1: format = EmulatorImageFormat(rawValue: value.int32) ?? .png
            case 2:
                var rotationReader = ProtoReader(value.bytes)
                while let (rf, rv) = try rotationReader.next() {
                    guard rf == 1 else { continue }
                    rotation = EmulatorSkinRotation(rawValue: rv.int32) ?? .portrait
                }
            case 3: width = Int(value.uint32)
            case 4: height = Int(value.uint32)
            default: break
            }
        }
    }
}

/// `Touch`.
public struct EmulatorTouch: Sendable, Equatable {
    public var x: Int32
    public var y: Int32
    public var identifier: Int32
    /// Non-zero while in contact; 0 lifts the pointer.
    public var pressure: Int32

    public init(x: Int32, y: Int32, identifier: Int32, pressure: Int32) {
        self.x = x
        self.y = y
        self.identifier = identifier
        self.pressure = pressure
    }

    func write(into w: inout ProtoWriter) {
        // x/y = 0 are valid coordinates, but proto3 omission of zero is equivalent.
        w.int32(1, x)
        w.int32(2, y)
        w.int32(3, identifier)
        w.int32(4, pressure)
    }
}

public enum EmulatorKeyEventType: Int32, Sendable {
    case keyDown = 0
    case keyUp = 1
    case keyPress = 2
}

public enum EmulatorInputEvent: Sendable, Equatable {
    case touch([EmulatorTouch], display: Int32 = 0)
    case mouse(x: Int32, y: Int32, buttons: Int32, display: Int32 = 0)
    case wheel(dx: Int32, dy: Int32, display: Int32 = 0)
    /// `key` uses W3C KeyboardEvent.key values ("GoHome", "Enter", "a", ...).
    case key(String, EmulatorKeyEventType)
    /// UTF-8 text typed as a series of key presses.
    case text(String)
    /// A Linux evdev key code (e.g. 580 = KEY_APPSELECT), for keys without a W3C name the emulator maps.
    case evdevKey(Int32, EmulatorKeyEventType)

    func encodeAsInputEvent() -> [UInt8] {
        var w = ProtoWriter()
        switch self {
        case .key, .text, .evdevKey:
            w.message(1) { self.writeKeyboard(into: &$0) }
        case .touch:
            w.message(2) { self.writeTouch(into: &$0) }
        case .mouse:
            w.message(3) { self.writeMouse(into: &$0) }
        case .wheel(let dx, let dy, let display):
            w.message(6) { m in
                m.int32(1, dx)
                m.int32(2, dy)
                m.int32(3, display)
            }
        }
        return w.bytes
    }

    func writeTouch(into w: inout ProtoWriter) {
        guard case .touch(let touches, let display) = self else { return }
        for touch in touches {
            w.message(1) { touch.write(into: &$0) }
        }
        w.int32(2, display)
    }

    func writeMouse(into w: inout ProtoWriter) {
        guard case .mouse(let x, let y, let buttons, let display) = self else { return }
        w.int32(1, x)
        w.int32(2, y)
        w.int32(3, buttons)
        w.int32(4, display)
    }

    func writeKeyboard(into w: inout ProtoWriter) {
        switch self {
        case .key(let key, let type):
            w.int32(2, type.rawValue)
            w.string(4, key)
        case .text(let text):
            w.string(5, text)
        case .evdevKey(let code, let type):
            w.int32(1, 1) // KeyCodeType.Evdev
            w.int32(2, type.rawValue)
            w.int32(3, code)
        default:
            break
        }
    }
}

/// `GpsState`.
public struct EmulatorGPSState: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var speed: Double
    public var bearing: Double
    public var satellites: Int32
    public var passiveUpdate: Bool

    public init(latitude: Double, longitude: Double, altitude: Double = 0, speed: Double = 0,
                bearing: Double = 0, satellites: Int32 = 6, passiveUpdate: Bool = false) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.bearing = bearing
        self.satellites = satellites
        self.passiveUpdate = passiveUpdate
    }

    func encode() -> [UInt8] {
        var w = ProtoWriter()
        w.bool(1, passiveUpdate)
        w.double(2, latitude)
        w.double(3, longitude)
        w.double(4, speed)
        w.double(5, bearing)
        w.double(6, altitude)
        w.int32(7, satellites)
        return w.bytes
    }

    static func decode(_ bytes: [UInt8]) throws -> EmulatorGPSState {
        var state = EmulatorGPSState(latitude: 0, longitude: 0, satellites: 0)
        var reader = ProtoReader(bytes)
        while let (field, value) = try reader.next() {
            switch field {
            case 1: state.passiveUpdate = value.bool
            case 2: state.latitude = value.double
            case 3: state.longitude = value.double
            case 4: state.speed = value.double
            case 5: state.bearing = value.double
            case 6: state.altitude = value.double
            case 7: state.satellites = value.int32
            default: break
            }
        }
        return state
    }
}

/// `BatteryState`.
public struct EmulatorBatteryState: Sendable, Equatable {
    public enum Charger: Int32, Sendable, CaseIterable { case none = 0, ac = 1, usb = 2, wireless = 3 }
    public enum Status: Int32, Sendable, CaseIterable { case unknown = 0, charging = 1, discharging = 2, notCharging = 3, full = 4 }
    public enum Health: Int32, Sendable, CaseIterable { case good = 0, failed = 1, dead = 2, overvoltage = 3, overheated = 4 }

    public var hasBattery = true
    public var isPresent = true
    public var charger: Charger = .ac
    public var chargeLevel: Int32 = 100
    public var health: Health = .good
    public var status: Status = .charging

    public init() {}

    func encode() -> [UInt8] {
        var w = ProtoWriter()
        w.bool(1, hasBattery)
        w.bool(2, isPresent)
        w.int32(3, charger.rawValue)
        w.int32(4, chargeLevel)
        w.int32(5, health.rawValue)
        w.int32(6, status.rawValue)
        return w.bytes
    }

    static func decode(_ bytes: [UInt8]) throws -> EmulatorBatteryState {
        var state = EmulatorBatteryState()
        state.hasBattery = false
        state.isPresent = false
        state.charger = .none
        state.chargeLevel = 0
        state.status = .unknown
        var reader = ProtoReader(bytes)
        while let (field, value) = try reader.next() {
            switch field {
            case 1: state.hasBattery = value.bool
            case 2: state.isPresent = value.bool
            case 3: state.charger = Charger(rawValue: value.int32) ?? .none
            case 4: state.chargeLevel = value.int32
            case 5: state.health = Health(rawValue: value.int32) ?? .good
            case 6: state.status = Status(rawValue: value.int32) ?? .unknown
            default: break
            }
        }
        return state
    }
}

/// `EmulatorStatus`.
public struct EmulatorStatus: Sendable {
    public var version = ""
    public var uptimeMillis: UInt64 = 0
    public var booted = false
    public var heartbeat: UInt64 = 0
    public var hardwareConfig: [String: String] = [:]

    static func decode(_ bytes: [UInt8]) throws -> EmulatorStatus {
        var status = EmulatorStatus()
        var reader = ProtoReader(bytes)
        while let (field, value) = try reader.next() {
            switch field {
            case 1: status.version = value.string
            case 2: status.uptimeMillis = value.uint64
            case 3: status.booted = value.bool
            case 5:
                // EntryList { repeated Entry entry = 1; } Entry { key = 1; value = 2; }
                var list = ProtoReader(value.bytes)
                while let (lf, lv) = try list.next() {
                    guard lf == 1 else { continue }
                    let (k, v) = try Self.decodePair(lv.bytes)
                    status.hardwareConfig[k] = v
                }
            case 6: status.heartbeat = value.uint64
            case 8:
                // map<string,string> platformConfig: each entry is a {key=1,value=2} message.
                let (k, v) = try Self.decodePair(value.bytes)
                status.hardwareConfig[k] = v
            default: break
            }
        }
        return status
    }

    private static func decodePair(_ bytes: ArraySlice<UInt8>) throws -> (String, String) {
        var reader = ProtoReader(bytes)
        var key = ""
        var value = ""
        while let (field, v) = try reader.next() {
            if field == 1 { key = v.string } else if field == 2 { value = v.string }
        }
        return (key, value)
    }
}

/// `VmRunState.RunState` values that clients may request.
public enum EmulatorVMState: Int32, Sendable {
    case unknown = 0
    case running = 1
    case restoreVM = 2
    case paused = 3
    case saveVM = 4
    case shutdown = 5
    case terminate = 7
    case reset = 9
    case internalError = 10
    case restart = 11
    case start = 12
    case stop = 13
}

/// `SensorValue.SensorType`.
public enum EmulatorSensor: Int32, Sendable, CaseIterable {
    case acceleration = 0
    case gyroscope = 1
    case magneticField = 2
    case orientation = 3
    case temperature = 4
    case proximity = 5
    case light = 6
    case pressure = 7
    case humidity = 8
}

/// `PhysicalModelValue.PhysicalType` subset.
public enum EmulatorPhysicalModel: Int32, Sendable {
    case position = 0
    case rotation = 1
    case magneticField = 2
    case temperature = 3
    case proximity = 4
    case light = 5
    case pressure = 6
    case humidity = 7
}

enum EmulatorValueCodec {
    static func sensorValue(_ sensor: EmulatorSensor, values: [Float]) -> [UInt8] {
        var w = ProtoWriter()
        w.int32(1, sensor.rawValue)
        w.message(3) { $0.packedFloats(1, values) }
        return w.bytes
    }

    static func physicalModel(_ model: EmulatorPhysicalModel, values: [Float]) -> [UInt8] {
        var w = ProtoWriter()
        w.int32(1, model.rawValue)
        w.message(3) { $0.packedFloats(1, values) }
        return w.bytes
    }

    static func decodeValues(_ bytes: [UInt8]) throws -> (status: Int32, values: [Float]) {
        var reader = ProtoReader(bytes)
        var status: Int32 = 0
        var values: [Float] = []
        while let (field, value) = try reader.next() {
            if field == 2 { status = value.int32 }
            if field == 3 {
                var inner = ProtoReader(value.bytes)
                while let (f, v) = try inner.next() {
                    guard f == 1 else { continue }
                    if case .lengthDelimited = v {
                        values.append(contentsOf: v.packedFloats)
                    } else if case .fixed32(let bits) = v {
                        values.append(Float(bitPattern: bits))
                    }
                }
            }
        }
        return (status, values)
    }
}
