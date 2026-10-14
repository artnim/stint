import XCTest
import GRDB
@testable import TimeCore

final class SyncLoggingTests: XCTestCase {
    var db: AppDatabase!
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws { db = try AppDatabase.inMemory() }

    private func outbox() throws -> [String] {
        try db.pendingOutbox().map { "\($0.tableName):\($0.op):\($0.uuid.prefix(4))" }
    }

    func testInsertUpdateDeleteStampAndLog() throws {
        var c = Client(name: "ACME")
        try db.insert(&c)
        XCTAssertEqual(c.modifiedBy, db.deviceId)
        XCTAssertEqual(try db.pendingOutbox().map(\.op), ["upsert"])

        c.name = "ACME Corp"
        let before = c.modifiedAt
        Thread.sleep(forTimeInterval: 0.01)
        try db.update(c)
        let stored = try db.allClients()[0]
        XCTAssertEqual(stored.name, "ACME Corp")
        XCTAssertGreaterThan(stored.modifiedAt, before)
        XCTAssertEqual(try db.pendingOutbox().map(\.op), ["upsert", "upsert"])

        try db.delete(stored)
        XCTAssertEqual(try db.allClients(), [], "tombstoned rows are hidden")
        let raw: Client? = try db.read { try $0.fetchByUUID(uuid: stored.uuid) }
        XCTAssertNotNil(raw?.deletedAt, "the row stays as a tombstone until pushed")
        XCTAssertEqual(try db.pendingOutbox().map(\.op), ["upsert", "upsert", "delete"])

        try db.purge(table: "client", uuid: stored.uuid)
        let gone: Client? = try db.read { try $0.fetchByUUID(uuid: stored.uuid) }
        XCTAssertNil(gone)
    }

    func testTimerAndRepoHelpersLog() throws {
        var p = Project(clientId: nil, name: "P"); try db.insert(&p)
        try db.start(description: "a", projectId: p.id, at: t0)
        try db.stopRunning(at: t0.addingTimeInterval(600))
        let repo = try db.addRepo(fullName: "o/r")
        try db.assignRepo(repo.id!, toProject: p.id)
        let ops = try db.pendingOutbox().map { "\($0.tableName):\($0.op)" }
        XCTAssertEqual(ops, ["project:upsert", "entry:upsert", "entry:upsert", "repo:upsert", "repo:upsert"])
    }

    func testAssignRepoBackfillLogsEachEntry() throws {
        let repo = try db.addRepo(fullName: "o/r")
        try db.start(description: "#1: x", projectId: nil, repoId: repo.id, issueNumber: 1, at: t0)
        try db.stopRunning(at: t0.addingTimeInterval(600))
        var p = Project(clientId: nil, name: "P"); try db.insert(&p)
        let before = try db.pendingOutbox().count
        try db.assignRepo(repo.id!, toProject: p.id)
        XCTAssertEqual(try db.pendingOutbox().count, before + 2)   // repo + the backfilled entry
    }

    func testSettingsLogOnlySyncedKeys() throws {
        try db.setSetting("userName", "M")
        try db.setSetting("databasePath", "/x")
        try db.setSetting("syncZoneToken", "t")
        XCTAssertEqual(try db.pendingOutbox().map(\.uuid), ["userName"])
    }

    func testTombstonesAreHiddenEverywhere() throws {
        var c = Client(name: "C"); try db.insert(&c)
        var p = Project(clientId: c.id, name: "P"); try db.insert(&p)
        let repo = try db.addRepo(fullName: "o/r")
        try db.assignRepo(repo.id!, toProject: p.id)
        try db.start(description: "x", projectId: p.id, at: t0)
        let e = try db.stopRunning(at: t0.addingTimeInterval(600))!
        try db.delete(e); try db.delete(repo); try db.delete(p); try db.delete(c)
        XCTAssertEqual(try db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400)), [])
        XCTAssertEqual(try db.entries(from: t0, to: t0.addingTimeInterval(86400)), [])
        XCTAssertEqual(try db.recents(), [])
        XCTAssertEqual(try db.allClients(), []); XCTAssertEqual(try db.allProjects(), []); XCTAssertEqual(try db.allRepos(), [])
        XCTAssertEqual(try db.openIssueRows(assignedOnly: false), [])
    }

    func testIssueCacheStillUsesThePlainHelpers() throws {
        let repo = try db.addRepo(fullName: "o/r")
        var i = IssueCache(repoId: repo.id!, number: 1, title: "t", isPullRequest: false, state: "open", updatedAt: t0)
        try db.insert(&i)
        XCTAssertEqual(try db.pendingOutbox().map(\.tableName), ["repo"])   // issueCache is not synced
    }

    func testDeletingAClientDetachesAndLogsItsProjects() throws {
        var c = Client(name: "C"); try db.insert(&c)
        var p1 = Project(clientId: c.id, name: "P1"); try db.insert(&p1)
        var p2 = Project(clientId: c.id, name: "P2"); try db.insert(&p2)
        let before = try db.pendingOutbox().count
        try db.delete(c)
        XCTAssertEqual(try db.allProjects().map(\.clientId), [nil, nil])
        let ops = try db.pendingOutbox().dropFirst(before).map { "\($0.tableName):\($0.op)" }
        XCTAssertEqual(Array(ops), ["project:upsert", "project:upsert", "client:delete"])
    }

    func testDeletingAProjectDetachesEntriesAndRepos() throws {
        var p = Project(clientId: nil, name: "P"); try db.insert(&p)
        let repo = try db.addRepo(fullName: "o/r")
        try db.assignRepo(repo.id!, toProject: p.id)
        try db.start(description: "x", projectId: p.id, at: t0)
        try db.stopRunning(at: t0.addingTimeInterval(600))
        let before = try db.pendingOutbox().count
        try db.delete(p)
        XCTAssertNil(try db.allRepos()[0].projectId)
        XCTAssertNil(try db.entries(from: t0, to: t0.addingTimeInterval(86400))[0].projectId)
        let ops = try db.pendingOutbox().dropFirst(before).map { "\($0.tableName):\($0.op)" }
        XCTAssertEqual(Array(ops), ["entry:upsert", "repo:upsert", "project:delete"])
    }

    func testDeletingARepoDetachesEntriesAndDropsItsIssueCache() throws {
        let repo = try db.addRepo(fullName: "o/r")
        try db.start(description: "x", projectId: nil, repoId: repo.id, issueNumber: 1, at: t0)
        try db.stopRunning(at: t0.addingTimeInterval(600))
        var i = IssueCache(repoId: repo.id!, number: 1, title: "t", isPullRequest: false, state: "open", updatedAt: t0)
        try db.insert(&i)
        let before = try db.pendingOutbox().count
        try db.delete(repo)
        XCTAssertNil(try db.entries(from: t0, to: t0.addingTimeInterval(86400))[0].repoId)
        XCTAssertEqual(try db.openIssueRows(assignedOnly: false), [])
        XCTAssertEqual(try db.read { try IssueCache.fetchCount($0) }, 0)
        let ops = try db.pendingOutbox().dropFirst(before).map { "\($0.tableName):\($0.op)" }
        XCTAssertEqual(Array(ops), ["entry:upsert", "repo:delete"])
    }
}
