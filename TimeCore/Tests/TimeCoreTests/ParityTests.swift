import PDFKit
import XCTest
@testable import TimeCore

/// Run with:
///   PARITY_CSV=~/Downloads/export.csv PARITY_PDF=~/Projects/solidtime-report/Timesheet_2026-09.pdf \
///   PARITY_MONTH=2026-09 swift test --filter ParityTests
final class ParityTests: XCTestCase {
    func testMonthlyPresetMatchesThePythonWrapperOutput() throws {
        let env = ProcessInfo.processInfo.environment
        guard let csv = env["PARITY_CSV"], let ref = env["PARITY_PDF"], let month = env["PARITY_MONTH"] else {
            throw XCTSkip("set PARITY_CSV, PARITY_PDF and PARITY_MONTH=YYYY-MM")
        }
        let parts = month.split(separator: "-").map { Int($0)! }
        let db = try AppDatabase.inMemory()
        _ = try CSVImporter(database: db, timeZone: berlin.timeZone)
            .importFile(at: URL(fileURLWithPath: (csv as NSString).expandingTildeInPath))

        var o = ReportOptions()
        o.language = .en
        o.title = expandTitle("Timesheet {Month} {Year}", month: parts[1], year: parts[0], lang: .en)
        o.gridMinutes = 15
        o.durationRounding = .up
        o.startSnap = .ceil
        let (s, e) = monthRange(year: parts[0], month: parts[1], calendar: berlin)
        let lines = try db.reportEntries(from: s, to: e, userName: "Martin Hans")
        let report = try XCTUnwrap(buildReport(lines, options: o, calendar: berlin))
        let ours = try XCTUnwrap(PDFDocument(data: PDFRenderer.render(report))?.string)
        let theirs = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: (ref as NSString).expandingTildeInPath))?.string)

        func hours(_ s: String) -> [String] { s.matches(of: #/\d+\.\d\d h/#).map { String($0.output) }.sorted() }
        func days(_ s: String) -> [String] {
            s.matches(of: #/(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), \d\d \w{3} \d{4}/#).map { String($0.output.0) }
        }
        XCTAssertEqual(hours(ours), hours(theirs), "hour values differ")
        XCTAssertEqual(days(ours), days(theirs), "day rows differ")
        XCTAssertEqual(report.entryCount, theirs.matches(of: #/ – \d\d:\d\d/#).count, "entry count differs")
        XCTAssertTrue(theirs.contains(fmtHours(report.totalHours, .en)), "total \(report.totalHours) not in reference")
    }
}
