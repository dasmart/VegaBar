import XCTest
@testable import VegaBar

final class ControlProtocolTests: XCTestCase {
    func testRequestRoundTripsThroughJSON() throws {
        let r = ControlProtocol.Request(command: .brightness, value: 42.5, relative: true, name: nil)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(ControlProtocol.Request.self, from: data)
        XCTAssertEqual(back.command, .brightness)
        XCTAssertEqual(back.value, 42.5)
        XCTAssertEqual(back.relative, true)
    }

    func testUnknownCommandIsRejectedByDecoder() {
        let json = Data(#"{"command":"unpair"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ControlProtocol.Request.self, from: json))
    }

    func testNonFiniteValuesCannotBeEncoded() {
        let r = ControlProtocol.Request(command: .brightness, value: .nan)
        XCTAssertThrowsError(try JSONEncoder().encode(r))
    }
}
