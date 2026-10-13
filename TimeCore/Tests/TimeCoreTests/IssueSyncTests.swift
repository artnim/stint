import XCTest
import GRDB
@testable import TimeCore

final class IssueSyncTests: XCTestCase {
    var db: AppDatabase!
    let t0 = Date(timeIntervalSince1970: 1_791_619_200)

    override func setUpWithError() throws { db = try AppDatabase.inMemory() }

    private func issue(_ n: Int, repo: String = "website", title: String = "t") -> GitHubIssue {
        GitHubIssue(repoOwner: "artnim", repoName: repo, number: n, title: title, isPullRequest: false, state: "open", updatedAt: t0)
    }

    func testCreatesReposAndCacheRows() throws {
        try IssueSync.apply([issue(1), issue(2, repo: "app")], to: db)
        XCTAssertEqual(try db.allRepos().map(\.fullName), ["artnim/app", "artnim/website"])
        let rows = try db.openIssueRows()
        XCTAssertEqual(rows.map(\.issue.number), [2, 1])      // unmapped repos sorted by name, then number
        XCTAssertNil(rows[0].projectName)
    }

    func testUpdatesTitlesKeepsMappingAndClosesMissing() throws {
        try IssueSync.apply([issue(1, title: "old"), issue(2)], to: db)
        let repo = try db.allRepos()[0]
        var p = Project(clientId: nil, name: "Website")
        try db.write { try p.insert($0) }
        try db.assignRepo(repo.id!, toProject: p.id)

        try IssueSync.apply([issue(1, title: "new")], to: db)
        let rows = try db.openIssueRows()
        XCTAssertEqual(rows.map(\.issue.number), [1])
        XCTAssertEqual(rows[0].issue.title, "new")
        XCTAssertEqual(rows[0].projectName, "Website")
        XCTAssertEqual(try db.allRepos()[0].projectId, p.id)
        let closed = try db.read { try IssueCache.filter(Column("number") == 2).fetchOne($0) }
        XCTAssertEqual(closed?.state, "closed")

        try IssueSync.apply([issue(1), issue(2)], to: db)     // reappears -> open again
        XCTAssertEqual(try db.openIssueRows().map(\.issue.number), [1, 2])
    }

    func testAssigningRepoBackfillsUnassignedEntriesOnly() throws {
        try IssueSync.apply([issue(1)], to: db)
        let repo = try db.allRepos()[0]
        var other = Project(clientId: nil, name: "Other")
        var target = Project(clientId: nil, name: "Target")
        try db.write { try other.insert($0); try target.insert($0) }
        let a = try db.start(description: "a", projectId: nil, repoId: repo.id, at: t0)
        _ = try db.stopRunning(at: t0.addingTimeInterval(600))
        let b = try db.start(description: "b", projectId: other.id, repoId: repo.id, at: t0.addingTimeInterval(1200))
        _ = try db.stopRunning(at: t0.addingTimeInterval(1800))
        try db.assignRepo(repo.id!, toProject: target.id)
        let ea = try db.read { try Entry.fetchOne($0, key: a.id!) }
        let eb = try db.read { try Entry.fetchOne($0, key: b.id!) }
        XCTAssertEqual(ea?.projectId, target.id)
        XCTAssertEqual(eb?.projectId, other.id)
    }

    func testRowsAreGroupedByProjectNameThenRepoThenNumber() throws {
        try IssueSync.apply([issue(5, repo: "zeta"), issue(3, repo: "alpha"), issue(9, repo: "alpha")], to: db)
        var p = Project(clientId: nil, name: "Z-Project")
        try db.write { try p.insert($0) }
        let zeta = try db.allRepos().first { $0.name == "zeta" }!
        try db.assignRepo(zeta.id!, toProject: p.id)
        let rows = try db.openIssueRows()
        XCTAssertEqual(rows.map { "\($0.projectName ?? "-")/\($0.repo.name)#\($0.issue.number)" },
                       ["Z-Project/zeta#5", "-/alpha#3", "-/alpha#9"])
    }
}
