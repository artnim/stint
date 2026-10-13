import Foundation

public struct GitHubIssue: Equatable {
    public var repoOwner: String
    public var repoName: String
    public var number: Int
    public var title: String
    public var isPullRequest: Bool
    public var state: String
    public var updatedAt: Date

    public init(repoOwner: String, repoName: String, number: Int, title: String,
                isPullRequest: Bool, state: String, updatedAt: Date) {
        self.repoOwner = repoOwner; self.repoName = repoName; self.number = number
        self.title = title; self.isPullRequest = isPullRequest; self.state = state; self.updatedAt = updatedAt
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

    public func assignedIssues() async throws -> [GitHubIssue] {
        var url: URL? = baseURL.appending(path: "issues")
            .appending(queryItems: [.init(name: "filter", value: "assigned"),
                                    .init(name: "state", value: "open"),
                                    .init(name: "per_page", value: "100")])
        var out: [GitHubIssue] = []
        while let u = url {
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
            out += try Self.decode(data)
            url = Self.nextLink(from: resp.value(forHTTPHeaderField: "Link"))
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

    static func decode(_ data: Data) throws -> [GitHubIssue] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            return try dec.decode([RawIssue].self, from: data).compactMap { r in
                guard let repo = r.repository else { return nil }
                return GitHubIssue(repoOwner: repo.owner.login, repoName: repo.name, number: r.number,
                                   title: r.title, isPullRequest: r.pull_request != nil,
                                   state: r.state, updatedAt: r.updated_at)
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
