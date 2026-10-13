import XCTest
@testable import TimeCore

final class CollisionsTests: XCTestCase {
    private func make(_ s: String, _ e: String, snapMode: SnapMode = .nearest) -> ReportEntry {
        var r = ReportEntry(description: "x", start: local(s), end: local(e))
        r.start = snap(r.rawStart, minutes: 15, mode: snapMode, calendar: berlin)
        r.end = r.start.addingTimeInterval(r.hours * 3600)
        return r
    }

    func testSnappingInducedOverlapIsNudged() {
        // raw 09:00-09:52 and 09:52-10:30: intervals touch but do not overlap.
        // nearest snap puts the second start at 09:45 (< 09:52 displayed end) -> nudged to 10:00
        var es = [make("2026-08-03 09:00", "2026-08-03 09:52"), make("2026-08-03 09:52", "2026-08-03 10:30")]
        XCTAssertEqual(hhmm(es[1].start), "09:45")   // precondition: snapping did create the collision
        resolveSnapCollisions(&es, minutes: 15, mode: .nearest, syntheticEnds: false, calendar: berlin)
        XCTAssertEqual(hhmm(es[1].start), "10:00")
        XCTAssertEqual(es[1].hours, 38.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(hhmm(es[1].end), "10:38")
    }

    func testRealOverlapIsLeftVisible() {
        var es = [make("2026-08-03 09:00", "2026-08-03 10:00"), make("2026-08-03 09:30", "2026-08-03 10:30")]
        resolveSnapCollisions(&es, minutes: 15, mode: .nearest, syntheticEnds: false, calendar: berlin)
        XCTAssertEqual(hhmm(es[1].start), "09:30")
    }

    func testRealOverlapIsNudgedWithSyntheticEnds() {
        var es = [make("2026-08-03 09:00", "2026-08-03 10:00"), make("2026-08-03 09:30", "2026-08-03 10:30")]
        resolveSnapCollisions(&es, minutes: 15, mode: .nearest, syntheticEnds: true, calendar: berlin)
        XCTAssertEqual(hhmm(es[1].start), "10:00")
    }

    func testChainOfNudgesCarriesForward() {
        // second is nudged to 10:00-10:15; third raw 10:07 snaps to 10:00 (< 10:15) and is nudged to 10:15
        var es = [make("2026-08-03 09:00", "2026-08-03 09:52"),
                  make("2026-08-03 09:52", "2026-08-03 10:07"),
                  make("2026-08-03 10:07", "2026-08-03 10:30")]
        resolveSnapCollisions(&es, minutes: 15, mode: .nearest, syntheticEnds: false, calendar: berlin)
        XCTAssertEqual(hhmm(es[1].start), "10:00")
        XCTAssertEqual(hhmm(es[1].end), "10:15")
        XCTAssertEqual(hhmm(es[2].start), "10:15")
        XCTAssertEqual(hhmm(es[2].end), "10:38")
    }

    func testDifferentDaysNeverInteract() {
        var es = [make("2026-08-03 23:50", "2026-08-04 00:20"), make("2026-08-04 00:21", "2026-08-04 00:40")]
        resolveSnapCollisions(&es, minutes: 15, mode: .nearest, syntheticEnds: false, calendar: berlin)
        XCTAssertEqual(hhmm(es[1].start), "00:15")
    }

    func testDisabledIsANoop() {
        var es = [make("2026-08-03 09:00", "2026-08-03 09:52"), make("2026-08-03 09:53", "2026-08-03 10:30")]
        let before = es
        resolveSnapCollisions(&es, minutes: 15, mode: .none, syntheticEnds: false, calendar: berlin)
        XCTAssertEqual(es, before)
    }
}
