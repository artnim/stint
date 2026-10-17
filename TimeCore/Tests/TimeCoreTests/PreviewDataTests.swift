import XCTest
@testable import TimeCore

final class PreviewDataTests: XCTestCase {
    func testPreviewDatabaseHasARunningStintFinishedEntriesAndIssues() throws {
        let db = AppDatabase.preview()
        XCTAssertEqual(try db.runningEntry()?.issueNumber, 1427)
        let dayAgo = Date().addingTimeInterval(-86400)
        XCTAssertEqual(try db.finishedEntries(from: dayAgo, to: Date()).count, 3)
        XCTAssertEqual(try db.openIssueRows().map(\.issue.number).sorted(), [1427, 1452])
        XCTAssertEqual(try db.allProjects().map(\.name), ["Altenso SCM"])
    }
}
