import Foundation
import GRDB
@testable import TimeCore

/// A "device": its own in-memory database and an engine talking to the shared fake server.
func makeDevice(_ server: InMemorySyncServer, now: @escaping @Sendable () -> Date = { Date() }) throws -> (db: AppDatabase, engine: SyncEngine) {
    let db = try AppDatabase.inMemory()
    return (db, SyncEngine(database: db, transport: server, now: now))
}

/// Writes a synced row with an explicit stamp, the way a user edit on that device at that time would.
func edit<T: SyncableRecord>(_ db: AppDatabase, _ row: inout T, at: Date, _ change: (inout T) -> Void) throws {
    change(&row)
    var r = row
    try db.write { try $0.syncUpdate(&r, deviceId: db.deviceId, now: at) }
    row = r
}

func tombstone<T: SyncableRecord>(_ db: AppDatabase, _ row: T, at: Date) throws {
    var r = row
    try db.write { try $0.syncTombstone(&r, deviceId: db.deviceId, now: at) }
}

/// Records which transport calls happened, in order.
actor SpyTransport: SyncTransport {
    let inner: InMemorySyncServer
    var calls: [String] = []
    init(_ inner: InMemorySyncServer) { self.inner = inner }
    func fetchChanges(since token: String?) async throws -> SyncChanges { calls.append("fetch"); return try await inner.fetchChanges(since: token) }
    func save(_ records: [SyncRecord]) async throws -> [SyncRecordID: SyncSaveOutcome] { calls.append("save"); return try await inner.save(records) }
    func delete(_ ids: [SyncRecordID]) async throws { calls.append("delete"); try await inner.delete(ids) }
}
