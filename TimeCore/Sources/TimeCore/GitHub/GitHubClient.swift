import Foundation

public struct GitHubIssue: Equatable {
    public var repoOwner: String
    public var repoName: String
    public var number: Int
    public var title: String
    public var isPullRequest: Bool
    public var state: String
    public var updatedAt: Date
    public var assignedToMe: Bool

    public init(repoOwner: String, repoName: String, number: Int, title: String,
                isPullRequest: Bool, state: String, updatedAt: Date, assignedToMe: Bool = true) {
        self.repoOwner = repoOwner; self.repoName = repoName; self.number = number
        self.title = title; self.isPullRequest = isPullRequest; self.state = state; self.updatedAt = updatedAt
        self.assignedToMe = assignedToMe
    }
}

public protocol HTTPTransport {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, resp as! HTTPURLResponse)
    }
}

public enum GitHubError: Error, Equatable {
    case unauthorized
    case http(Int)
    case decoding(String)
}

/// Read-only client: everything open that is assigned to the token's user, across all repos.
public struct GitHubClient {
    let token: String
    let transport: any HTTPTransport
    let baseURL: URL

    public init(token: String, transport: any HTTPTransport = URLSessionTransport(),
                baseURL: URL = URL(string: "https://api.github.com")!) {
        self.token = token; self.transport = transport; self.baseURL = baseURL
    }

    /// Issues and PRs assigned to the token's user, across every repo the token can see.
    /// `since` limits to items updated after that instant (GitHub's `since` parameter).
    public func assignedIssues(state: String = "open", since: Date? = nil) async throws -> [GitHubIssue] {
        var items: [URLQueryItem] = [.init(name: "filter", value: "assigned"), .init(name: "state", value: state)]
        if let since { items.append(.init(name: "since", value: Self.iso(since))) }
        items.append(.init(name: "per_page", value: "100"))
        return try await fetchPages(from: baseURL.appending(path: "issues").appending(queryItems: items),
                                    maxPages: Int.max, defaultRepo: nil)
    }

    /// Issues and PRs of one repo (newest first), whether assigned or not, capped at
    /// `maxPages` × 100. Items carry `assignedToMe == false`.
    public func repoIssues(owner: String, name: String, state: String = "open", since: Date? = nil,
                           maxPages: Int = 5) async throws -> [GitHubIssue] {
        var items: [URLQueryItem] = [.init(name: "state", value: state)]
        if let since { items.append(.init(name: "since", value: Self.iso(since))) }
        items.append(.init(name: "per_page", value: "100"))
        return try await fetchPages(from: baseURL.appending(path: "repos/\(owner)/\(name)/issues").appending(queryItems: items),
                                    maxPages: maxPages, defaultRepo: (owner, name))
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func fetchPages(from start: URL, maxPages: Int,
                            defaultRepo: (owner: String, name: String)?) async throws -> [GitHubIssue] {
        var url: URL? = start
        var out: [GitHubIssue] = []
        var pages = 0
        while let u = url, pages < maxPages {
            let (data, resp) = try await transport.get(u, headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            ])
            switch resp.statusCode {
            case 200: break
            case 401: throw GitHubError.unauthorized
            default: throw GitHubError.http(resp.statusCode)
            }
            out += try Self.decode(data, defaultRepo: defaultRepo)
            url = Self.nextLink(from: resp.value(forHTTPHeaderField: "Link"))
            pages += 1
        }
        return out
    }

    private struct RawIssue: Decodable {
        struct PR: Decodable {}
        struct Repository: Decodable {
            struct Owner: Decodable { let login: String }
            let name: String
            let owner: Owner
        }
        let number: Int
        let title: String
        let state: String
        let updated_at: Date
        let pull_request: PR?
        let repository: Repository?
    }

    /// `/issues` items carry their `repository`; `/repos/{o}/{r}/issues` items do not, so the
    /// caller passes the repo. With a `defaultRepo` the items are "not assigned to me".
    static func decode(_ data: Data, defaultRepo: (owner: String, name: String)? = nil) throws -> [GitHubIssue] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            return try dec.decode([RawIssue].self, from: data).compactMap { r in
                let owner = r.repository?.owner.login ?? defaultRepo?.owner
                let name = r.repository?.name ?? defaultRepo?.name
                guard let owner, let name else { return nil }
                return GitHubIssue(repoOwner: owner, repoName: name, number: r.number,
                                   title: r.title, isPullRequest: r.pull_request != nil,
                                   state: r.state, updatedAt: r.updated_at,
                                   assignedToMe: defaultRepo == nil)
            }
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
    }

    /// `<url>; rel="next"` out of a Link header.
    static func nextLink(from header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces[1] == "rel=\"next\"" else { continue }
            let raw = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: raw)
        }
        return nil
    }
}
