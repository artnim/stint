import Foundation
import GRDB

public protocol SyncableRecord: FetchableRecord, MutablePersistableRecord {
    static var databaseTableName: String { get }
    var id: Int64? { get }
    var uuid: String { get set }
    var modifiedAt: Date { get set }
    var modifiedBy: String { get set }
    var deletedAt: Date? { get set }
}

public enum SyncOp: String, Codable { case upsert, delete }

public enum SyncTables {
    public static let synced = ["client", "project", "repo", "entry"]
    public static let syncedSettings: Set<String> = ["userName", "reportPresets"]
}

/// One pending change (R5). Drained by the sync engine after the server acknowledges it.
public struct OutboxItem: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "outbox"
    public var id: Int64?
    public var tableName: String
    public var uuid: String
    public var op: String
    public var createdAt: Date
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Database {
    public func logChange(table: String, uuid: String, op: SyncOp, now: Date) throws {
        var item = OutboxItem(tableName: table, uuid: uuid, op: op.rawValue, createdAt: now)
        try item.insert(self)
    }

    public func fetchByUUID<T: SyncableRecord>(uuid: String) throws -> T? {
        try T.filter(Column("uuid") == uuid).fetchOne(self)
    }

    public func syncInsert<T: SyncableRecord>(_ r: inout T, deviceId: String, now: Date) throws {
        r.modifiedAt = now; r.modifiedBy = deviceId; r.deletedAt = nil
        try r.insert(self)
        try logChange(table: T.databaseTableName, uuid: r.uuid, op: .upsert, now: now)
    }

    public func syncUpdate<T: SyncableRecord>(_ r: inout T, deviceId: String, now: Date) throws {
        r.modifiedAt = now; r.modifiedBy = deviceId
        try r.update(self)
        try logChange(table: T.databaseTableName, uuid: r.uuid, op: .upsert, now: now)
    }

    /// R4: a local delete becomes a tombstone until the deletion is pushed.
    public func syncTombstone<T: SyncableRecord>(_ r: inout T, deviceId: String, now: Date) throws {
        r.modifiedAt = now; r.modifiedBy = deviceId; r.deletedAt = now
        try r.update(self)
        try logChange(table: T.databaseTableName, uuid: r.uuid, op: .delete, now: now)
    }
}
