import Foundation

/// Minimal protocol-buffer wire format support (proto3), enough to speak the
/// emulator controller API without code generation or third-party runtimes.
public enum ProtoWireType: UInt8, Sendable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

public enum ProtoError: Error, Equatable {
    case truncated
    case malformedVarint
    case unsupportedWireType(UInt8)
}

public struct ProtoWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func writeTag(_ field: Int, _ type: ProtoWireType) {
        writeVarint(UInt64(field << 3) | UInt64(type.rawValue))
    }

    /// proto3 omits default values; callers that need presence use `force: true`.
    public mutating func int32(_ field: Int, _ value: Int32, force: Bool = false) {
        guard value != 0 || force else { return }
        writeTag(field, .varint)
        writeVarint(UInt64(bitPattern: Int64(value))) // Negative int32 is sign-extended to 10 bytes.
    }

    public mutating func uint32(_ field: Int, _ value: UInt32) {
        guard value != 0 else { return }
        writeTag(field, .varint)
        writeVarint(UInt64(value))
    }

    public mutating func uint64(_ field: Int, _ value: UInt64) {
        guard value != 0 else { return }
        writeTag(field, .varint)
        writeVarint(value)
    }

    public mutating func bool(_ field: Int, _ value: Bool) {
        guard value else { return }
        writeTag(field, .varint)
        writeVarint(1)
    }

    public mutating func double(_ field: Int, _ value: Double) {
        guard value != 0 else { return }
        writeTag(field, .fixed64)
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
    }

    public mutating func string(_ field: Int, _ value: String) {
        guard !value.isEmpty else { return }
        bytesField(field, Array(value.utf8))
    }

    public mutating func bytesField(_ field: Int, _ value: [UInt8]) {
        writeTag(field, .lengthDelimited)
        writeVarint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    /// Embedded messages are written even when empty so oneof/presence is preserved.
    public mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var nested = ProtoWriter()
        build(&nested)
        bytesField(field, nested.bytes)
    }

    public mutating func packedFloats(_ field: Int, _ values: [Float]) {
        guard !values.isEmpty else { return }
        var payload: [UInt8] = []
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        }
        bytesField(field, payload)
    }
}

/// A decoded field value. Length-delimited payloads are kept as slices of the source buffer.
public enum ProtoValue: Sendable {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case lengthDelimited(ArraySlice<UInt8>)

    public var uint64: UInt64 {
        switch self {
        case .varint(let v), .fixed64(let v): return v
        case .fixed32(let v): return UInt64(v)
        case .lengthDelimited: return 0
        }
    }

    public var int32: Int32 { Int32(truncatingIfNeeded: Int64(bitPattern: uint64)) }
    public var uint32: UInt32 { UInt32(truncatingIfNeeded: uint64) }
    public var bool: Bool { uint64 != 0 }
    public var double: Double { Double(bitPattern: uint64) }

    public var bytes: ArraySlice<UInt8> {
        if case .lengthDelimited(let slice) = self { return slice }
        return []
    }

    public var string: String { String(decoding: bytes, as: UTF8.self) }

    public var packedFloats: [Float] {
        let raw = bytes
        var result: [Float] = []
        var index = raw.startIndex
        while index + 4 <= raw.endIndex {
            let bits = UInt32(raw[index]) | UInt32(raw[index + 1]) << 8 | UInt32(raw[index + 2]) << 16 | UInt32(raw[index + 3]) << 24
            result.append(Float(bitPattern: bits))
            index += 4
        }
        return result
    }
}

public struct ProtoReader {
    private let buffer: ArraySlice<UInt8>
    private var index: Int

    public init(_ bytes: ArraySlice<UInt8>) {
        buffer = bytes
        index = bytes.startIndex
    }

    public init(_ bytes: [UInt8]) {
        self.init(bytes[...])
    }

    /// Returns the next (field number, value) pair, or nil at end of input.
    public mutating func next() throws -> (field: Int, value: ProtoValue)? {
        guard index < buffer.endIndex else { return nil }
        let key = try readVarint()
        let field = Int(key >> 3)
        guard let type = ProtoWireType(rawValue: UInt8(key & 0x7)) else {
            throw ProtoError.unsupportedWireType(UInt8(key & 0x7))
        }
        switch type {
        case .varint:
            return (field, .varint(try readVarint()))
        case .fixed64:
            guard index + 8 <= buffer.endIndex else { throw ProtoError.truncated }
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(buffer[index + i]) << (8 * UInt64(i)) }
            index += 8
            return (field, .fixed64(value))
        case .fixed32:
            guard index + 4 <= buffer.endIndex else { throw ProtoError.truncated }
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(buffer[index + i]) << (8 * UInt32(i)) }
            index += 4
            return (field, .fixed32(value))
        case .lengthDelimited:
            let length = Int(try readVarint())
            guard length >= 0, index + length <= buffer.endIndex else { throw ProtoError.truncated }
            let slice = buffer[index..<index + length]
            index += length
            return (field, .lengthDelimited(slice))
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < buffer.endIndex else { throw ProtoError.truncated }
            let byte = buffer[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { throw ProtoError.malformedVarint }
        }
    }
}
