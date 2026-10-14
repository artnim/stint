import XCTest
@testable import TimeCore

struct FakeTransport: HTTPTransport {
    var responses: [String: (status: Int, body: Data, headers: [String: String])]
    var seenHeaders: (([String: String]) -> Void)? = nil

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        seenHeaders?(headers)
        guard let r = responses[url.absoluteString] else {
            throw GitHubError.http(404)
        }
        return (r.body, HTTPURLResponse(url: url, statusCode: r.status, httpVersion: nil, headerFields: r.headers)!)
    }
}

final class GitHubClientTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func testFollowsLinkPaginationAndDecodes() async throws {
        let base = "https://api.github.com/issues?filter=assigned&state=open&per_page=100"
        let page2 = "https://api.github.com/issues?filter=assigned&state=open&per_page=100&page=2"
        var sent: [String: String] = [:]
        let transport = FakeTransport(responses: [
            base: (200, try fixture("github-issues-page1"), ["Link": "<\(page2)>; rel=\"next\", <\(base)>; rel=\"first\""]),
            page2: (200, try fixture("github-issues-page2"), [:]),
        ], seenHeaders: { sent = $0 })
        let issues = try await GitHubClient(token: "tok", transport: transport).assignedIssues()
        XCTAssertEqual(issues.map(\.number), [101, 42, 7])
        XCTAssertEqual(issues[1].isPullRequest, true)
        XCTAssertEqual(issues[0].isPullRequest, false)
        XCTAssertEqual(issues[2].repoOwner, "artnim")
        XCTAssertEqual(issues[2].repoName, "app")
        XCTAssertEqual(issues[0].updatedAt, Date(timeIntervalSince1970: 1_791_619_200))
        XCTAssertEqual(sent["Authorization"], "Bearer tok")
        XCTAssertEqual(sent["X-GitHub-Api-Version"], "2022-11-28")
    }

    func testUnauthorized() async {
        let base = "https://api.github.com/issues?filter=assigned&state=open&per_page=100"
        let transport = FakeTransport(responses: [base: (401, Data("{}".utf8), [:])])
        do {
            _ = try await GitHubClient(token: "bad", transport: transport).assignedIssues()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GitHubError, .unauthorized)
        }
    }

    func testRepoIssuesFillsRepoFromArgumentsAndPaginates() async throws {
        let base = "https://api.github.com/repos/artnim/app/issues?state=open&per_page=100"
        let page2 = "https://api.github.com/repos/artnim/app/issues?state=open&per_page=100&page=2"
        let transport = FakeTransport(responses: [
            base: (200, try fixture("github-repo-issues"), ["Link": "<\(page2)>; rel=\"next\""]),
            page2: (200, try fixture("github-issues-page2"), [:]),
        ])
        let issues = try await GitHubClient(token: "tok", transport: transport).repoIssues(owner: "artnim", name: "app")
        XCTAssertEqual(issues.map(\.number), [200, 201, 7])
        XCTAssertEqual(issues.map(\.repoOwner), ["artnim", "artnim", "artnim"])
        XCTAssertEqual(issues.map(\.repoName), ["app", "app", "app"])
        XCTAssertEqual(issues[1].isPullRequest, true)
        XCTAssertEqual(issues.map(\.assignedToMe), [false, false, false])
    }

    func testRepoIssuesStopsAtMaxPages() async throws {
        let base = "https://api.github.com/repos/artnim/app/issues?state=open&per_page=100"
        let page2 = "https://api.github.com/repos/artnim/app/issues?state=open&per_page=100&page=2"
        let transport = FakeTransport(responses: [
            base: (200, try fixture("github-repo-issues"), ["Link": "<\(page2)>; rel=\"next\""]),
            page2: (200, try fixture("github-repo-issues"), ["Link": "<\(base)>; rel=\"next\""]),
        ])
        let issues = try await GitHubClient(token: "tok", transport: transport).repoIssues(owner: "artnim", name: "app", maxPages: 2)
        XCTAssertEqual(issues.count, 4)
    }

    func testRepoIssuesHTTPError() async {
        let base = "https://api.github.com/repos/artnim/app/issues?state=open&per_page=100"
        let transport = FakeTransport(responses: [base: (404, Data("{}".utf8), [:])])
        do {
            _ = try await GitHubClient(token: "tok", transport: transport).repoIssues(owner: "artnim", name: "app")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GitHubError, .http(404))
        }
    }

    func testNextLinkParsing() {
        XCTAssertEqual(GitHubClient.nextLink(from: "<https://x/a?page=2>; rel=\"next\", <https://x/a?page=9>; rel=\"last\"")?.absoluteString, "https://x/a?page=2")
        XCTAssertNil(GitHubClient.nextLink(from: "<https://x/a?page=1>; rel=\"prev\""))
        XCTAssertNil(GitHubClient.nextLink(from: nil))
    }
}
