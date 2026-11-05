import Testing
@testable import DDEmulatorGRPC

// Vectors from RFC 7541 Appendix C, extracted verbatim from the RFC text.
private enum RFC7541 {
    static let c41 = "828684418cf1e3c2e5f23a6ba0ab90f4ff"
    static let c42 = "828684be5886a8eb10649cbf"
    static let c43 = "828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf"
    static let c61 = "488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3"
    static let c62 = "4883640effc1c0bf"
    static let c63 = "88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007"
}

private func hex(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

private func pairs(_ headers: [HeaderField]) -> [String] {
    headers.map { "\($0.name): \($0.value)" }
}

@Suite("HPACK")
struct HPACKTests {
    @Test("RFC 7541 C.4 requests with Huffman coding share one dynamic table")
    func requestSequence() throws {
        var decoder = HPACKDecoder()
        #expect(pairs(try decoder.decode(hex(RFC7541.c41))) == [
            ":method: GET", ":scheme: http", ":path: /", ":authority: www.example.com",
        ])
        #expect(pairs(try decoder.decode(hex(RFC7541.c42))) == [
            ":method: GET", ":scheme: http", ":path: /", ":authority: www.example.com", "cache-control: no-cache",
        ])
        #expect(pairs(try decoder.decode(hex(RFC7541.c43))) == [
            ":method: GET", ":scheme: https", ":path: /index.html", ":authority: www.example.com", "custom-key: custom-value",
        ])
    }

    @Test("RFC 7541 C.6 responses evict entries from a 256-byte table")
    func responseSequenceWithEviction() throws {
        var decoder = HPACKDecoder(maxTableSize: 256)
        #expect(pairs(try decoder.decode(hex(RFC7541.c61))) == [
            ":status: 302", "cache-control: private", "date: Mon, 21 Oct 2013 20:13:21 GMT", "location: https://www.example.com",
        ])
        #expect(pairs(try decoder.decode(hex(RFC7541.c62))) == [
            ":status: 307", "cache-control: private", "date: Mon, 21 Oct 2013 20:13:21 GMT", "location: https://www.example.com",
        ])
        #expect(pairs(try decoder.decode(hex(RFC7541.c63))) == [
            ":status: 200", "cache-control: private", "date: Mon, 21 Oct 2013 20:13:22 GMT",
            "location: https://www.example.com", "content-encoding: gzip",
            "set-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
        ])
    }

    @Test("Encoder output round-trips through the decoder")
    func encoderRoundTrip() throws {
        let headers = [
            HeaderField(":method", "POST"),
            HeaderField(":scheme", "http"),
            HeaderField(":path", "/android.emulation.control.EmulatorController/getStatus"),
            HeaderField("content-type", "application/grpc"),
            HeaderField("te", "trailers"),
            HeaderField("authorization", "Bearer secret", sensitive: true),
        ]
        var decoder = HPACKDecoder()
        let decoded = try decoder.decode(HPACKEncoder().encode(headers))
        #expect(pairs(decoded) == pairs(headers))
        #expect(decoded.last?.sensitive == true)
    }

    @Test("Integers use the multi-byte continuation form past the prefix limit")
    func integerEncoding() throws {
        var out: [UInt8] = []
        HPACKPrimitive.encodeInteger(1337, prefixBits: 5, firstByteFlags: 0, into: &out)
        #expect(out == [31, 154, 10]) // RFC 7541 C.1.2
        var index = 0
        #expect(try HPACKPrimitive.decodeInteger(out, &index, prefixBits: 5) == 1337)
    }

    @Test("Invalid Huffman padding is rejected")
    func invalidPadding() {
        // 'a' is 00011 (5 bits); padding with zeros instead of ones is illegal.
        #expect(throws: HPACKError.invalidHuffmanCode) {
            _ = try HuffmanDecoder.shared.decode([0b0001_1000])
        }
    }
}

@Suite("Protobuf wire format")
struct ProtoWireTests {
    @Test("Negative int32 values are encoded as 10-byte varints")
    func negativeInt32() throws {
        var writer = ProtoWriter()
        writer.int32(1, -1)
        #expect(writer.bytes.count == 11)
        var reader = ProtoReader(writer.bytes)
        let field = try #require(try reader.next())
        #expect(field.field == 1)
        #expect(field.value.int32 == -1)
    }

    @Test("GPS state survives an encode/decode round trip")
    func gpsRoundTrip() throws {
        let state = EmulatorGPSState(latitude: 37.422, longitude: -122.084, altitude: 12.5, speed: 3, bearing: 90, satellites: 7)
        #expect(try EmulatorGPSState.decode(state.encode()) == state)
    }

    @Test("Touch events nest touches inside InputEvent.touch_event")
    func touchEncoding() throws {
        let event = EmulatorInputEvent.touch([EmulatorTouch(x: 10, y: 20, identifier: 1, pressure: 1)])
        var outer = ProtoReader(event.encodeAsInputEvent())
        let touchEvent = try #require(try outer.next())
        #expect(touchEvent.field == 2)
        var inner = ProtoReader(touchEvent.value.bytes)
        let touch = try #require(try inner.next())
        #expect(touch.field == 1)
        var fields = ProtoReader(touch.value.bytes)
        var values: [Int: Int32] = [:]
        while let (f, v) = try fields.next() { values[f] = v.int32 }
        #expect(values == [1: 10, 2: 20, 3: 1, 4: 1])
    }

    @Test("Packed floats decode in order")
    func packedFloats() throws {
        let bytes = EmulatorValueCodec.sensorValue(.acceleration, values: [0, 9.81, -1.5])
        let decoded = try EmulatorValueCodec.decodeValues(bytes)
        #expect(decoded.values == [0, 9.81, -1.5])
    }
}

@Suite("gRPC framing")
struct GRPCFramingTests {
    @Test("Messages split across DATA frames are reassembled")
    func reassembly() throws {
        let framed = GRPCMessageFramer.frame([1, 2, 3]) + GRPCMessageFramer.frame([4])
        var framer = GRPCMessageFramer()
        #expect(try framer.append(Array(framed.prefix(4))).isEmpty)
        #expect(try framer.append(Array(framed[4..<9])) == [[1, 2, 3]])
        #expect(try framer.append(Array(framed[9...])) == [[4]])
    }

    @Test("Trailers map grpc-status and percent-decoded grpc-message")
    func trailers() {
        let error = GRPCCallState.status(from: [
            HeaderField("grpc-status", "16"),
            HeaderField("grpc-message", "missing%20token"),
        ]) as? GRPCStatusError
        #expect(error == GRPCStatusError(code: 16, message: "missing token"))
        #expect(GRPCCallState.status(from: [HeaderField("grpc-status", "0")]) == nil)
    }
}
