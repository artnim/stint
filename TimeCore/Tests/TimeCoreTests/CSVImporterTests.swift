import XCTest
import GRDB
@testable import TimeCore

final class CSVImporterTests: XCTestCase {
    var db: AppDatabase!
    var importer: CSVImporter!
    var fixture: URL!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        importer = CSVImporter(database: db, timeZone: berlin.timeZone)
        fixture = try XCTUnwrap(Bundle.module.url(forResource: "solidtime-sample", withExtension: "csv", subdirectory: "Fixtures"))
    }

    func testImportsFinishedNonBreakRows() throws {
        let r = try importer.importFile(at: fixture)
        XCTAssertEqual(r, CSVImportResult(imported: 3, skippedDuplicates: 0, skippedBreaks: 1, skippedUnfinished: 1))

        let entries = try db.read { try Entry.order(Column("startUTC")).fetchAll($0) }
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].description, "#101: Login, fix \"quotes\"")
        XCTAssertEqual(entries[0].startUTC, local("2026-08-03 09:00:00"))
        XCTAssertEqual(entries[0].endUTC, local("2026-08-03 10:00:00"))
        XCTAssertEqual(entries[0].tags, ["backend", "bugfix"])
        XCTAssertEqual(entries[1].description, "Review\nnotes (Sprint 12)")
        XCTAssertEqual(entries[1].tags, [])
        XCTAssertEqual(entries[2].description, "#7: Deploy")
        XCTAssertNotNil(entries[0].importedKey)
    }

    func testCreatesClientsAndProjects() throws {
        _ = try importer.importFile(at: fixture)
        XCTAssertEqual(try db.allClients().map(\.name), ["ACME", "Globex"])
        let projects = try db.allProjects()
        XCTAssertEqual(projects.map(\.name), ["App", "Website"])
        let acme = try db.allClients().first { $0.name == "ACME" }!
        XCTAssertEqual(projects.first { $0.name == "Website" }?.clientId, acme.id)
        let entries = try db.read { try Entry.order(Column("startUTC")).fetchAll($0) }
        XCTAssertEqual(entries[0].projectId, projects.first { $0.name == "Website" }?.id)
    }

    func testReimportSkipsDuplicates() throws {
        _ = try importer.importFile(at: fixture)
        let again = try importer.importFile(at: fixture)
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.skippedDuplicates, 3)
        XCTAssertEqual(try db.read { try Entry.fetchCount($0) }, 3)
        XCTAssertEqual(try db.allProjects().count, 2)
    }

    func testRejectsForeignCSV() {
        XCTAssertThrowsError(try importer.importText("a,b\n1,2\n")) { err in
            XCTAssertEqual(err as? CSVImportError, .missingColumns(["Description", "End", "Start"]))
        }
        XCTAssertThrowsError(try importer.importText("")) { err in
            XCTAssertEqual(err as? CSVImportError, .empty)
        }
    }

    func testImportedEntriesProduceTheExpectedReport() throws {
        _ = try importer.importFile(at: fixture)
        let (s, e) = monthRange(year: 2026, month: 8, calendar: berlin)
        let lines = try db.reportEntries(from: s, to: e, userName: "Martin Hans")
        let report = try XCTUnwrap(buildReport(lines, options: ReportOptions(), calendar: berlin))
        XCTAssertEqual(report.totalHours, 3.0, accuracy: 1e-9)
        XCTAssertEqual(report.days.count, 2)
        XCTAssertEqual(report.meta.client, "mehrere (2)")
    }

    func testEndNotAfterStartCountsAsUnfinished() throws {
        let text = "Description,Start,End\nbad,2026-08-03 10:00:00,2026-08-03 09:00:00\nzero,2026-08-03 10:00:00,2026-08-03 10:00:00\nok,2026-08-03 09:00:00,2026-08-03 10:00:00\n"
        let r = try importer.importText(text)
        XCTAssertEqual(r.imported, 1)
        XCTAssertEqual(r.skippedUnfinished, 2)
    }

    func testDuplicateHeaderColumnsDoNotCrash() throws {
        let text = "Description,Description,Start,End\nfirst,second,2026-08-03 09:00:00,2026-08-03 10:00:00\n"
        let r = try importer.importText(text)
        XCTAssertEqual(r.imported, 1)
        let e = try db.read { try Entry.fetchOne($0) }
        XCTAssertEqual(e?.description, "first")
    }
}
