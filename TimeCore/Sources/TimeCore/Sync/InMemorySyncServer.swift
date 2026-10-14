import Foundation
import GRDB

/// A fake server shared by the "devices" in tests: a record store plus a change log with
/// sequence numbers; the token is the last sequence number a client has seen.
///
/// Change tags are modelled like CloudKit's `.ifServerRecordUnchanged`: every stored record has a version.
/// A save succeeds for a new recordName or when it carries the server's current version (and bumps it);
/// a save for an existing record with a missing or stale version fails with "server changed"; a save for a
/// deleted record returns `.notFound`. `SyncRecord` has no slot for transport metadata, so the versions a
/// caller knows live beside it: in the device's `syncMeta` table for `device(_:)` (as `CloudKitTransport`
/// keeps its tags), or in one side table for callers that use the server directly as a transport.
public actor InMemorySyncServer: SyncTransport {
    public struct Failure: Error {}
    private var store: [SyncRecordID: SyncRecord] = [:]
    private var versions: [SyncRecordID: Int] = [:]
    private var log: [(seq: Int, id: SyncRecordID, deleted: Bool)] = []
    private var seq = 0
    private var failNext = false
    /// Versions known to direct callers (the server used as a transport without `device(_:)`).
    private var directTags: [String: Int] = [:]

    public init() {}

    public func setFailNext(_ v: Bool) { failNext = v }
    public func records() -> [SyncRecordID: SyncRecord] { store }

    /// A transport for one device that keeps its known versions in that device's `syncMeta` table.
    public nonisolated func device(_ database: AppDatabase) -> InMemorySyncDevice {
        InMemorySyncDevice(server: self, database: database)
    }

    private func checkFailure() throws {
        if failNext { failNext = false; throw Failure() }
    }

    // MARK: server core

    /// Changes after `token`, plus the current version of every changed record.
    func fetch(since token: String?) throws -> (changes: SyncChanges, versions: [String: Int]) {
        try checkFailure()
        let after = token.flatMap(Int.init) ?? 0
        var latest: [SyncRecordID: Bool] = [:]      // id -> deleted?
        var order: [SyncRecordID] = []
        for e in log where e.seq > after {
            if latest[e.id] == nil { order.append(e.id) }
            latest[e.id] = e.deleted
        }
        let changed = order.compactMap { id -> SyncRecord? in latest[id] == false ? store[id] : nil }
        let deleted = order.filter { latest[$0] == true }
        var known: [String: Int] = [:]
        for r in changed { known[r.name] = versions[r.id] }
        return (SyncChanges(changed: changed, deleted: deleted, token: String(seq)), known)
    }

    /// Saves against the versions the caller knows; returns each outcome and, when saved, the new version.
    func save(_ records: [SyncRecord], known: [String: Int]) throws -> [SyncRecordID: (outcome: SyncSaveOutcome, version: Int?)] {
        try checkFailure()
        var out: [SyncRecordID: (outcome: SyncSaveOutcome, version: Int?)] = [:]
        for r in records {
            if log.last(where: { $0.id == r.id })?.deleted == true { out[r.id] = (.notFound, nil); continue }   // do not resurrect
            if let current = versions[r.id], known[r.name] != current { out[r.id] = (.failed("server changed"), nil); continue }
            seq += 1
            store[r.id] = r
            versions[r.id] = seq
            log.append((seq, r.id, false))
            out[r.id] = (.saved, seq)
        }
        return out
    }

    func remove(_ ids: [SyncRecordID]) throws {
        try checkFailure()
        for id in ids where store[id] != nil {
            seq += 1
            store[id] = nil
            versions[id] = nil
            log.append((seq, id, true))
        }
    }

    // MARK: SyncTransport for direct callers

    public func fetchChanges(since token: String?) async throws -> SyncChanges {
        let (changes, known) = try fetch(since: token)
        directTags.merge(known) { $1 }
        for id in changes.deleted { directTags[id.name] = nil }
        return changes
    }

    public func save(_ records: [SyncRecord]) async throws -> [SyncRecordID: SyncSaveOutcome] {
        let result = try save(records, known: directTags)
        for (id, r) in result {
            if let v = r.version { directTags[id.name] = v } else if r.outcome == .notFound { directTags[id.name] = nil }
        }
        return result.mapValues(\.outcome)
    }

    public func delete(_ ids: [SyncRecordID]) async throws {
        try remove(ids)
        for id in ids { directTags[id.name] = nil }
    }
}

/// One device's view of the shared fake server; known versions live in its `syncMeta` table, so clearing that
/// table (a local reset) forgets them exactly as it forgets CloudKit change tags.
public final class InMemorySyncDevice: SyncTransport, @unchecked Sendable {
    let server: InMemorySyncServer
    let database: AppDatabase

    init(server: InMemorySyncServer, database: AppDatabase) {
        self.server = server; self.database = database
    }

    public func fetchChanges(since token: String?) async throws -> SyncChanges {
        let (changes, known) = try await server.fetch(since: token)
        try writeTags(store: known, remove: changes.deleted.map(\.name))
        return changes
    }

    public func save(_ records: [SyncRecord]) async throws -> [SyncRecordID: SyncSaveOutcome] {
        let known = try readTags(records.map(\.name))
        let result = try await server.save(records, known: known)
        var saved: [String: Int] = [:]
        for (id, r) in result { if let v = r.version { saved[id.name] = v } }
        try writeTags(store: saved, remove: result.filter { $0.value.outcome == .notFound }.map(\.key.name))
        return result.mapValues(\.outcome)
    }

    public func delete(_ ids: [SyncRecordID]) async throws {
        try await server.remove(ids)
        try writeTags(store: [:], remove: ids.map(\.name))
    }

    private func readTags(_ names: [String]) throws -> [String: Int] {
        try database.read { db in
            var out: [String: Int] = [:]
            for name in names {
                if let data = try Data.fetchOne(db, sql: "SELECT systemFields FROM syncMeta WHERE recordName = ?", arguments: [name]),
                   let v = Int(String(decoding: data, as: UTF8.self)) {
                    out[name] = v
                }
            }
            return out
        }
    }

    private func writeTags(store: [String: Int], remove: [String]) throws {
        guard !store.isEmpty || !remove.isEmpty else { return }
        try database.write { db in
            for name in remove {
                try db.execute(sql: "DELETE FROM syncMeta WHERE recordName = ?", arguments: [name])
            }
            for (name, v) in store {
                try db.execute(sql: "INSERT OR REPLACE INTO syncMeta (recordName, systemFields) VALUES (?, ?)",
                               arguments: [name, Data(String(v).utf8)])
            }
        }
    }
}
