import XCTest
@testable import TimeCore

final class ReportEntryTests: XCTestCase {
    private func e(_ d: String) -> ReportEntry {
        ReportEntry(description: d, start: local("2026-08-03 09:00"), end: local("2026-08-03 10:00"))
    }

    func testIssuePrefixIsSplitOff() {
        let r = e("#1234: Fix login")
        XCTAssertEqual(r.issue, "#1234")
        XCTAssertEqual(r.description, "Fix login")
        XCTAssertEqual(r.hours, 1.0)
    }

    func testIssuePrefixVariants() {
        XCTAssertEqual(e("#7 - thing").issue, "#7")
        XCTAssertEqual(e("#7 – thing").description, "thing")
        XCTAssertEqual(e("#7").description, "")
        XCTAssertEqual(e("no issue #7").issue, "")
        XCTAssertEqual(e("#7: first line\nsecond").description, "first line\nsecond")
    }

    func testHoursCanBeOverriddenAndTagsAreTrimmed() {
        let r = ReportEntry(description: "x", start: local("2026-08-03 09:00"), end: local("2026-08-03 10:00"),
                            hours: 1.25, tags: [" a ", "", "b"])
        XCTAssertEqual(r.hours, 1.25)
        XCTAssertEqual(r.tags, ["a", "b"])
        XCTAssertEqual(r.start, r.rawStart)
        XCTAssertEqual(r.end, r.rawEnd)
    }

    func testDayUsesTheCalendarTimeZone() {
        // 00:30 Berlin on Aug 4 is 22:30 UTC on Aug 3
        let r = ReportEntry(description: "late", start: local("2026-08-04 00:30"), end: local("2026-08-04 01:00"))
        XCTAssertEqual(r.day(in: berlin), Day(year: 2026, month: 8, day: 4))
        XCTAssertEqual(Day(year: 2026, month: 8, day: 4).isoString, "2026-08-04")
        XCTAssertLessThan(Day(year: 2026, month: 8, day: 4), Day(year: 2026, month: 9, day: 1))
    }
}
