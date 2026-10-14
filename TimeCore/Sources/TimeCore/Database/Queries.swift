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
        try read { try Entry.filter(Column("endUTC") == nil).filter(Column("deletedAt") == nil).fetchOne($0) }
    }

    /// Stops a running entry (at `now`) and starts a new one.
    @discardableResult
    public func start(description: String, projectId: Int64?, repoId: Int64? = nil,
                      issueNumber: Int? = nil, issueTitle: String? = nil,
                      tags: [String] = [], at now: Date = Date()) throws -> Entry {
        try write { db in
            if var running = try Entry.filter(Column("endUTC") == nil).filter(Column("deletedAt") == nil).fetchOne(db) {
                running.endUTC = now
                try db.syncUpdate(&running, deviceId: deviceId, now: now)
            }
            var e = Entry(projectId: projectId, description: description, startUTC: now,
                          repoId: repoId, issueNumber: issueNumber, issueTitle: issueTitle, tags: tags)
            try db.syncInsert(&e, deviceId: deviceId, now: now)
            return e
        }
    }

    @discardableResult
    public func stopRunning(at now: Date = Date()) throws -> Entry? {
        try write { db in
            guard var running = try Entry.filter(Column("endUTC") == nil).filter(Column("deletedAt") == nil).fetchOne(db) else { return nil }
            running.endUTC = now
            try db.syncUpdate(&running, deviceId: deviceId, now: now)
            return running
        }
    }

    /// Finished entries with `from <= startUTC < to`, oldest first.
    public func finishedEntries(from: Date, to: Date) throws -> [Entry] {
        try read { db in
            try Entry.filter(Column("endUTC") != nil && Column("deletedAt") == nil)
                .filter(Column("startUTC") >= from && Column("startUTC") < to)
                .order(Column("startUTC"))
                .fetchAll(db)
        }
    }

    /// All entries, running included, with `from <= startUTC < to`, oldest first.
    public func entries(from: Date, to: Date) throws -> [Entry] {
        try read { db in
            try Entry.filter(Column("deletedAt") == nil)
                .filter(Column("startUTC") >= from && Column("startUTC") < to)
                .order(Column("startUTC"))
                .fetchAll(db)
        }
    }

    /// Plain records (issueCache, outbox): no stamps, no log.
    public func insert<T: MutablePersistableRecord>(_ record: inout T) throws { try write { try record.insert($0) } }
    public func update<T: MutablePersistableRecord>(_ record: T) throws { try write { try record.update($0) } }
    public func delete<T: MutablePersistableRecord>(_ record: T) throws { try write { _ = try record.delete($0) } }

    /// Synced records: stamp with this device and log into the outbox (R1, R5); delete = tombstone (R4).
    public func insert<T: SyncableRecord>(_ record: inout T) throws {
        var r = record
        try write { try $0.syncInsert(&r, deviceId: deviceId, now: Date()) }
        record = r
    }
    public func update<T: SyncableRecord>(_ record: T) throws {
        var r = record
        try write { try $0.syncUpdate(&r, deviceId: deviceId, now: Date()) }
    }
    public func delete<T: SyncableRecord>(_ record: T) throws {
        var r = record
        try write { try $0.syncTombstone(&r, deviceId: deviceId, now: Date()) }
    }

    public func purge(table: String, uuid: String) throws {
        try write { try $0.execute(sql: "DELETE FROM \(table) WHERE uuid = ?", arguments: [uuid]) }
    }

    public func pendingOutbox() throws -> [OutboxItem] {
        try read { try OutboxItem.order(Column("id")).fetchAll($0) }
    }

    public func recents(limit: Int = 10) throws -> [RecentItem] {
        try read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT description, projectId, repoId, issueNumber, issueTitle, MAX(startUTC) AS last
                FROM entry WHERE endUTC IS NOT NULL AND deletedAt IS NULL
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
        try read { try Client.filter(Column("deletedAt") == nil).order(Column("name")).fetchAll($0) }
    }

    public func allProjects() throws -> [Project] {
        try read { try Project.filter(Column("deletedAt") == nil).order(Column("name")).fetchAll($0) }
    }

    public func allRepos() throws -> [Repo] {
        try read { try Repo.filter(Column("deletedAt") == nil).order(Column("owner"), Column("name")).fetchAll($0) }
    }

    public func setting(_ key: String) throws -> String? {
        try read { try Setting.fetchOne($0, key: key)?.value }
    }

    public func setSetting(_ key: String, _ value: String) throws {
        let now = Date()
        try write { db in
            let s = Setting(key: key, value: value, modifiedAt: now, modifiedBy: deviceId)
            try s.save(db)
            if SyncTables.syncedSettings.contains(key) { try db.logChange(table: "setting", uuid: key, op: .upsert, now: now) }
        }
    }
}

