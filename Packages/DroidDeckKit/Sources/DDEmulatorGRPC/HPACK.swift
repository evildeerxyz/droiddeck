import Foundation

/// A header field as transmitted in HTTP/2.
public struct HeaderField: Sendable, Equatable {
    public var name: String
    public var value: String
    /// Sensitive values are encoded as "never indexed" so intermediaries never cache them.
    public var sensitive: Bool

    public init(_ name: String, _ value: String, sensitive: Bool = false) {
        self.name = name
        self.value = value
        self.sensitive = sensitive
    }
}

public enum HPACKError: Error, Equatable {
    case truncated
    case integerOverflow
    case invalidIndex(Int)
    case invalidHuffmanCode
    case tableSizeUpdateTooLarge(Int)
}

// MARK: - Primitive coding (RFC 7541 §5)

enum HPACKPrimitive {
    static func encodeInteger(_ value: Int, prefixBits: Int, firstByteFlags: UInt8, into out: inout [UInt8]) {
        let maxPrefix = (1 << prefixBits) - 1
        if value < maxPrefix {
            out.append(firstByteFlags | UInt8(value))
            return
        }
        out.append(firstByteFlags | UInt8(maxPrefix))
        var remaining = value - maxPrefix
        while remaining >= 128 {
            out.append(UInt8(remaining % 128 + 128))
            remaining /= 128
        }
        out.append(UInt8(remaining))
    }

    static func decodeInteger(_ bytes: [UInt8], _ index: inout Int, prefixBits: Int) throws -> Int {
        guard index < bytes.count else { throw HPACKError.truncated }
        let maxPrefix = (1 << prefixBits) - 1
        var value = Int(bytes[index]) & maxPrefix
        index += 1
        if value < maxPrefix { return value }
        var shift = 0
        while true {
            guard index < bytes.count else { throw HPACKError.truncated }
            let byte = bytes[index]
            index += 1
            guard shift <= 28 else { throw HPACKError.integerOverflow }
            value += Int(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 { break }
        }
        return value
    }

    /// Strings are always sent as raw octets (H=0). Decoding supports both forms.
    static func encodeString(_ string: String, into out: inout [UInt8]) {
        let bytes = Array(string.utf8)
        encodeInteger(bytes.count, prefixBits: 7, firstByteFlags: 0, into: &out)
        out.append(contentsOf: bytes)
    }

    static func decodeString(_ bytes: [UInt8], _ index: inout Int) throws -> String {
        guard index < bytes.count else { throw HPACKError.truncated }
        let huffman = bytes[index] & 0x80 != 0
        let length = try decodeInteger(bytes, &index, prefixBits: 7)
        guard length >= 0, index + length <= bytes.count else { throw HPACKError.truncated }
        let slice = bytes[index..<index + length]
        index += length
        let raw = huffman ? try HuffmanDecoder.shared.decode(slice) : Array(slice)
        return String(decoding: raw, as: UTF8.self)
    }
}

// MARK: - Huffman

/// Decodes the canonical HPACK Huffman code using a binary tree built from RFC 7541 Appendix B.
final class HuffmanDecoder: Sendable {
    static let shared = HuffmanDecoder()

    // Node arrays: child indices for bit 0 / bit 1, and the symbol at leaves (-1 for internal nodes).
    private let zero: [Int32]
    private let one: [Int32]
    private let symbol: [Int16]

    private init() {
        var zero: [Int32] = [-1]
        var one: [Int32] = [-1]
        var symbol: [Int16] = [-1]
        for (sym, entry) in HPACKTables.huffmanCodes.enumerated() {
            var node = 0
            for bitIndex in stride(from: Int(entry.length) - 1, through: 0, by: -1) {
                let bit = (entry.code >> UInt32(bitIndex)) & 1
                let next = bit == 0 ? zero[node] : one[node]
                if next >= 0 {
                    node = Int(next)
                } else {
                    zero.append(-1)
                    one.append(-1)
                    symbol.append(-1)
                    let created = Int32(zero.count - 1)
                    if bit == 0 { zero[node] = created } else { one[node] = created }
                    node = Int(created)
                }
            }
            symbol[node] = Int16(sym)
        }
        self.zero = zero
        self.one = one
        self.symbol = symbol
    }

    func decode<C: Collection>(_ input: C) throws -> [UInt8] where C.Element == UInt8 {
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 8 / 5)
        var node = 0
        var bitsSinceSymbol = 0
        var allOnesSinceSymbol = true
        for byte in input {
            for shift in stride(from: 7, through: 0, by: -1) {
                let bit = (byte >> UInt8(shift)) & 1
                let next = bit == 0 ? zero[node] : one[node]
                guard next >= 0 else { throw HPACKError.invalidHuffmanCode }
                node = Int(next)
                bitsSinceSymbol += 1
                if bit == 0 { allOnesSinceSymbol = false }
                let sym = symbol[node]
                if sym >= 0 {
                    if sym == 256 { throw HPACKError.invalidHuffmanCode } // EOS must not appear in data.
                    output.append(UInt8(sym))
                    node = 0
                    bitsSinceSymbol = 0
                    allOnesSinceSymbol = true
                }
            }
        }
        // Padding must be a prefix of EOS (all ones) and shorter than 8 bits.
        if bitsSinceSymbol > 7 || !allOnesSinceSymbol { throw HPACKError.invalidHuffmanCode }
        return output
    }
}

