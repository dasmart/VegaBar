import XCTest
@testable import VegaBar

/// The time-of-day colour temperature curve, as pure arithmetic.
final class ScheduleTests: XCTestCase {
    private func k(_ hour: Int, _ minute: Int = 0, morning: Int = 7 * 60, evening: Int = 19 * 60) -> Double {
        Automations.targetKelvin(minuteOfDay: hour * 60 + minute, day: 5600, night: 3200,
                                 morningStart: morning, eveningStart: evening)
    }

    func testDaytimeAndNightValues() {
        XCTAssertEqual(k(12), 5600)
        XCTAssertEqual(k(23), 3200)
        XCTAssertEqual(k(3), 3200)
    }

    func testBlendsAcrossAnHourAroundEachStart() {
        XCTAssertEqual(k(6, 30), 3200)          // window opens
        XCTAssertEqual(k(7), 4400, accuracy: 1)  // midpoint
        XCTAssertEqual(k(7, 30), 5600)          // window closes
        XCTAssertEqual(k(18, 30), 5600)
        XCTAssertEqual(k(19), 4400, accuracy: 1)
        XCTAssertEqual(k(19, 30), 3200)
    }

    func testStartJustAfterMidnightWrapsCorrectly() {
        // Morning at 00:15: the blend runs 23:45 → 00:45 across midnight.
        XCTAssertEqual(k(23, 45, morning: 15), 3200)
        XCTAssertEqual(k(0, 15, morning: 15), 4400, accuracy: 1)
        XCTAssertEqual(k(0, 45, morning: 15), 5600)
        XCTAssertEqual(k(23, 0, morning: 15), 3200)
    }
}