public struct ReportFilter: Equatable {
    public var clientId: Int64?
    public var projectId: Int64?
    public init(clientId: Int64? = nil, projectId: Int64? = nil) {
        self.clientId = clientId; self.projectId = projectId
    }
}

extension AppDatabase {
    /// Finished entries in [from, to) as report lines with project/client names resolved.
    public func reportEntries(from: Date, to: Date, filter: ReportFilter = ReportFilter(),
                              userName: String) throws -> [ReportEntry] {
        let entries = try finishedEntries(from: from, to: to)
        let projects = Dictionary(uniqueKeysWithValues: try allProjects().map { ($0.id!, $0) })
        let clients = Dictionary(uniqueKeysWithValues: try allClients().map { ($0.id!, $0) })
        return entries.compactMap { e in
            let project = e.projectId.flatMap { projects[$0] }
            let client = project?.clientId.flatMap { clients[$0] }
            if let pid = filter.projectId, e.projectId != pid { return nil }
            if let cid = filter.clientId, project?.clientId != cid { return nil }
            return ReportEntry(description: e.description, project: project?.name ?? "",
                               client: client?.name ?? "", user: userName,
                               start: e.startUTC, end: e.endUTC!, tags: e.tags)
        }
    }
}

public struct IssueRow: Equatable, Identifiable {
    public var issue: IssueCache
    public var repo: Repo
    public var projectName: String?
    public var id: Int64 { issue.id! }
}

extension AppDatabase {
    /// Open cached issues, mapped repos first (by project name), then unmapped; within a group by repo name and number.
    public func openIssueRows(assignedOnly: Bool = true) throws -> [IssueRow] {
        var request = IssueCache.filter(Column("state") == "open")
        if assignedOnly { request = request.filter(Column("assignedToMe") == true) }
        return try issueRows(request)
    }

    /// Everything the popover search covers: all open issues plus those closed (updated) after `closedSince`.
    /// Within a project and repo, open issues come before closed ones.
    public func searchIssueRows(closedSince: Date) throws -> [IssueRow] {
        try issueRows(IssueCache.filter(Column("state") == "open" || Column("updatedAt") >= closedSince))
    }

    private func issueRows(_ request: QueryInterfaceRequest<IssueCache>) throws -> [IssueRow] {
        try read { db in
            let repos = Dictionary(uniqueKeysWithValues: try Repo.filter(Column("deletedAt") == nil).fetchAll(db).map { ($0.id!, $0) })
            let projects = Dictionary(uniqueKeysWithValues: try Project.filter(Column("deletedAt") == nil).fetchAll(db).map { ($0.id!, $0) })
            let rows = try request.fetchAll(db).compactMap { i -> IssueRow? in
                guard let repo = repos[i.repoId] else { return nil }
                return IssueRow(issue: i, repo: repo, projectName: repo.projectId.flatMap { projects[$0]?.name })
            }
            return rows.sorted {
                let a = ($0.projectName == nil ? 1 : 0, $0.projectName ?? "", $0.repo.fullName, $0.issue.state == "closed" ? 1 : 0, $0.issue.number)
                let b = ($1.projectName == nil ? 1 : 0, $1.projectName ?? "", $1.repo.fullName, $1.issue.state == "closed" ? 1 : 0, $1.issue.number)
                return a < b
            }
        }
    }

    public enum RepoError: Error, Equatable { case invalidName(String), duplicate(String) }

    /// Tracks a repository by "owner/name" so its open issues are synced even before anything is assigned.
    @discardableResult
    public func addRepo(fullName: String) throws -> Repo {
        let parts = fullName.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw RepoError.invalidName(fullName) }
        let (owner, name) = (String(parts[0]), String(parts[1]))
        return try write { db in
            if var existing = try Repo.filter(Column("owner") == owner && Column("name") == name).fetchOne(db) {
                guard existing.deletedAt != nil else { throw RepoError.duplicate("\(owner)/\(name)") }
                existing.deletedAt = nil
                try db.syncUpdate(&existing, deviceId: deviceId, now: Date())
                return existing
            }
            var r = Repo(owner: owner, name: name)
            try db.syncInsert(&r, deviceId: deviceId, now: Date())
            return r
        }
    }

    public func assignRepo(_ repoId: Int64, toProject projectId: Int64?) throws {
        try write { db in
            guard var repo = try Repo.fetchOne(db, key: repoId) else { return }
            repo.projectId = projectId
            let now = Date()
            try db.syncUpdate(&repo, deviceId: deviceId, now: now)
            if let projectId {
                let orphans = try Entry.filter(Column("repoId") == repoId && Column("projectId") == nil && Column("deletedAt") == nil).fetchAll(db)
                for var e in orphans {
                    e.projectId = projectId
                    try db.syncUpdate(&e, deviceId: deviceId, now: now)
                }
            }
        }
    }
}
