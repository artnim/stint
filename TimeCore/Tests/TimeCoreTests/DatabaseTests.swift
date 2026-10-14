import XCTest
import GRDB
@testable import TimeCore

final class DatabaseTests: XCTestCase {
    var db: AppDatabase!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
    }

    func testMigrationCreatesTables() throws {
        let tables = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        for t in ["client", "project", "repo", "entry", "issueCache", "setting"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
    }

    func testIssueCacheHasAssignedToMeColumnDefaultingToTrue() throws {
        let columns = try db.read { try $0.columns(in: "issueCache").map(\.name) }
        XCTAssertTrue(columns.contains("assignedToMe"))
        var repo = Repo(owner: "o", name: "r")
        try db.insert(&repo)
        try db.write { db in
            try db.execute(sql: "INSERT INTO issueCache (repoId, number, title, isPullRequest, state, updatedAt) VALUES (?, 1, 't', 0, 'open', ?)",
                           arguments: [repo.id, Date()])
        }
        XCTAssertEqual(try db.read { try IssueCache.fetchOne($0) }?.assignedToMe, true)
    }

    func testBackupCopyContainsData() throws {
        var c = Client(name: "ACME")
        try db.write { try c.insert($0) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try db.backup(to: url)
        let copy = try AppDatabase.open(at: url)
        XCTAssertEqual(try copy.allClients().map(\.name), ["ACME"])
    }

    func testStartStopRoundTrip() throws {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let e = try db.start(description: "#12: fix login", projectId: nil, at: t0)
        XCTAssertNotNil(e.id)
        XCTAssertNil(e.endUTC)
        XCTAssertEqual(try db.runningEntry()?.id, e.id)

        let stopped = try db.stopRunning(at: t0.addingTimeInterval(1800))
        XCTAssertEqual(stopped?.id, e.id)
        XCTAssertEqual(stopped?.hours, 0.5)
        XCTAssertNil(try db.runningEntry())
    }

    func testStartingWhileRunningStopsThePreviousOneAtTheNewStart() throws {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try db.start(description: "a", projectId: nil, at: t0)
        let second = try db.start(description: "b", projectId: nil, at: t0.addingTimeInterval(600))
        let entries = try db.read { try Entry.order(Column("startUTC")).fetchAll($0) }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, first.id)
        XCTAssertEqual(entries[0].endUTC, t0.addingTimeInterval(600))
        XCTAssertEqual(try db.runningEntry()?.id, second.id)
    }

    func testFinishedEntriesInRangeExcludeRunningAndOutOfRange() throws {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try db.start(description: "old", projectId: nil, at: t0.addingTimeInterval(-7200))
        _ = try db.stopRunning(at: t0.addingTimeInterval(-3600))
        _ = try db.start(description: "in", projectId: nil, at: t0)
        _ = try db.stopRunning(at: t0.addingTimeInterval(900))
        _ = try db.start(description: "running", projectId: nil, at: t0.addingTimeInterval(1000))

        let got = try db.finishedEntries(from: t0, to: t0.addingTimeInterval(86400))
        XCTAssertEqual(got.map(\.description), ["in"])
        let all = try db.entries(from: t0, to: t0.addingTimeInterval(86400))
        XCTAssertEqual(all.map(\.description), ["in", "running"])
    }

    func testGenericHelpers() throws {
        var c = Client(name: "ACME")
        try db.insert(&c)
        XCTAssertNotNil(c.id)
        c.name = "ACME Corp"
        try db.update(c)
        XCTAssertEqual(try db.allClients().map(\.name), ["ACME Corp"])
        try db.delete(c)
        XCTAssertEqual(try db.allClients(), [])
    }

    func testRecentsAreDistinctAndNewestFirst() throws {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var p = Project(clientId: nil, name: "P")
        try db.write { try p.insert($0) }
        for (i, d) in ["a", "b", "a", "c"].enumerated() {
            _ = try db.start(description: d, projectId: p.id, at: t0.addingTimeInterval(Double(i) * 600))
            _ = try db.stopRunning(at: t0.addingTimeInterval(Double(i) * 600 + 300))
        }
        let r = try db.recents(limit: 10)
        XCTAssertEqual(r.map(\.description), ["c", "a", "b"])
        XCTAssertEqual(r.first?.projectId, p.id)
    }

    func testSettingsRoundTrip() throws {
        XCTAssertNil(try db.setting("userName"))
        try db.setSetting("userName", "Martin Hans")
        XCTAssertEqual(try db.setting("userName"), "Martin Hans")
        try db.setSetting("userName", "M")
        XCTAssertEqual(try db.setting("userName"), "M")
    }
}
