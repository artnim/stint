import XCTest
@testable import TimeCore

final class RoundingTests: XCTestCase {
    func testSnapNearest() {
        XCTAssertEqual(hhmm(snap(local("2026-08-03 13:09:00"), minutes: 15, mode: .nearest, calendar: berlin)), "13:15")
        XCTAssertEqual(hhmm(snap(local("2026-08-03 13:07:00"), minutes: 15, mode: .nearest, calendar: berlin)), "13:00")
        XCTAssertEqual(hhmm(snap(local("2026-08-03 13:07:30"), minutes: 15, mode: .nearest, calendar: berlin)), "13:00") // off*2 < minutes -> down
        XCTAssertEqual(hhmm(snap(local("2026-08-03 13:52:00"), minutes: 15, mode: .nearest, calendar: berlin)), "13:45")
    }

    func testSnapFloorAndCeil() {
        XCTAssertEqual(hhmm(snap(local("2026-08-03 13:14:59"), minutes: 15, mode: .floor, calendar: berlin)), "13:00")
        XCTAssertEqual(hhmm(snap(local("2026-08-03 13:00:01"), minutes: 15, mode: .ceil, calendar: berlin)), "13:15")
        XCTAssertEqual(hhmm(snap(local("2026-08-03 13:00:00"), minutes: 15, mode: .ceil, calendar: berlin)), "13:00")
    }

    func testSnapOnGridDropsSeconds() {
        let d = snap(local("2026-08-03 13:15:00"), minutes: 15, mode: .nearest, calendar: berlin)
        XCTAssertEqual(d, local("2026-08-03 13:15:00"))
    }

    func testSnapDisabled() {
        let d = local("2026-08-03 13:09:42")
        XCTAssertEqual(snap(d, minutes: 0, mode: .nearest, calendar: berlin), d)
        XCTAssertEqual(snap(d, minutes: 15, mode: .none, calendar: berlin), d)
    }

    func testSnapOnDSTChangeDayStaysOnTheSameDay() {
        // 2026-10-25: 03:00 CEST -> 02:00 CET. Snapping must not jump days or change the instant by more than the offset.
        let d = local("2026-10-25 02:50:00")
        let s = snap(d, minutes: 15, mode: .ceil, calendar: berlin)
        XCTAssertEqual(berlin.component(.day, from: s), 25)
        XCTAssertEqual(s.timeIntervalSince(d), 600, accuracy: 0.5)
    }

    func testRoundHours() {
        XCTAssertEqual(roundHours(1.01, minutes: 15, mode: .up), 1.25, accuracy: 1e-9)
        XCTAssertEqual(roundHours(1.24, minutes: 15, mode: .down), 1.0, accuracy: 1e-9)
        XCTAssertEqual(roundHours(1.12, minutes: 15, mode: .nearest), 1.0, accuracy: 1e-9)
        XCTAssertEqual(roundHours(1.13, minutes: 15, mode: .nearest), 1.25, accuracy: 1e-9)
        XCTAssertEqual(roundHours(0.25, minutes: 15, mode: .up), 0.25, accuracy: 1e-9) // exact multiple stays
        XCTAssertEqual(roundHours(0.2500000001, minutes: 15, mode: .up), 0.25, accuracy: 1e-9) // epsilon
        XCTAssertEqual(roundHours(1.01, minutes: 15, mode: .none), 1.01)
        XCTAssertEqual(roundHours(1.01, minutes: 0, mode: .up), 1.01)
    }
}
