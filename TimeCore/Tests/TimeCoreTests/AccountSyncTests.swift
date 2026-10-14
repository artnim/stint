import XCTest
@testable import TimeCore

final class AccountSyncTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func testMergesAccountsAndReportsRejectedOnes() async throws {
        let db = try AppDatabase.inMemory()
        let since = Date(timeIntervalSince1970: 1_791_619_200)
        let good = "https://api.github.com/issues?filter=assigned&state=open&per_page=100"
        let goodClosed = "https://api.github.com/issues?filter=assigned&state=closed&since=2026-10-10T08:00:00Z&per_page=100"
        let transportGood = FakeTransport(responses: [good: (200, try fixture("github-issues-page1"), [:]),
                                                      goodClosed: (200, Data("[]".utf8), [:])])
        let transportBad = FakeTransport(responses: [good: (401, Data("{}".utf8), [:])])
        let outcome = await AccountSync.run(
            accounts: [GitHubAccountCredential(label: "org-a", token: "A"), GitHubAccountCredential(label: "org-b", token: "B")],
            db: db, closedSince: since,
            makeClient: { token in GitHubClient(token: token, transport: token == "A" ? transportGood : transportBad) })
        XCTAssertEqual(outcome.rejectedLabels, ["org-b"])
        XCTAssertTrue(outcome.applied)
        XCTAssertEqual(try db.openIssueRows().map(\.issue.number).sorted(), [42, 101])
    }
}
