import Foundation
import GRDB

public struct SyncSummary: Equatable, Sendable {
    public var pulled = 0
    public var deleted = 0
    public var pushed = 0
    public var failed = 0
    public init(pulled: Int = 0, deleted: Int = 0, pushed: Int = 0, failed: Int = 0) {
        self.pulled = pulled; self.deleted = deleted; self.pushed = pushed; self.failed = failed
    }
}

/// One cycle: pull remote changes since the stored token, apply them (R3, R4, R8, R9),
/// then push the outbox (R5). Never touches the outbox for remote-applied rows.
public actor SyncEngine {
    public static let tokenKey = "syncZoneToken"
    let db: AppDatabase
    let transport: any SyncTransport
    let now: @Sendable () -> Date

    public init(database: AppDatabase, transport: any SyncTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = database; self.transport = transport; self.now = now
    }

    private var inFlight: Task<SyncSummary, Error>?

    /// Single-flight: a call made while a cycle is running awaits that cycle's result.
    public func sync() async throws -> SyncSummary {
        if let running = inFlight { return try await running.value }
        let task = Task {
            defer { self.inFlight = nil }                    // cleared before the result is delivered
            return try await self.runCycle()
        }
        inFlight = task
        return try await task.value
    }

    private func runCycle() async throws -> SyncSummary {
        var summary = SyncSummary()
        let token = try db.setting(Self.tokenKey)
        let changes = try await transport.fetchChanges(since: token)
        (summary.pulled, summary.deleted) = try apply(changes)
        (summary.pushed, summary.failed) = try await pushOutbox()
        return summary
    }

    // MARK: pull

    public func apply(_ changes: SyncChanges) throws -> (pulled: Int, deleted: Int) {
        let deviceId = db.deviceId
        let now = self.now()
        return try db.write { db in
            var pulled = 0
            let byType = Dictionary(grouping: changes.changed, by: \.type)
            for type in RecordMapper.types {                      // R8: parents first
                for r in byType[type] ?? [] {
                    if try Self.applyRecord(r, in: db) { pulled += 1 }
                }
            }
            var deleted = 0
            for id in changes.deleted {
                guard let table = RecordMapper.table(forType: id.type) else { continue }
                if table == "setting" {
                    try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [id.name])
                } else {
                    try db.execute(sql: "DELETE FROM \(table) WHERE uuid = ?", arguments: [id.name])
                }
                try db.execute(sql: "DELETE FROM outbox WHERE tableName = ? AND uuid = ?", arguments: [table, id.name])
                deleted += 1
            }
            _ = deviceId   // used by Task 4's resolveRunningStints call, added there
            if let token = changes.token {
                try Setting(key: Self.tokenKey, value: token, modifiedAt: now, modifiedBy: deviceId).save(db)
            }
            return (pulled, deleted)
        }
    }

    static func localWins(_ lAt: Date, _ lBy: String, _ rAt: Date, _ rBy: String) -> Bool {
        lAt > rAt || (lAt == rAt && lBy > rBy)
    }

    /// Returns true when the local row changed.
    static func applyRecord(_ r: SyncRecord, in db: Database) throws -> Bool {
        switch r.type {
        case "Client":
            return try upsert(r, in: db, make: { Client(name: "", uuid: r.name) }) { c, _ in RecordMapper.apply(r, to: &c) }
        case "Project":
            return try upsert(r, in: db, make: { Project(clientId: nil, name: "", uuid: r.name) }) { p, db in
                RecordMapper.apply(r, to: &p)
                p.clientId = try resolve(Client.self, uuid: r.string("clientUUID"), in: db)
            }
        case "Repo":
            let owner = r.string("owner") ?? "", name = r.string("name") ?? ""
            return try upsert(r, in: db, make: { Repo(owner: "", name: "", uuid: r.name) },
                              natural: { try Repo.filter(Column("owner") == owner && Column("name") == name && Column("uuid") != r.name).fetchOne(db) }) { x, db in
                RecordMapper.apply(r, to: &x)
                x.projectId = try resolve(Project.self, uuid: r.string("projectUUID"), in: db)
            }
        case "Entry":
            let key = r.string("importedKey")
            return try upsert(r, in: db, make: { Entry(description: "", startUTC: Date(), uuid: r.name) },
                              natural: { try key.flatMap { try Entry.filter(Column("importedKey") == $0 && Column("uuid") != r.name).fetchOne(db) } }) { e, db in
                RecordMapper.apply(r, to: &e)
                e.projectId = try resolve(Project.self, uuid: r.string("projectUUID"), in: db)
                e.repoId = try resolve(Repo.self, uuid: r.string("repoUUID"), in: db)
            }
        case "Setting":
            guard SyncTables.syncedSettings.contains(r.name) else { return false }
            let remoteAt = r.date("modifiedAt") ?? .distantPast
            let remoteBy = r.string("modifiedBy") ?? ""
            if let local = try Setting.fetchOne(db, key: r.name) {
                if local.modifiedAt == remoteAt && local.modifiedBy == remoteBy { return false }
                if localWins(local.modifiedAt, local.modifiedBy, remoteAt, remoteBy) {
                    try requeueIfIdle(db, table: "setting", uuid: r.name, at: local.modifiedAt)
                    return false
                }
            }
            try Setting(key: r.name, value: r.string("value") ?? "", modifiedAt: remoteAt, modifiedBy: remoteBy).save(db)
            return true
        default:
            return false
        }
    }

    private static func upsert<T: SyncableRecord>(_ r: SyncRecord, in db: Database, make: () -> T,
                                                  natural: () throws -> T? = { nil },
                                                  fill: (inout T, Database) throws -> Void) throws -> Bool {
        let remoteAt = r.date("modifiedAt") ?? .distantPast
        let remoteBy = r.string("modifiedBy") ?? ""
        if var local: T = try db.fetchByUUID(uuid: r.name) {
            if local.deletedAt != nil { return false }                                  // R4: pending delete wins
            if local.modifiedAt == remoteAt && local.modifiedBy == remoteBy {                  // R9: already applied
                return try refreshReferences(r, in: db)    // ...except a re-sent row whose parent uuid changed (R16)
            }
            if localWins(local.modifiedAt, local.modifiedBy, remoteAt, remoteBy) {           // R3: ours goes back up
                try requeueIfIdle(db, table: T.databaseTableName, uuid: r.name, at: local.modifiedAt)
                return false
            }
            try fill(&local, db)
            try local.update(db)
            return true
        }
        if let other = try natural() {                                                   // R16
            return try mergeNaturalKey(local: other, remote: r, remoteAt: remoteAt, remoteBy: remoteBy, in: db, fill: fill)
        }
        var row = make()
        try fill(&row, db)
        try row.insert(db)
        return true
    }

    /// R16: two uuids for one natural key collapse into the lexically smaller one.
    private static func mergeNaturalKey<T: SyncableRecord>(local other: T, remote r: SyncRecord, remoteAt: Date, remoteBy: String,
                                                           in db: Database, fill: (inout T, Database) throws -> Void) throws -> Bool {
        let table = T.databaseTableName
        guard r.name < other.uuid else {
            // ours survives: drop the remote duplicate on the server and make sure our version is pushed
            try db.logChange(table: table, uuid: r.name, op: .delete, now: other.modifiedAt)
            try requeueIfIdle(db, table: table, uuid: other.uuid, at: other.modifiedAt)
            return false
        }
        var local = other
        let old = local.uuid
        let remoteWins = local.deletedAt == nil && !localWins(local.modifiedAt, local.modifiedBy, remoteAt, remoteBy)
        local.uuid = r.name                                                              // keeps the local id
        if remoteWins { try fill(&local, db) }
        try local.update(db)
        try db.execute(sql: "DELETE FROM outbox WHERE tableName = ? AND uuid = ?", arguments: [table, old])
        try db.logChange(table: table, uuid: old, op: .delete, now: local.modifiedAt)    // the old server record goes away
        if local is Repo, let repoId = local.id {                                        // children already pushed carry the old repoUUID
            for e in try Entry.filter(Column("repoId") == repoId && Column("deletedAt") == nil).fetchAll(db) {
                try db.logChange(table: "entry", uuid: e.uuid, op: .upsert, now: e.modifiedAt)
            }
        }
        if let deletedAt = local.deletedAt {
            try db.logChange(table: table, uuid: r.name, op: .delete, now: deletedAt)    // our pending deletion carries over
        } else if !remoteWins {
            try requeueIfIdle(db, table: table, uuid: r.name, at: local.modifiedAt)
        }
        return remoteWins
    }

    /// Same stamps, so the fields are identical; only adopt references that now resolve (never null one out).
    private static func refreshReferences(_ r: SyncRecord, in db: Database) throws -> Bool {
        switch r.type {
        case "Entry":
            guard var e: Entry = try db.fetchByUUID(uuid: r.name) else { return false }
            var changed = false
            if let p = try resolve(Project.self, uuid: r.string("projectUUID"), in: db), p != e.projectId { e.projectId = p; changed = true }
            if let x = try resolve(Repo.self, uuid: r.string("repoUUID"), in: db), x != e.repoId { e.repoId = x; changed = true }
            if changed { try e.update(db) }
            return changed
        case "Repo":
            guard var x: Repo = try db.fetchByUUID(uuid: r.name),
                  let p = try resolve(Project.self, uuid: r.string("projectUUID"), in: db), p != x.projectId else { return false }
            x.projectId = p; try x.update(db); return true
        case "Project":
            guard var x: Project = try db.fetchByUUID(uuid: r.name),
                  let c = try resolve(Client.self, uuid: r.string("clientUUID"), in: db), c != x.clientId else { return false }
            x.clientId = c; try x.update(db); return true
        default:
            return false
        }
    }

    private static func requeueIfIdle(_ db: Database, table: String, uuid: String, at: Date) throws {
        let pending = try OutboxItem.filter(Column("tableName") == table && Column("uuid") == uuid).fetchCount(db)
        if pending == 0 { try db.logChange(table: table, uuid: uuid, op: .upsert, now: at) }
    }

    private static func resolve<T: SyncableRecord>(_: T.Type, uuid: String?, in db: Database) throws -> Int64? {
        guard let uuid, let row: T = try db.fetchByUUID(uuid: uuid), row.deletedAt == nil else { return nil }
        return row.id
    }

    // MARK: push

    static func type(forTable table: String) -> String {
        RecordMapper.types.first { RecordMapper.table(forType: $0) == table } ?? table
    }

    /// The current record for an outbox entry, or nil when the row is gone or tombstoned.
    static func record(forTable table: String, uuid: String, in db: Database) throws -> SyncRecord? {
        switch table {
        case "client":
            guard let c: Client = try db.fetchByUUID(uuid: uuid), c.deletedAt == nil else { return nil }
            return RecordMapper.record(client: c)
        case "project":
            guard let p: Project = try db.fetchByUUID(uuid: uuid), p.deletedAt == nil else { return nil }
            let client = try p.clientId.flatMap { try Client.fetchOne(db, key: $0) }
            return RecordMapper.record(project: p, clientUUID: client?.uuid)
        case "repo":
            guard let r: Repo = try db.fetchByUUID(uuid: uuid), r.deletedAt == nil else { return nil }
            let project = try r.projectId.flatMap { try Project.fetchOne(db, key: $0) }
            return RecordMapper.record(repo: r, projectUUID: project?.uuid)
        case "entry":
            guard let e: Entry = try db.fetchByUUID(uuid: uuid), e.deletedAt == nil else { return nil }
            let project = try e.projectId.flatMap { try Project.fetchOne(db, key: $0) }
            let repo = try e.repoId.flatMap { try Repo.fetchOne(db, key: $0) }
            return RecordMapper.record(entry: e, projectUUID: project?.uuid, repoUUID: repo?.uuid)
        case "setting":
            guard let s = try Setting.fetchOne(db, key: uuid) else { return nil }
            return RecordMapper.record(settingKey: s.key, value: s.value, modifiedAt: s.modifiedAt, modifiedBy: s.modifiedBy)
        default:
            return nil
        }
    }

    private static func clearOutbox(_ db: Database, table: String, uuid: String, upTo maxId: Int64) throws {
        try db.execute(sql: "DELETE FROM outbox WHERE tableName = ? AND uuid = ? AND id <= ?", arguments: [table, uuid, maxId])
    }

    public func push() async throws -> Int { try await pushOutbox().pushed }

    func pushOutbox() async throws -> (pushed: Int, failed: Int) {
        let items = try db.pendingOutbox()
        guard let maxId = items.last?.id else { return (0, 0) }
        var latest: [String: OutboxItem] = [:]
        var order: [String] = []
        for i in items {
            let key = "\(i.tableName)|\(i.uuid)"
            if latest[key] == nil { order.append(key) }
            latest[key] = i                                    // the last op for a row wins
        }
        var upserts: [SyncRecord] = []
        var deletes: [SyncRecordID] = []
        var stale: [OutboxItem] = []                           // upsert for a row that no longer exists
        try db.read { db in
            for key in order {
                let i = latest[key]!
                if i.op == SyncOp.delete.rawValue {
                    deletes.append(SyncRecordID(type: Self.type(forTable: i.tableName), name: i.uuid))
                } else if let r = try Self.record(forTable: i.tableName, uuid: i.uuid, in: db) {
                    upserts.append(r)
                } else {
                    stale.append(i)
                }
            }
        }
        var pushed = 0, failed = 0
        if !upserts.isEmpty {
            let outcomes = try await transport.save(upserts)
            try db.write { db in
                for r in upserts {
                    let table = RecordMapper.table(forType: r.type)!
                    switch outcomes[r.id] ?? .failed("no outcome") {
                    case .saved:
                        try Self.clearOutbox(db, table: table, uuid: r.name, upTo: maxId); pushed += 1
                    case .notFound:                                   // R4: deleted elsewhere; never re-create it
                        if table == "setting" { break }               // settings are never deleted: stays queued, retried later
                        try db.execute(sql: "DELETE FROM \(table) WHERE uuid = ?", arguments: [r.name])
                        try Self.clearOutbox(db, table: table, uuid: r.name, upTo: maxId)
                    case .failed:
                        failed += 1                                   // stays queued, retried next cycle
                    }
                }
            }
        }
        if !deletes.isEmpty {
            try await transport.delete(deletes)
            try db.write { db in
                for id in deletes {
                    let table = RecordMapper.table(forType: id.type)!
                    try db.execute(sql: "DELETE FROM \(table) WHERE uuid = ?", arguments: [id.name])   // purge the tombstone
                    try Self.clearOutbox(db, table: table, uuid: id.name, upTo: maxId)
                }
            }
            pushed += deletes.count
        }
        if !stale.isEmpty {
            try db.write { db in
                for i in stale { try Self.clearOutbox(db, table: i.tableName, uuid: i.uuid, upTo: maxId) }
            }
        }
        return (pushed, failed)
    }
}
