import XCTest
@testable import VegaBar

/// Every rule in `LightSafety`, exercised with hand-built frames so the test
/// doesn't depend on the encoder behaving.
final class SafetyTests: XCTestCase {
    private let device: UInt16 = 0x8000

    /// Builds a frame around a raw command and payload, with a valid CRC unless asked otherwise.
    private func raw(_ cmd: UInt16, _ payload: [UInt8], badCRC: Bool = false) -> Data {
        let body: [UInt8] = [0, 1, 1, 0, UInt8(cmd & 0xFF), UInt8(cmd >> 8)] + payload
        var crc = ZYProtocol.crc16(body)
        if badCRC { crc ^= 1 }
        return Data([0x24, 0x3C, UInt8(body.count & 0xFF), UInt8(body.count >> 8)] + body + [UInt8(crc & 0xFF), UInt8(crc >> 8)])
    }

    private func f32(_ v: Float) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian, Array.init) }

    private func assertRejected(_ frame: Data, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        if case .allowed = LightSafety.validate(frame) { XCTFail("\(name) should be rejected", file: file, line: line) }
    }

    func testEncoderOutputIsAllowed() {
        XCTAssertEqual(LightSafety.validate(ZYProtocol.setBrightness(device: device, percent: 50)), .allowed)
        XCTAssertEqual(LightSafety.validate(ZYProtocol.setColorTemp(device: device, kelvin: 5600)), .allowed)
        XCTAssertEqual(LightSafety.validate(ZYProtocol.setPower(device: device, on: false)), .allowed)
        XCTAssertEqual(LightSafety.validate(ZYProtocol.getBrightness(device: device)), .allowed)
        XCTAssertEqual(LightSafety.validate(ZYProtocol.getColorTemp(device: device)), .allowed)
        XCTAssertEqual(LightSafety.validate(ZYProtocol.getPower(device: device)), .allowed)
        XCTAssertEqual(LightSafety.validate(ZYProtocol.getVoltage(device: device)), .allowed)
        XCTAssertEqual(LightSafety.validate(ZYProtocol.identify(device: device)), .allowed)
        XCTAssertEqual(LightSafety.validate(ZYProtocol.register(device: device)), .allowed)
        XCTAssertEqual(LightSafety.validate(ZYProtocol.removeDevice(device: device)), .allowed)
        XCTAssertEqual(LightSafety.validate(ZYProtocol.getDeviceId()), .allowed)
    }

    func testRejectsOutOfRangeValues() {
        assertRejected(ZYProtocol.setBrightness(device: device, percent: .nan), "NaN brightness")
        assertRejected(raw(0x1001, [0x00, 0x80, 1] + f32(150)), "brightness 150")
        assertRejected(raw(0x1001, [0x00, 0x80, 1] + f32(-5)), "brightness -5")
        assertRejected(raw(0x1001, [0x00, 0x80, 1] + f32(.infinity)), "brightness inf")
        assertRejected(raw(0x1002, [0x00, 0x80, 1, 0xE8, 0x03]), "1000K")
        assertRejected(raw(0x1002, [0x00, 0x80, 1, 0x10, 0x27]), "10000K")
        assertRejected(raw(0x1008, [0x00, 0x80, 1, 2]), "power value 2")
    }

    func testRejectsCommandsOutsideTheAllowList() {
        assertRejected(raw(0x1009, [0x00, 0x80, 1, 1]), "max mode")
        assertRejected(raw(0x100B, [0x00, 0x80, 1] + f32(50) + [1]), "brightness+mode")
        assertRejected(raw(0x1003, [0x00, 0x80, 1, 255, 0, 0, 0, 0, 0]), "RGB")
        assertRejected(raw(0x8001, []), "firmware version")
        assertRejected(raw(0x0004, [0x00, 0x80, 1, 0]), "add to group")
    }

    func testRejectsBadTargetsAndMalformedFrames() {
        assertRejected(raw(0x1001, [0x01, 0x00, 1] + f32(50)), "group id")
        assertRejected(raw(0x1008, [0x00, 0x00, 1, 1]), "unregistered id 0")
        assertRejected(raw(0x1008, [0x00, 0x80, 1, 1], badCRC: true), "bad CRC")
        assertRejected(raw(0x1001, [0x00, 0x80, 1, 0]), "short payload")
        assertRejected(raw(0x0006, [0x00, 0x80, 5, 0]), "register into group 5")
        assertRejected(Data(ZYProtocol.setPower(device: device, on: true).dropLast()), "truncated")
        assertRejected(raw(0x1001, [0x00, 0x80, 0] + f32(50)), "read carrying data")
    }

    func testWritePacingCapsStrobing() {
        XCTAssertEqual(LightSafety.minInterval(for: .brightness, isWrite: true), 0.1)
        XCTAssertEqual(LightSafety.minInterval(for: .colorTemp, isWrite: true), 0.1)
        XCTAssertEqual(LightSafety.minInterval(for: .power, isWrite: true), 1.0)
        XCTAssertNil(LightSafety.minInterval(for: .brightness, isWrite: false), "reads are never paced")
        XCTAssertNil(LightSafety.minInterval(for: .power, isWrite: false))
        XCTAssertGreaterThanOrEqual(LightSafety.minInterval(for: .removeDevice, isWrite: true) ?? 0, 1)
    }
}
