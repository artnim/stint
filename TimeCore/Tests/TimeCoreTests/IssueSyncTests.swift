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

    func testMergeMarksAssignmentAndDeduplicates() {
        var unassigned = issue(1, title: "from repo listing")
        unassigned.assignedToMe = false
        var other = issue(3, title: "nobody's")
        other.assignedToMe = false
        let merged = IssueSync.merge(assigned: [issue(1, title: "assigned"), issue(2, repo: "app")],
                                     repoIssues: [unassigned, other])
        XCTAssertEqual(merged.map { "\($0.repoName)#\($0.number):\($0.assignedToMe)" }.sorted(),
                       ["app#2:true", "website#1:true", "website#3:false"])
        XCTAssertEqual(merged.first { $0.number == 1 }?.title, "assigned")
    }

    func testOpenIssueRowsFiltersUnassignedUnlessAsked() throws {
        var other = issue(3, title: "nobody's")
        other.assignedToMe = false
        try IssueSync.apply([issue(1), other], to: db)
        XCTAssertEqual(try db.openIssueRows().map(\.issue.number), [1])
        let all = try db.openIssueRows(assignedOnly: false)
        XCTAssertEqual(all.map(\.issue.number), [1, 3])
        XCTAssertEqual(all.map(\.issue.assignedToMe), [true, false])
        // a later sync that assigns #3 flips the flag
        try IssueSync.apply([issue(1), issue(3)], to: db)
        XCTAssertEqual(try db.openIssueRows().map(\.issue.number), [1, 3])
    }

    func testSearchRowsIncludeRecentlyClosedButOpenRowsDoNot() throws {
        var recent = issue(5, title: "closed last week")
        recent.state = "closed"; recent.updatedAt = t0.addingTimeInterval(-7 * 86400); recent.assignedToMe = false
        var old = issue(6, title: "closed long ago")
        old.state = "closed"; old.updatedAt = t0.addingTimeInterval(-60 * 86400); old.assignedToMe = false
        var unassignedOpen = issue(7, title: "open, not mine")
        unassignedOpen.assignedToMe = false
        try IssueSync.apply([issue(1), recent, old, unassignedOpen], to: db)

        XCTAssertEqual(try db.openIssueRows().map(\.issue.number), [1])
        let search = try db.searchIssueRows(closedSince: t0.addingTimeInterval(-30 * 86400))
        XCTAssertEqual(search.map(\.issue.number), [1, 7, 5])      // open first, then closed
        XCTAssertEqual(search.map(\.issue.state), ["open", "open", "closed"])
    }

    func testAddRepoParsesFullNameAndRejectsDuplicates() throws {
        let repo = try db.addRepo(fullName: " Artnim/Website ")
        XCTAssertEqual(repo.fullName, "Artnim/Website")
        XCTAssertThrowsError(try db.addRepo(fullName: "Artnim/Website"))
        XCTAssertThrowsError(try db.addRepo(fullName: "no-slash"))
        XCTAssertEqual(try db.allRepos().count, 1)
    }

    func testAddRepoRevivesATombstonedRepo() throws {
        let repo = try db.addRepo(fullName: "Artnim/Website")
        try db.delete(repo)
        XCTAssertEqual(try db.allRepos(), [])
        let again = try db.addRepo(fullName: "Artnim/Website")
        XCTAssertEqual(again.uuid, repo.uuid)
        XCTAssertEqual(try db.allRepos().count, 1)
        XCTAssertEqual(try db.pendingOutbox().filter { $0.uuid == repo.uuid }.last?.op, "upsert")
        XCTAssertThrowsError(try db.addRepo(fullName: "Artnim/Website"))
    }

    func testPartialSyncDoesNotCloseMissingIssues() throws {
        try IssueSync.apply([issue(1), issue(2, repo: "app")], to: db)
        // one account failed: apply only what the others returned, close nothing
        try IssueSync.apply([issue(1, title: "renamed")], to: db, closeMissing: false)
        let rows = try db.openIssueRows()
        XCTAssertEqual(rows.map(\.issue.number), [2, 1])
        XCTAssertEqual(rows.first { $0.issue.number == 1 }?.issue.title, "renamed")
        // next full sync closes again
        try IssueSync.apply([issue(1)], to: db, closeMissing: true)
        XCTAssertEqual(try db.openIssueRows().map(\.issue.number), [1])
    }
}