// MARK: - Encoder

/// Stateless encoder: uses static-table name references where available and
/// never adds entries to the peer's dynamic table, so no encoder state is needed.
public struct HPACKEncoder: Sendable {
    public init() {}

    public func encode(_ headers: [HeaderField]) -> [UInt8] {
        var out: [UInt8] = []
        for header in headers {
            if !header.sensitive,
               let full = HPACKEncoder.staticFullMatch["\(header.name)\u{0}\(header.value)"] {
                HPACKPrimitive.encodeInteger(full, prefixBits: 7, firstByteFlags: 0x80, into: &out)
                continue
            }
            // Literal without indexing (0000) or never indexed (0001), 4-bit name index prefix.
            let flags: UInt8 = header.sensitive ? 0x10 : 0x00
            if let nameIndex = HPACKEncoder.staticNameIndex[header.name] {
                HPACKPrimitive.encodeInteger(nameIndex, prefixBits: 4, firstByteFlags: flags, into: &out)
            } else {
                out.append(flags)
                HPACKPrimitive.encodeString(header.name, into: &out)
            }
            HPACKPrimitive.encodeString(header.value, into: &out)
        }
        return out
    }

    private static let staticFullMatch: [String: Int] = {
        var map: [String: Int] = [:]
        for (offset, entry) in HPACKTables.staticTable.enumerated() where !entry.value.isEmpty {
            map["\(entry.name)\u{0}\(entry.value)"] = offset + 1
        }
        return map
    }()

    private static let staticNameIndex: [String: Int] = {
        var map: [String: Int] = [:]
        for (offset, entry) in HPACKTables.staticTable.enumerated() where map[entry.name] == nil {
            map[entry.name] = offset + 1
        }
        return map
    }()
}

// MARK: - Decoder

/// Full HPACK decoder with dynamic table support (RFC 7541 §2.3, §4, §6).
public struct HPACKDecoder: Sendable {
    private var dynamicTable: [(name: String, value: String)] = [] // index 0 = most recent
    private var dynamicSize = 0
    private(set) var maxTableSize: Int
    /// Upper bound advertised to the peer via SETTINGS_HEADER_TABLE_SIZE.
    private let protocolMaxTableSize: Int

    public init(maxTableSize: Int = 4096) {
        self.maxTableSize = maxTableSize
        self.protocolMaxTableSize = maxTableSize
    }

    public mutating func decode(_ block: [UInt8]) throws -> [HeaderField] {
        var headers: [HeaderField] = []
        var index = 0
        while index < block.count {
            let byte = block[index]
            if byte & 0x80 != 0 {
                let idx = try HPACKPrimitive.decodeInteger(block, &index, prefixBits: 7)
                let entry = try lookup(idx)
                headers.append(HeaderField(entry.name, entry.value))
            } else if byte & 0xC0 == 0x40 {
                let idx = try HPACKPrimitive.decodeInteger(block, &index, prefixBits: 6)
                let name = idx == 0 ? try HPACKPrimitive.decodeString(block, &index) : try lookup(idx).name
                let value = try HPACKPrimitive.decodeString(block, &index)
                headers.append(HeaderField(name, value))
                insert(name: name, value: value)
            } else if byte & 0xE0 == 0x20 {
                let size = try HPACKPrimitive.decodeInteger(block, &index, prefixBits: 5)
                guard size <= protocolMaxTableSize else { throw HPACKError.tableSizeUpdateTooLarge(size) }
                maxTableSize = size
                evict()
            } else {
                // 0000xxxx literal without indexing, 0001xxxx never indexed.
                let sensitive = byte & 0x10 != 0
                let idx = try HPACKPrimitive.decodeInteger(block, &index, prefixBits: 4)
                let name = idx == 0 ? try HPACKPrimitive.decodeString(block, &index) : try lookup(idx).name
                let value = try HPACKPrimitive.decodeString(block, &index)
                headers.append(HeaderField(name, value, sensitive: sensitive))
            }
        }
        return headers
    }

    private func lookup(_ index: Int) throws -> (name: String, value: String) {
        let staticCount = HPACKTables.staticTable.count
        if index >= 1 && index <= staticCount {
            return HPACKTables.staticTable[index - 1]
        }
        let dynamicIndex = index - staticCount - 1
        guard dynamicIndex >= 0 && dynamicIndex < dynamicTable.count else {
            throw HPACKError.invalidIndex(index)
        }
        return dynamicTable[dynamicIndex]
    }

    private mutating func insert(name: String, value: String) {
        let size = name.utf8.count + value.utf8.count + 32
        if size > maxTableSize {
            dynamicTable.removeAll()
            dynamicSize = 0
            return
        }
        dynamicTable.insert((name, value), at: 0)
        dynamicSize += size
        evict()
    }

    private mutating func evict() {
        while dynamicSize > maxTableSize, let last = dynamicTable.popLast() {
            dynamicSize -= last.name.utf8.count + last.value.utf8.count + 32
        }
    }
}
