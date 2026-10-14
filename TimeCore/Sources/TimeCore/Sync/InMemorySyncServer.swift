import Foundation

/// A fake server shared by the "devices" in tests: a record store plus a change log with
/// sequence numbers; the token is the last sequence number a client has seen.
public actor InMemorySyncServer: SyncTransport {
    public struct Failure: Error {}
    private var store: [SyncRecordID: SyncRecord] = [:]
    private var log: [(seq: Int, id: SyncRecordID, deleted: Bool)] = []
    private var seq = 0
    private var failNext = false

    public init() {}

    public func setFailNext(_ v: Bool) { failNext = v }
    public func records() -> [SyncRecordID: SyncRecord] { store }

    private func checkFailure() throws {
        if failNext { failNext = false; throw Failure() }
    }

    public func fetchChanges(since token: String?) async throws -> SyncChanges {
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
        return SyncChanges(changed: changed, deleted: deleted, token: String(seq))
    }

    public func save(_ records: [SyncRecord]) async throws -> [SyncRecordID: SyncSaveOutcome] {
        try checkFailure()
        var out: [SyncRecordID: SyncSaveOutcome] = [:]
        for r in records {
            seq += 1
            store[r.id] = r
            log.append((seq, r.id, false))
            out[r.id] = .saved
        }
        return out
    }

    public func delete(_ ids: [SyncRecordID]) async throws {
        try checkFailure()
        for id in ids where store[id] != nil {
            seq += 1
            store[id] = nil
            log.append((seq, id, true))
        }
    }
}
