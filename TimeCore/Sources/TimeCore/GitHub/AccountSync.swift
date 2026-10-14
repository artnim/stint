import Foundation

public struct GitHubAccountCredential: Sendable {
    public var label: String
    public var token: String
    public init(label: String, token: String) { self.label = label; self.token = token }
}

public struct AccountSyncOutcome: Equatable, Sendable {
    public var rejectedLabels: [String]
    public var failed: Int
    public var applied: Bool
}

/// The issue sync shared by both apps: assigned issues per account, every open and recently
/// closed issue of each tracked repo, merged and applied; closes missing issues only when
/// everything succeeded.
public enum AccountSync {
    public static func run(accounts: [GitHubAccountCredential], db: AppDatabase, closedSince: Date,
                           makeClient: (String) -> GitHubClient = { GitHubClient(token: $0) }) async -> AccountSyncOutcome {
        var assigned: [GitHubIssue] = []
        var rejected: [String] = []
        var failed = 0
        for account in accounts {
            do {
                let client = makeClient(account.token)
                assigned += try await client.assignedIssues()
                assigned += try await client.assignedIssues(state: "closed", since: closedSince)
            } catch GitHubError.unauthorized {
                rejected.append(account.label); failed += 1
            } catch {
                failed += 1   // offline or rate-limited: keep the cache, stay quiet (spec §3)
            }
        }
        let usable = accounts.filter { !rejected.contains($0.label) }
        var listed: [GitHubIssue] = []
        for repo in (try? db.allRepos()) ?? [] {
            var fetched = false
            for account in usable {
                do {
                    let client = makeClient(account.token)
                    listed += try await client.repoIssues(owner: repo.owner, name: repo.name)
                    listed += try await client.repoIssues(owner: repo.owner, name: repo.name, state: "closed", since: closedSince, maxPages: 2)
                    fetched = true
                    break
                } catch GitHubError.http(let code) where code == 403 || code == 404 {
                    continue   // this token cannot see the repo; try the next account
                } catch {
                    break      // unauthorized, offline, rate-limited: do not hammer the API
                }
            }
            if !fetched { failed += 1 }
        }
        let merged = IssueSync.merge(assigned: assigned, repoIssues: listed)
        var applied = false
        if !merged.isEmpty || failed == 0 {
            applied = (try? IssueSync.apply(merged, to: db, closeMissing: failed == 0)) != nil
        }
        return AccountSyncOutcome(rejectedLabels: rejected, failed: failed, applied: applied)
    }
}
