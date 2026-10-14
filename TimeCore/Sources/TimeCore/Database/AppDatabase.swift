import Foundation
import GRDB

public final class AppDatabase {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
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
        return m
    }
}
