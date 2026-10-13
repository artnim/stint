import XCTest
@testable import TimeCore

final class SanityCheckTests: XCTestCase {
    private func e(_ s: String, _ end: String, _ d: String = "work") -> ReportEntry {
        ReportEntry(description: d, start: local(s), end: local(end))
    }

    func testCleanDataHasNoWarnings() {
        let es = [e("2026-08-03 09:00", "2026-08-03 10:00"), e("2026-08-03 10:00", "2026-08-03 10:30")]
        XCTAssertEqual(sanityCheck(es, minutes: 15, syntheticEnds: false, calendar: berlin), [])
    }

    func testDuplicate() {
        let es = [e("2026-08-03 09:00", "2026-08-03 10:00", "#1: a"), e("2026-08-03 09:00", "2026-08-03 10:00", "#1: a")]
        let w = sanityCheck(es, minutes: 15, syntheticEnds: false, calendar: berlin)
        XCTAssertEqual(w, ["2026-08-03  duplicate: #1 a at 09:00",
                           "2026-08-03  overlap: 09:00-10:00 and 09:00-10:00"])
    }

    func testOverlap() {
        let es = [e("2026-08-03 09:00", "2026-08-03 10:00"), e("2026-08-03 09:45", "2026-08-03 10:45")]
        let w = sanityCheck(es, minutes: 15, syntheticEnds: false, calendar: berlin)
        XCTAssertEqual(w, ["2026-08-03  overlap: 09:00-10:00 and 09:45-10:45"])
    }

    func testSmallOverlapIgnoredWithSyntheticEnds() {
        let es = [e("2026-08-03 09:00", "2026-08-03 10:00"), e("2026-08-03 09:50", "2026-08-03 10:50")]
        XCTAssertEqual(sanityCheck(es, minutes: 15, syntheticEnds: true, calendar: berlin), [])
        XCTAssertEqual(sanityCheck(es, minutes: 15, syntheticEnds: false, calendar: berlin).count, 1)
    }

    func testOffGridAndZeroLength() {
        let es = [e("2026-08-03 09:00", "2026-08-03 09:10", "#2: ten minutes"),
                  e("2026-08-03 10:00", "2026-08-03 10:00", "zero")]
        let w = sanityCheck(es, minutes: 15, syntheticEnds: false, calendar: berlin)
        XCTAssertEqual(w, ["2026-08-03  duration 10 min is not a multiple of 15 min: #2 ten minutes",
                           "2026-08-03  zero-length entry:  zero"])
    }

    func testMissingDescription() {
        let es = [e("2026-08-03 09:00", "2026-08-03 10:00", "")]
        XCTAssertEqual(sanityCheck(es, minutes: 15, syntheticEnds: false, calendar: berlin),
                       ["2026-08-03 09:00  entry without description"])
    }
}
