import XCTest
@testable import TimeCore

final class FormattingTests: XCTestCase {
    func testHours() {
        XCTAssertEqual(fmtHours(140.0, .de), "140,00 h")
        XCTAssertEqual(fmtHours(1.25, .en), "1.25 h")
        XCTAssertEqual(fmtHours(0.125, .en), "0.12 h") // printf rounds the binary value like Python's f"{:.2f}"
    }

    func testDate() {
        XCTAssertEqual(fmtDate(Day(year: 2026, month: 8, day: 3), .de), "Montag, 03.08.2026")
        XCTAssertEqual(fmtDate(Day(year: 2026, month: 8, day: 3), .en), "Monday, 03 Aug 2026")
        XCTAssertEqual(fmtDate(Day(year: 2026, month: 8, day: 9), .en), "Sunday, 09 Aug 2026")
    }

    func testPeriod() {
        XCTAssertEqual(fmtPeriod(Day(year: 2026, month: 8, day: 3), Day(year: 2026, month: 8, day: 28), .de), "03.08.2026 – 28.08.2026")
        XCTAssertEqual(fmtPeriod(Day(year: 2026, month: 8, day: 3), Day(year: 2026, month: 8, day: 28), .en), "03 Aug 2026 – 28 Aug 2026")
    }

    func testShortTags() {
        XCTAssertEqual(shortTags(["a", "b", "c", "d"], maxTags: 3, maxChars: 26), "a, b, c, +1")
        XCTAssertEqual(shortTags(["this is a very long tag name indeed"], maxTags: 3, maxChars: 10), "this is a…")
        XCTAssertEqual(shortTags([], maxTags: 3, maxChars: 26), "")
    }

    func testStrings() {
        XCTAssertEqual(Strings.of(.de).title, "Leistungsnachweis")
        XCTAssertEqual(Strings.of(.en).title, "Time Report")
        XCTAssertEqual(Strings.of(.de).weekdays[0], "Montag")
        XCTAssertEqual(Strings.of(.en).months[9], "September")
    }

    func testExpandTitle() {
        XCTAssertEqual(expandTitle("Timesheet {Month} {Year}", month: 9, year: 2026, lang: .en), "Timesheet September 2026")
        XCTAssertEqual(expandTitle("Leistungsnachweis {Monat} {Jahr}", month: 3, year: 2026, lang: .de), "Leistungsnachweis März 2026")
        XCTAssertEqual(expandTitle("Plain", month: 3, year: 2026, lang: .de), "Plain")
    }
}
