import Foundation
import GRDB

extension AppDatabase {
    /// R18 writer: the open issues assigned to me, ordered by repo then number, as one synced row,
    /// stamped and logged only when the payload changed.
    public func writeAssignedIssueSnapshot(now: Date = Date()) throws {
        try write { db in
            let repos = Dictionary(uniqueKeysWithValues: try Repo.filter(Column("deletedAt") == nil).fetchAll(db).map { ($0.id!, $0) })
            let projects = Dictionary(uniqueKeysWithValues: try Project.filter(Column("deletedAt") == nil).fetchAll(db).map { ($0.id!, $0.uuid) })
            let items = try IssueCache.filter(Column("state") == "open" && Column("assignedToMe") == true).fetchAll(db)
                .compactMap { i -> AssignedIssueItem? in
                    guard let repo = repos[i.repoId] else { return nil }
                    return AssignedIssueItem(repo: repo.fullName, number: i.number, title: i.title,
                                             project: repo.projectId.flatMap { projects[$0] },
                                             pr: i.isPullRequest ? true : nil)
                }
                .sorted { ($0.repo, $0.number) < ($1.repo, $1.number) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = String(decoding: try encoder.encode(items), as: UTF8.self)
            if var row: AssignedIssues = try db.fetchByUUID(uuid: AssignedIssues.fixedUUID) {
                if row.deletedAt == nil, row.payload == payload { return }    // unchanged: no stamp, no outbox row
                row.fetchedAt = now; row.payload = payload; row.deletedAt = nil
                try db.syncUpdate(&row, deviceId: deviceId, now: now)
            } else {
                var row = AssignedIssues(fetchedAt: now, payload: payload)
                try db.syncInsert(&row, deviceId: deviceId, now: now)
            }
        }
    }

    /// R18 reader (watch only): replaces the issue cache with the snapshot. Repos are resolved by full name;
    /// an unknown repo skips its issues until the repo arrives. Returns the number of cached issues, or -1
    /// when there is no row or the payload does not parse (the cache is then left untouched).
    @discardableResult
    public func applyAssignedIssueSnapshot() throws -> Int {
        try write { db in
            guard let row: AssignedIssues = try db.fetchByUUID(uuid: AssignedIssues.fixedUUID),
                  let items = try? JSONDecoder().decode([AssignedIssueItem].self, from: Data(row.payload.utf8)) else { return -1 }
            let repos = Dictionary(uniqueKeysWithValues: try Repo.filter(Column("deletedAt") == nil).fetchAll(db).map { ($0.fullName, $0.id!) })
            try db.execute(sql: "DELETE FROM issueCache")
            var count = 0
            for item in items {
                guard let repoId = repos[item.repo] else { continue }
                var cached = IssueCache(repoId: repoId, number: item.number, title: item.title,
                                        isPullRequest: item.pr ?? false, state: "open", updatedAt: row.fetchedAt, assignedToMe: true)
                try cached.insert(db)
                count += 1
            }
            return count
        }
    }
}
