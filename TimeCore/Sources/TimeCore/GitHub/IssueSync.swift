import Foundation
import GRDB

public enum IssueSync {
    /// Upsert repos (keeping their project mapping) and cache rows. With `closeMissing`, every open
    /// cached issue not in `issues` is marked closed; pass `false` when `issues` is incomplete
    /// (for example when one of several accounts failed to sync).
    public static func apply(_ issues: [GitHubIssue], to db: AppDatabase, closeMissing: Bool = true) throws {
        try db.write { db in
            var repoIds: [String: Int64] = [:]
            for r in try Repo.fetchAll(db) { repoIds[r.fullName] = r.id }
            var seen = Set<String>()   // "repoId/number"
            for i in issues {
                let full = "\(i.repoOwner)/\(i.repoName)"
                let repoId: Int64
                if let id = repoIds[full] { repoId = id } else {
                    var r = Repo(owner: i.repoOwner, name: i.repoName)
                    try r.insert(db)
                    repoId = r.id!
                    repoIds[full] = repoId
                }
                seen.insert("\(repoId)/\(i.number)")
                if var row = try IssueCache.filter(Column("repoId") == repoId && Column("number") == i.number).fetchOne(db) {
                    row.title = i.title; row.state = i.state; row.isPullRequest = i.isPullRequest; row.updatedAt = i.updatedAt
                    try row.update(db)
                } else {
                    var row = IssueCache(repoId: repoId, number: i.number, title: i.title,
                                         isPullRequest: i.isPullRequest, state: i.state, updatedAt: i.updatedAt)
                    try row.insert(db)
                }
            }
            guard closeMissing else { return }
            for var row in try IssueCache.filter(Column("state") == "open").fetchAll(db)
            where !seen.contains("\(row.repoId)/\(row.number)") {
                row.state = "closed"
                try row.update(db)
            }
        }
    }
}
