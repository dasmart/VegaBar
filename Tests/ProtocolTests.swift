import XCTest
@testable import VegaBar

/// Byte-for-byte checks against the reference frames decoded from the Android
/// app, plus real replies captured from a PL103.
final class ProtocolTests: XCTestCase {
    private let device: UInt16 = 0x8000

    private func hex(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined(separator: " ") }

    private func assertFrame(seq: UInt16, _ make: () -> Data, equals expected: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        ZYProtocol.resetSequence(to: seq)
        XCTAssertEqual(hex(make()), expected, file: file, line: line)
    }

    func testCRC16XModemCheckValue() {
        XCTAssertEqual(ZYProtocol.crc16(Array("123456789".utf8)), 0x31C3)
    }

    func testReferenceFrames() {
        assertFrame(seq: 1, { ZYProtocol.setBrightness(device: device, percent: 50) },
                    equals: "24 3C 0D 00 00 01 01 00 01 10 00 80 01 00 00 48 42 39 9F")
        assertFrame(seq: 2, { ZYProtocol.setColorTemp(device: device, kelvin: 5600) },
                    equals: "24 3C 0B 00 00 01 02 00 02 10 00 80 01 E0 15 6B 6B")
        assertFrame(seq: 4, { ZYProtocol.setPower(device: device, on: true) },
                    equals: "24 3C 0A 00 00 01 04 00 08 10 00 80 01 01 1C F5")
        assertFrame(seq: 5, { ZYProtocol.setPower(device: device, on: false) },
                    equals: "24 3C 0A 00 00 01 05 00 08 10 00 80 01 00 EE A2")
        assertFrame(seq: 6, { ZYProtocol.getBrightness(device: device) },
                    equals: "24 3C 0D 00 00 01 06 00 01 10 00 80 00 00 00 00 00 36 F0")
        assertFrame(seq: 7, { ZYProtocol.identify(device: device) },
                    equals: "24 3C 08 00 00 01 07 00 01 11 00 80 4F E3")
        assertFrame(seq: 8, { ZYProtocol.getDeviceId() },
                    equals: "24 3C 06 00 00 01 08 00 05 20 05 F4")
        assertFrame(seq: 10, { ZYProtocol.register(device: device) },
                    equals: "24 3C 0A 00 00 01 0A 00 06 00 00 80 00 00 E4 CC")
        assertFrame(seq: 11, { ZYProtocol.removeDevice(device: device) },
                    equals: "24 3C 08 00 00 01 0B 00 03 00 00 80 97 71")
    }

    func testSequenceWrapsToOneNotZero() {
        ZYProtocol.resetSequence(to: .max)
        XCTAssertEqual(ZYProtocol.nextSequence(), .max)
        XCTAssertEqual(ZYProtocol.nextSequence(), 1)
    }

    func testEncoderClampsOutOfRangeValues() {
        ZYProtocol.resetSequence(to: 1)
        let hot = ZYProtocol.setColorTemp(device: device, kelvin: 9000)
        XCTAssertEqual(LightSafety.validate(hot), .allowed)
        XCTAssertEqual(Array(hot)[13...14], [0x64, 0x19])   // 6500 little-endian
        let bright = ZYProtocol.setBrightness(device: device, percent: 150)
        XCTAssertEqual(LightSafety.validate(bright), .allowed)
    }

    func testDecodesRealRepliesFromThePL103() {
        var parser = ZYProtocol.Parser()
        let brightness = Data([0x24,0x3c,0x0d,0x00,0x01,0x00,0x02,0x00,0x01,0x10,0x00,0x80,0x00,0x00,0x00,0x80,0x41,0x1a,0xa4])
        let colorTemp  = Data([0x24,0x3c,0x0b,0x00,0x01,0x00,0x03,0x00,0x02,0x10,0x00,0x80,0x00,0x10,0x0e,0xef,0xb0])
        let power      = Data([0x24,0x3c,0x0a,0x00,0x01,0x00,0x04,0x00,0x08,0x10,0x00,0x80,0x00,0x01,0x4b,0x42])
        XCTAssertEqual(parser.feed(brightness), [.brightness(id: device, percent: 16)])
        XCTAssertEqual(parser.feed(colorTemp), [.colorTemp(id: device, kelvin: 3600)])
        XCTAssertEqual(parser.feed(power), [.power(id: device, on: true)])
    }

    func testParserReassemblesSplitFramesAndSkipsJunk() {
        var parser = ZYProtocol.Parser()
        let frame = [UInt8](Data([0x24,0x3c,0x0a,0x00,0x01,0x00,0x04,0x00,0x08,0x10,0x00,0x80,0x00,0x01,0x4b,0x42]))
        XCTAssertEqual(parser.feed(Data([0xAA, 0x24] + frame[0..<7])), [])
        XCTAssertEqual(parser.feed(Data(frame[7...])), [.power(id: device, on: true)])
    }

    func testParserDropsBadCRC() {
        var parser = ZYProtocol.Parser()
        var frame = [UInt8](Data([0x24,0x3c,0x0a,0x00,0x01,0x00,0x04,0x00,0x08,0x10,0x00,0x80,0x00,0x01,0x4b,0x42]))
        frame[frame.count - 1] ^= 0xFF
        XCTAssertEqual(parser.feed(Data(frame)), [])
    }
}
