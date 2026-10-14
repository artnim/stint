import Foundation
import GRDB

public final class AppDatabase {
    public let writer: any DatabaseWriter

    public let deviceId: String

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
        self.deviceId = try writer.read { try Setting.fetchOne($0, key: "deviceId")?.value } ?? ""
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        return try AppDatabase(DatabaseQueue(path: url.path))
    }

    /// Writes a consistent copy of the live database to `url` (VACUUM INTO).
    public func backup(to url: URL) throws {
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
    }

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.read(block)
    }

    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "client") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("archived", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "project") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("client", onDelete: .setNull)
                t.column("name", .text).notNull()
                t.column("archived", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "repo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .setNull)
                t.column("owner", .text).notNull()
                t.column("name", .text).notNull()
                t.uniqueKey(["owner", "name"])
            }
            try db.create(table: "entry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("project", onDelete: .setNull)
                t.column("startUTC", .datetime).notNull()
                t.column("endUTC", .datetime)
                t.column("description", .text).notNull().defaults(to: "")
                t.belongsTo("repo", onDelete: .setNull)
                t.column("issueNumber", .integer)
                t.column("issueTitle", .text)
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.column("importedKey", .text)
            }
            try db.execute(sql: "CREATE INDEX entry_start ON entry(startUTC)")
            try db.execute(sql: "CREATE UNIQUE INDEX entry_imported ON entry(importedKey) WHERE importedKey IS NOT NULL")
            // at most one running entry: index a constant over the rows whose end is NULL
            try db.execute(sql: "CREATE UNIQUE INDEX entry_one_running ON entry((endUTC IS NULL)) WHERE endUTC IS NULL")
            try db.create(table: "issueCache") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("repo", onDelete: .cascade).notNull()
                t.column("number", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("isPullRequest", .boolean).notNull()
                t.column("state", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["repoId", "number"])
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        m.registerMigration("v2-issue-assigned") { db in
            // issues of tracked repos that are not assigned to the user, for search
            try db.alter(table: "issueCache") { t in
                t.add(column: "assignedToMe", .boolean).notNull().defaults(to: true)
            }
        }
        m.registerMigration("v3-sync") { db in
            let now = Date()
            let deviceId = UUID().uuidString
            try db.create(table: "outbox") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tableName", .text).notNull()
                t.column("uuid", .text).notNull()
                t.column("op", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.alter(table: "setting") { t in
                t.add(column: "modifiedAt", .datetime).notNull().defaults(to: now)
                t.add(column: "modifiedBy", .text).notNull().defaults(to: deviceId)
            }
            try Setting(key: "deviceId", value: deviceId, modifiedAt: now, modifiedBy: deviceId).insert(db)
            for table in SyncTables.synced {
                try db.alter(table: table) { t in
                    t.add(column: "uuid", .text).notNull().defaults(to: "")
                    t.add(column: "modifiedAt", .datetime).notNull().defaults(to: now)
                    t.add(column: "modifiedBy", .text).notNull().defaults(to: deviceId)
                    t.add(column: "deletedAt", .datetime)
                }
                for id in try Int64.fetchAll(db, sql: "SELECT id FROM \(table)") {
                    try db.execute(sql: "UPDATE \(table) SET uuid = ? WHERE id = ?", arguments: [UUID().uuidString, id])
                }
                try db.execute(sql: "CREATE UNIQUE INDEX \(table)_uuid ON \(table)(uuid)")
                // R12: the first cycle uploads everything that already exists
                try db.execute(sql: "INSERT INTO outbox (tableName, uuid, op, createdAt) SELECT ?, uuid, 'upsert', ? FROM \(table)",
                               arguments: [table, now])
            }
            for key in SyncTables.syncedSettings {
                try db.execute(sql: "INSERT INTO outbox (tableName, uuid, op, createdAt) SELECT 'setting', key, 'upsert', ? FROM setting WHERE key = ?",
                               arguments: [now, key])
            }
            // The one-running-entry invariant is now cross-device and enforced by R7 after every
            // merge; a remote running stint must be storable alongside a local one until then.
            try db.drop(index: "entry_one_running")
        }
        return m
    }
}
