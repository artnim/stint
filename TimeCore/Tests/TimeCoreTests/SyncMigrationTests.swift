import XCTest
import GRDB
@testable import TimeCore

final class SyncMigrationTests: XCTestCase {
    /// A v2 database with data, then v3: every row gets a uuid and is queued for upload (R1, R12).
    func testExistingRowsGetUUIDsAndAreQueued() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2-issue-assigned")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO client (name, archived) VALUES ('ACME', 0)")
            try db.execute(sql: "INSERT INTO project (clientId, name, archived) VALUES (1, 'Web', 0)")
            try db.execute(sql: "INSERT INTO repo (projectId, owner, name) VALUES (1, 'o', 'r')")
            try db.execute(sql: "INSERT INTO entry (projectId, startUTC, endUTC, description, tags) VALUES (1, ?, ?, 'x', '[]')",
                           arguments: [Date(timeIntervalSince1970: 1_790_000_000), Date(timeIntervalSince1970: 1_790_003_600)])
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('userName', 'Martin'), ('databasePath', '/x')")
        }
        let db = try AppDatabase(queue)
        let client = try db.allClients()[0]
        XCTAssertEqual(client.uuid.count, 36)
        XCTAssertEqual(client.modifiedBy, db.deviceId)
        XCTAssertNil(client.deletedAt)
        let outbox = try db.pendingOutbox()
        XCTAssertEqual(outbox.map { "\($0.tableName):\($0.op)" }.sorted(),
                       ["client:upsert", "entry:upsert", "project:upsert", "repo:upsert", "setting:upsert"])
        XCTAssertEqual(outbox.first { $0.tableName == "setting" }?.uuid, "userName")   // databasePath is not synced
        XCTAssertEqual(try db.read { try String.fetchAll($0, sql: "SELECT uuid FROM entry") }.count, 1)
    }

    func testRequeueAllForSyncQueuesLiveRowsAndSyncedSettings() throws {
        let db = try AppDatabase.inMemory()
        var c = Client(name: "ACME"); try db.insert(&c)
        var p = Project(clientId: c.id, name: "Web"); try db.insert(&p)
        var gone = Client(name: "Old"); try db.insert(&gone); try db.delete(gone)   // tombstone: not requeued
        try db.setSetting("userName", "Martin")
        try db.write { try $0.execute(sql: "DELETE FROM outbox") }
        try db.requeueAllForSync()
        XCTAssertEqual(try db.pendingOutbox().map { "\($0.tableName):\($0.op)" }.sorted(),
                       ["client:upsert", "project:upsert", "setting:upsert"])
    }

    func testDeviceIdIsCreatedOnceAndStable() throws {
        let queue = try DatabaseQueue()
        let a = try AppDatabase(queue)
        let b = try AppDatabase(queue)
        XCTAssertEqual(a.deviceId, b.deviceId)
        XCTAssertEqual(a.deviceId.count, 36)
    }

    func testUUIDIsUnique() throws {
        let db = try AppDatabase.inMemory()
        var c1 = Client(name: "A"); try db.insert(&c1)
        var c2 = Client(name: "B", uuid: c1.uuid)
        XCTAssertThrowsError(try db.insert(&c2))
    }
}
