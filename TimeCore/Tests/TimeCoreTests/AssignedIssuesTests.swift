import XCTest
import GRDB
@testable import TimeCore

final class AssignedIssuesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// A Mac-like database: one mapped repo with two open assigned issues, one unassigned, one closed.
    private func seedMac(_ db: AppDatabase) throws -> (Repo, Project) {
        var p = Project(clientId: nil, name: "Web"); try db.insert(&p)
        let r = try db.addRepo(fullName: "acme/web")
        try db.assignRepo(r.id!, toProject: p.id)
        let other = try db.addRepo(fullName: "acme/api")
        try IssueSync.apply([
            GitHubIssue(repoOwner: "acme", repoName: "web", number: 7, title: "Login", isPullRequest: false, state: "open", updatedAt: t0, assignedToMe: true),
            GitHubIssue(repoOwner: "acme", repoName: "web", number: 3, title: "Signup", isPullRequest: false, state: "open", updatedAt: t0, assignedToMe: true),
            GitHubIssue(repoOwner: "acme", repoName: "web", number: 9, title: "Not mine", isPullRequest: false, state: "open", updatedAt: t0, assignedToMe: false),
            GitHubIssue(repoOwner: "acme", repoName: "api", number: 1, title: "Closed", isPullRequest: false, state: "closed", updatedAt: t0, assignedToMe: true),
            GitHubIssue(repoOwner: "acme", repoName: "api", number: 2, title: "Rate limit", isPullRequest: false, state: "open", updatedAt: t0, assignedToMe: true),
        ], to: db)
        _ = other
        return (try db.allRepos().first { $0.name == "web" }!, p)
    }

    // R18 writer: open + assigned only, ordered by repo then number, project as uuid, one outbox row.
    func testWriterProducesOrderedPayloadAndQueuesIt() throws {
        let db = try AppDatabase.inMemory()
        let (_, p) = try seedMac(db)
        try db.write { try $0.execute(sql: "DELETE FROM outbox") }
        try db.writeAssignedIssueSnapshot(now: t0)
        let row = try db.read { try AssignedIssues.fetchOne($0) }!
        XCTAssertEqual(row.uuid, AssignedIssues.fixedUUID)
        XCTAssertEqual(row.fetchedAt, t0)
        XCTAssertEqual(row.modifiedAt, t0)
        let items = try JSONDecoder().decode([AssignedIssueItem].self, from: Data(row.payload.utf8))
        XCTAssertEqual(items, [
            AssignedIssueItem(repo: "acme/api", number: 2, title: "Rate limit", project: nil),
            AssignedIssueItem(repo: "acme/web", number: 3, title: "Signup", project: p.uuid),
            AssignedIssueItem(repo: "acme/web", number: 7, title: "Login", project: p.uuid),
        ])
        XCTAssertEqual(try db.pendingOutbox().map { "\($0.tableName):\($0.op)" }, ["assignedIssues:upsert"])
        // writing again updates the same row (no second uuid)
        try db.writeAssignedIssueSnapshot(now: t0.addingTimeInterval(60))
        XCTAssertEqual(try db.read { try AssignedIssues.fetchCount($0) }, 1)
    }

    // R18 reader: the cache is replaced from the payload; repos resolved by full name; unknown repo skipped.
    func testReaderReplacesCacheAndSkipsUnknownRepo() throws {
        let watch = try AppDatabase.inMemory()
        let web = try watch.db_addRepoForTest("acme/web")
        var stale = IssueCache(repoId: web.id!, number: 99, title: "Old", isPullRequest: false, state: "open", updatedAt: t0)
        try watch.insert(&stale)
        let payload = #"[{"repo":"acme/api","number":2,"title":"Rate limit","project":null},{"repo":"acme/web","number":7,"title":"Login","project":null}]"#
        var row = AssignedIssues(uuid: AssignedIssues.fixedUUID, fetchedAt: t0, payload: payload)
        try watch.write { try $0.syncInsert(&row, deviceId: "x", now: self.t0) }
        XCTAssertEqual(try watch.applyAssignedIssueSnapshot(), 1)
        let rows = try watch.openIssueRows()
        XCTAssertEqual(rows.map { "\($0.repo.fullName)#\($0.issue.number)" }, ["acme/web#7"])
        XCTAssertTrue(rows[0].issue.assignedToMe)
        XCTAssertEqual(rows[0].issue.state, "open")
        XCTAssertEqual(rows[0].issue.updatedAt, t0)
    }

    // Review Focus 2: the repo arrives after the snapshot; re-running the reader picks the issue up.
    func testReaderPicksUpRepoThatArrivesLater() throws {
        let watch = try AppDatabase.inMemory()
        let payload = #"[{"repo":"acme/api","number":2,"title":"Rate limit","project":null}]"#
        var row = AssignedIssues(uuid: AssignedIssues.fixedUUID, fetchedAt: t0, payload: payload)
        try watch.write { try $0.syncInsert(&row, deviceId: "x", now: self.t0) }
        XCTAssertEqual(try watch.applyAssignedIssueSnapshot(), 0)
        _ = try watch.db_addRepoForTest("acme/api")
        XCTAssertEqual(try watch.applyAssignedIssueSnapshot(), 1)
        XCTAssertEqual(try watch.openIssueRows().map(\.issue.number), [2])
    }

    // Review Focus 3: a malformed payload leaves the cache as it was.
    func testMalformedPayloadLeavesCacheUntouched() throws {
        let watch = try AppDatabase.inMemory()
        let web = try watch.db_addRepoForTest("acme/web")
        var good = IssueCache(repoId: web.id!, number: 7, title: "Login", isPullRequest: false, state: "open", updatedAt: t0)
        try watch.insert(&good)
        var row = AssignedIssues(uuid: AssignedIssues.fixedUUID, fetchedAt: t0, payload: "[{\"repo\":")
        try watch.write { try $0.syncInsert(&row, deviceId: "x", now: self.t0) }
        XCTAssertEqual(try watch.applyAssignedIssueSnapshot(), -1)
        XCTAssertEqual(try watch.openIssueRows().map(\.issue.number), [7])
    }

    // R18 LWW: two writers, the newer fetchedAt wins on a third device, and the row syncs like any other.
    func testNewerSnapshotWinsOnThirdDevice() async throws {
        let server = InMemorySyncServer()
        let mac = try makeDevice(server), phone = try makeDevice(server), watch = try makeDevice(server)
        _ = try seedMac(mac.db)
        try mac.db.writeAssignedIssueSnapshot(now: t0)
        _ = try await mac.engine.sync()
        _ = try await phone.engine.sync()
        try IssueSync.apply([GitHubIssue(repoOwner: "acme", repoName: "web", number: 8, title: "Newer", isPullRequest: false, state: "open", updatedAt: t0, assignedToMe: true)], to: phone.db)
        try phone.db.writeAssignedIssueSnapshot(now: t0.addingTimeInterval(600))
        _ = try await phone.engine.sync()
        _ = try await watch.engine.sync()
        XCTAssertEqual(try watch.db.applyAssignedIssueSnapshot(), 1)
        XCTAssertEqual(try watch.db.openIssueRows().map(\.issue.number), [8])
        _ = try await mac.engine.sync()
        let macRow = try mac.db.read { try AssignedIssues.fetchOne($0) }!
        XCTAssertEqual(macRow.fetchedAt, t0.addingTimeInterval(600), "the Mac stores the newer row but keeps its own cache")
        XCTAssertEqual(try mac.db.openIssueRows().map(\.issue.number).sorted(), [2, 3, 7])
    }

    // Review Focus 1 / R7 across three peers.
    func testThreePeersConvergeOnLaterStart() async throws {
        let server = InMemorySyncServer()
        let mac = try makeDevice(server), phone = try makeDevice(server), watch = try makeDevice(server)
        try mac.db.start(description: "on the mac", projectId: nil, at: t0)
        _ = try await mac.engine.sync(); _ = try await phone.engine.sync()
        try watch.db.start(description: "on the watch", projectId: nil, at: t0.addingTimeInterval(900))
        _ = try await watch.engine.sync(); _ = try await mac.engine.sync(); _ = try await phone.engine.sync(); _ = try await watch.engine.sync()
        for db in [mac.db, phone.db, watch.db] {
            XCTAssertEqual(try db.runningEntry()?.description, "on the watch")
            let finished = try db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400))
            XCTAssertEqual(finished.map(\.description), ["on the mac"])
            XCTAssertEqual(finished[0].endUTC, t0.addingTimeInterval(900))
        }
    }

    // AccountSync writes the snapshot after a successful apply.
    func testAccountSyncWritesSnapshot() async throws {
        let db = try AppDatabase.inMemory()
        let good = "https://api.github.com/issues?filter=assigned&state=open&per_page=100"
        let closed = "https://api.github.com/issues?filter=assigned&state=closed&since=2026-10-10T08:00:00Z&per_page=100"
        let page = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "github-issues-page1", withExtension: "json", subdirectory: "Fixtures")))
        let transport = FakeTransport(responses: [good: (200, page, [:]), closed: (200, Data("[]".utf8), [:])])
        let outcome = await AccountSync.run(accounts: [GitHubAccountCredential(label: "a", token: "A")], db: db,
                                            closedSince: Date(timeIntervalSince1970: 1_791_619_200),
                                            makeClient: { GitHubClient(token: $0, transport: transport) })
        XCTAssertTrue(outcome.applied)
        let row = try db.read { try AssignedIssues.fetchOne($0) }
        XCTAssertNotNil(row)
        let items = try JSONDecoder().decode([AssignedIssueItem].self, from: Data(row!.payload.utf8))
        XCTAssertEqual(items.map(\.number).sorted(), try db.openIssueRows().map(\.issue.number).sorted())
    }
}

private extension AppDatabase {
    /// A tracked repo without going through GitHub (the watch receives repos by sync; tests insert them directly).
    func db_addRepoForTest(_ fullName: String) throws -> Repo { try addRepo(fullName: fullName) }
}
