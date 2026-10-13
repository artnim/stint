import PDFKit
import XCTest
@testable import TimeCore

final class PDFRendererTests: XCTestCase {
    private func e(_ s: String, _ end: String, _ d: String = "work", tags: [String] = []) -> ReportEntry {
        ReportEntry(description: d, project: "Website", client: "ACME", user: "Martin Hans",
                    start: local(s), end: local(end), tags: tags)
    }

    private func pdf(_ report: Report) throws -> PDFDocument {
        let data = PDFRenderer.render(report)
        return try XCTUnwrap(PDFDocument(data: data))
    }

    func testSinglePageContainsHeaderDaysEntriesAndTotal() throws {
        var o = ReportOptions()
        o.summary = true
        let report = try XCTUnwrap(buildReport([
            e("2026-08-03 09:00", "2026-08-03 10:00", "#101: Login & <session>", tags: ["backend", "bugfix"]),
            e("2026-08-03 10:00", "2026-08-03 10:30", "Review"),
            e("2026-08-04 14:00", "2026-08-04 15:30", "#7: Deploy", tags: ["ops"]),
            e("2026-08-04 16:00", "2026-08-04 16:15", "#8: Hotfix"),
        ], options: o, calendar: berlin))
        let doc = try pdf(report)
        XCTAssertEqual(doc.pageCount, 1)
        let text = try XCTUnwrap(doc.string)
        for needle in ["Leistungsnachweis", "Kunde", "ACME", "Website", "Martin Hans",
                       "03.08.2026 – 04.08.2026", "Montag, 03.08.2026", "Dienstag, 04.08.2026",
                       "09:00 – 10:00", "#101", "Login & <session>", "backend, bugfix",
                       "1,00 h", "1,50 h", "1,75 h", "Gesamt", "3,25 h",
                       "2 Arbeitstage · 4 Einträge", "Aufteilung nach Tags", "ohne Tag"] {
            XCTAssertTrue(text.contains(needle), "missing: \(needle)")
        }
        XCTAssertEqual(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Leistungsnachweis")
        XCTAssertEqual(doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Martin Hans")
    }

    func testLongReportPaginatesAndRepeatsTheColumnHeader() throws {
        var entries: [ReportEntry] = []
        for day in 1...28 {
            for h in 8...12 {
                entries.append(e(String(format: "2026-09-%02d %02d:00", day, h), String(format: "2026-09-%02d %02d:45", day, h),
                                 "#\(day * 100 + h): a reasonably long description that wraps onto a second line inside the activity column"))
            }
        }
        var o = ReportOptions()
        o.language = .en
        o.title = "Timesheet September 2026"
        let report = try XCTUnwrap(buildReport(entries, options: o, calendar: berlin))
        let doc = try pdf(report)
        XCTAssertGreaterThan(doc.pageCount, 2)
        let page2 = try XCTUnwrap(doc.page(at: 1)?.string)
        XCTAssertTrue(page2.contains("Activity"), "column header not repeated on page 2")
        XCTAssertTrue(page2.contains("ACME · Website · 01 Sep 2026 – 28 Sep 2026"), "footer missing on page 2")
        XCTAssertTrue(page2.hasSuffix("2") || page2.contains("\n2"), "page number missing")
        let last = try XCTUnwrap(doc.page(at: doc.pageCount - 1)?.string)
        XCTAssertTrue(last.contains("105.00 h"))
    }

    func testColumnsFollowTheReport() throws {
        var o = ReportOptions()
        o.showTimes = false
        o.showTags = false
        let report = try XCTUnwrap(buildReport([e("2026-08-03 09:00", "2026-08-03 10:00", tags: ["t"])], options: o, calendar: berlin))
        let text = try XCTUnwrap(try pdf(report).string)
        XCTAssertFalse(text.contains("09:00"))
        XCTAssertFalse(text.contains("Tags"))
        XCTAssertTrue(text.contains("Tätigkeit"))
    }
}
