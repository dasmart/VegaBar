import XCTest
@testable import VegaBar

final class URLCommandTests: XCTestCase {
    private func request(_ s: String) -> ControlProtocol.Request? { URLCommand.request(from: URL(string: s)!) }

    func testSimpleCommands() {
        XCTAssertEqual(request("vegabar://on")?.command, .on)
        XCTAssertEqual(request("vegabar://OFF")?.command, .off)
        XCTAssertEqual(request("vegabar://toggle")?.command, .toggle)
        XCTAssertEqual(request("vegabar://identify")?.command, .identify)
    }

    func testNumericArgumentsAndRelativeSign() {
        let abs = request("vegabar://brightness/40")
        XCTAssertEqual(abs?.command, .brightness)
        XCTAssertEqual(abs?.value, 40)
        XCTAssertNotEqual(abs?.relative, true)
        let rel = request("vegabar://brightness/+10")
        XCTAssertEqual(rel?.value, 10)
        XCTAssertEqual(rel?.relative, true)
        let cct = request("vegabar://cct/-300")
        XCTAssertEqual(cct?.command, .cct)
        XCTAssertEqual(cct?.relative, true)
        XCTAssertEqual(cct?.value, -300)
    }

    func testPresetNameIsPercentDecoded() {
        XCTAssertEqual(request("vegabar://preset/Video%20Call")?.name, "Video Call")
    }

    func testRejectsGarbage() {
        XCTAssertNil(request("vegabar://brightness/abc"))
        XCTAssertNil(request("vegabar://brightness"))
        XCTAssertNil(request("vegabar://unpair/1"))
        XCTAssertNil(request("https://example.com/on"))
    }
}
