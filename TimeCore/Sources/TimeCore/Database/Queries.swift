import Foundation
import GRDB

public struct RecentItem: Equatable, Hashable {
    public var description: String
    public var projectId: Int64?
    public var repoId: Int64?
    public var issueNumber: Int?
    public var issueTitle: String?
}

extension AppDatabase {
    public func runningEntry() throws -> Entry? {
        try read { try Entry.filter(Column("endUTC") == nil).fetchOne($0) }
    }

    /// Stops a running entry (at `now`) and starts a new one.
    @discardableResult
    public func start(description: String, projectId: Int64?, repoId: Int64? = nil,
                      issueNumber: Int? = nil, issueTitle: String? = nil,
                      tags: [String] = [], at now: Date = Date()) throws -> Entry {
        try write { db in
            if var running = try Entry.filter(Column("endUTC") == nil).fetchOne(db) {
                running.endUTC = now
                try running.update(db)
            }
            var e = Entry(projectId: projectId, description: description, startUTC: now,
                          repoId: repoId, issueNumber: issueNumber, issueTitle: issueTitle, tags: tags)
            try e.insert(db)
            return e
        }
    }

    @discardableResult
    public func stopRunning(at now: Date = Date()) throws -> Entry? {
        try write { db in
            guard var running = try Entry.filter(Column("endUTC") == nil).fetchOne(db) else { return nil }
            running.endUTC = now
            try running.update(db)
            return running
        }
    }

    /// Finished entries with `from <= startUTC < to`, oldest first.
    public func finishedEntries(from: Date, to: Date) throws -> [Entry] {
        try read { db in
            try Entry.filter(Column("endUTC") != nil)
                .filter(Column("startUTC") >= from && Column("startUTC") < to)
                .order(Column("startUTC"))
                .fetchAll(db)
        }
    }

    /// All entries, running included, with `from <= startUTC < to`, oldest first.
    public func entries(from: Date, to: Date) throws -> [Entry] {
        try read { db in
            try Entry.filter(Column("startUTC") >= from && Column("startUTC") < to)
                .order(Column("startUTC"))
                .fetchAll(db)
        }
    }

    public func insert<T: MutablePersistableRecord>(_ record: inout T) throws {
        try write { try record.insert($0) }
    }

    public func update<T: MutablePersistableRecord>(_ record: T) throws {
        try write { try record.update($0) }
    }

    public func delete<T: MutablePersistableRecord>(_ record: T) throws {
        try write { _ = try record.delete($0) }
    }

    public func recents(limit: Int = 10) throws -> [RecentItem] {
        try read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT description, projectId, repoId, issueNumber, issueTitle, MAX(startUTC) AS last
                FROM entry WHERE endUTC IS NOT NULL
                GROUP BY description, projectId
                ORDER BY last DESC LIMIT ?
                """, arguments: [limit])
            return rows.map {
                RecentItem(description: $0["description"], projectId: $0["projectId"],
                           repoId: $0["repoId"], issueNumber: $0["issueNumber"],
                           issueTitle: $0["issueTitle"])
            }
        }
    }

    public func allClients() throws -> [Client] {
        try read { try Client.order(Column("name")).fetchAll($0) }
    }

    public func allProjects() throws -> [Project] {
        try read { try Project.order(Column("name")).fetchAll($0) }
    }

    public func allRepos() throws -> [Repo] {
        try read { try Repo.order(Column("owner"), Column("name")).fetchAll($0) }
    }

    public func setting(_ key: String) throws -> String? {
        try read { try Setting.fetchOne($0, key: key)?.value }
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try write { try Setting(key: key, value: value).save($0) }
    }
}
