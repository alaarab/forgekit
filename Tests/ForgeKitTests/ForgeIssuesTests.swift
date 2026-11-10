import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ForgeKit

/// Issues over both forges: one screen's shapes out of two JSON vocabularies,
/// including the places they disagree (gitboy's "#colour", event rows in the
/// comment stream, GitHub listing pull requests as issues).
final class ForgeIssuesTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func gitboyRepo() -> ForgeRepo {
        ForgeRepo(host: .testGitboy, owner: "octo", name: "app", description: nil,
                  isPrivate: false, defaultBranch: "main", isArchived: false,
                  updatedAt: nil,
                  webURL: URL(string: "https://gitboy.example.com/octo/app")!)
    }

    private func githubRepo() -> ForgeRepo {
        ForgeRepo(host: .github, owner: "octo", name: "app", description: nil,
                  isPrivate: false, defaultBranch: "main", isArchived: false,
                  updatedAt: nil,
                  webURL: URL(string: "https://github.com/octo/app")!)
    }

    private func makeGitboy() -> GitboyClient {
        GitboyClient(host: .testGitboy, token: "test-token", session: StubURLProtocol.session())
    }

    private func makeGitHub() -> GitHubForge {
        GitHubForge(client: GitHubHTTPTransport(session: StubURLProtocol.session(), token: "test-token"))
    }

    private func gitboyIssue(number: Int) -> ForgeIssue {
        ForgeIssue(repo: gitboyRepo(), number: number, title: "Crash on launch", author: "octo",
                   state: .open, labels: [], assignees: [], comments: 0, updatedAt: nil,
                   webURL: URL(string: "https://gitboy.example.com/octo/app/issues/\(number)")!)
    }

    private func githubIssue(number: Int) -> ForgeIssue {
        ForgeIssue(repo: githubRepo(), number: number, title: "Crash on launch", author: "octo",
                   state: .open, labels: [], assignees: [], comments: 0, updatedAt: nil,
                   webURL: URL(string: "https://github.com/octo/app/issues/\(number)")!)
    }

    private func queryItems(in url: String) throws -> [URLQueryItem] {
        try XCTUnwrap(URLComponents(string: url)).queryItems ?? []
    }
}

// MARK: - gitboy

extension ForgeIssuesTests {
    func testGitboyListPagesStripsTheLabelHashAndSendsTheQuery() async throws {
        StubURLProtocol.stub("repos/octo/app/issues", status: 200, body: """
        {"items":[
          {"index":12,"title":"Crash on launch","state":"open","author_username":"octo",
           "labels":[{"name":"bug","color":"#d73a4a"},{"name":"ui","color":"7ba95b"}],
           "assignees":[{"username":"ada"}],"comment_count":3,
           "updated_at":"2026-11-03T10:00:00Z"},
          {"index":11,"title":"Old idea","state":"closed","author_username":"ada",
           "labels":[],"assignees":[],"comment_count":0,
           "updated_at":null,"created_at":"2026-02-02T00:00:00Z"}
        ],"next_cursor":"cursor-2"}
        """)

        let page = try await makeGitboy().issues(in: gitboyRepo(), state: .open,
                                                 query: "crash", cursor: "cursor-1")

        XCTAssertEqual(page.next, "cursor-2")
        XCTAssertEqual(page.items.map(\.number), [12, 11])
        XCTAssertEqual(page.items.map(\.state), [.open, .closed])
        XCTAssertEqual(page.items[0].id, "gitboy:gitboy.example.com/octo/app#12")
        XCTAssertEqual(page.items[0].author, "octo")
        XCTAssertEqual(page.items[0].labels.map(\.name), ["bug", "ui"])
        XCTAssertEqual(page.items[0].labels.compactMap(\.colorHex), ["d73a4a", "7ba95b"])
        XCTAssertEqual(page.items[0].assignees, ["ada"])
        XCTAssertEqual(page.items[0].comments, 3)
        XCTAssertEqual(page.items[0].updatedAt, ISO8601Dates.parse("2026-11-03T10:00:00Z"))
        XCTAssertEqual(page.items[0].webURL.absoluteString,
                       "https://gitboy.example.com/octo/app/issues/12")
        // A missing updated_at falls back to created_at.
        XCTAssertEqual(page.items[1].updatedAt, ISO8601Dates.parse("2026-02-02T00:00:00Z"))

        let items = try queryItems(in: try XCTUnwrap(StubURLProtocol.requests.last?.url))
        XCTAssertEqual(items.first { $0.name == "paginated" }?.value, "true")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "open")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "50")
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "crash")
        XCTAssertEqual(items.first { $0.name == "cursor" }?.value, "cursor-1")
    }

    func testGitboyDetailKeepsCommentsAndSkipsEventRows() async throws {
        StubURLProtocol.stub("issues/12", status: 200, body: """
        {"index":12,"title":"Crash on launch","body":"Steps to reproduce: open the app.",
         "state":"open","author_username":"octo",
         "labels":[{"name":"bug","color":"#d73a4a"}],
         "assignees":[{"username":"ada"}],"comment_count":2,
         "updated_at":"2026-11-03T10:00:00Z"}
        """)
        StubURLProtocol.stub("issues/12/comments", status: 200, body: """
        [
          {"id":"c1","body":"Same here","author_username":"ada",
           "created_at":"2026-11-02T10:00:00Z","kind":"comment"},
          {"id":"e1","body":null,"author_username":"octo",
           "created_at":"2026-11-02T11:00:00Z","kind":"event"},
          {"id":"c2","body":"Fixed in 1.2","author_username":"octo",
           "created_at":"2026-11-03T09:00:00Z"}
        ]
        """)

        let detail = try await makeGitboy().issue(in: gitboyRepo(), number: 12)

        XCTAssertEqual(detail.issue.number, 12)
        XCTAssertEqual(detail.body, "Steps to reproduce: open the app.")
        XCTAssertEqual(detail.issue.labels.map(\.name), ["bug"])
        XCTAssertEqual(detail.issue.assignees, ["ada"])
        XCTAssertEqual(detail.issue.comments, 2)
        XCTAssertEqual(detail.comments.map(\.id), ["c1", "c2"], "event rows are not comments")
        XCTAssertEqual(detail.comments.map(\.author), ["ada", "octo"])
        XCTAssertEqual(detail.comments.last?.createdAt, ISO8601Dates.parse("2026-11-03T09:00:00Z"))
    }

    func testGitboyCreateSendsTitleAndBody() async throws {
        StubURLProtocol.stub("repos/octo/app/issues", status: 201, body: """
        {"index":13,"title":"New issue","body":"Please fix","state":"open","author_username":"octo",
         "labels":[],"assignees":[],"comment_count":0,"updated_at":"2026-11-03T10:00:00Z"}
        """)

        let created = try await makeGitboy().createIssue(in: gitboyRepo(),
                                                         title: "New issue", body: "Please fix")

        XCTAssertEqual(created.number, 13)
        XCTAssertEqual(created.state, .open)
        XCTAssertEqual(created.webURL.absoluteString,
                       "https://gitboy.example.com/octo/app/issues/13")
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/issues")
        let body = try XCTUnwrap(StubURLProtocol.bodies.last)
        XCTAssertTrue(body.contains(#""title":"New issue""#), body)
        XCTAssertTrue(body.contains(#""body":"Please fix""#), body)
    }

    func testGitboyCommentSendsItsBody() async throws {
        StubURLProtocol.stub("issues/13/comments", status: 201, body: """
        {"id":"c9","body":"On it","author_username":"ada",
         "created_at":"2026-11-03T11:00:00Z","kind":"comment"}
        """)

        let comment = try await makeGitboy().comment(on: gitboyIssue(number: 13), body: "On it")

        XCTAssertEqual(comment.id, "c9")
        XCTAssertEqual(comment.author, "ada")
        XCTAssertEqual(comment.body, "On it")
        XCTAssertEqual(comment.createdAt, ISO8601Dates.parse("2026-11-03T11:00:00Z"))
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/issues/13/comments")
        XCTAssertEqual(try XCTUnwrap(StubURLProtocol.bodies.last), #"{"body":"On it"}"#)
    }

    func testGitboyCloseSendsTheState() async throws {
        StubURLProtocol.stub("issues/13", status: 200, body: """
        {"index":13,"title":"Crash on launch","state":"closed","author_username":"octo",
         "labels":[],"assignees":[],"comment_count":0,"updated_at":"2026-11-03T12:00:00Z"}
        """)

        let closed = try await makeGitboy().setState(of: gitboyIssue(number: 13), to: .closed)

        XCTAssertEqual(closed.state, .closed)
        XCTAssertEqual(closed.number, 13)
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "PATCH")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/issues/13")
        XCTAssertEqual(try XCTUnwrap(StubURLProtocol.bodies.last), #"{"state":"closed"}"#)
    }

    func testGitboyMissingIssueScopeMapsToMissingScope() async {
        StubURLProtocol.stub("repos/octo/app/issues", status: 403,
                             body: #"{"error":"Token requires read:issue"}"#)

        do {
            _ = try await makeGitboy().issues(in: gitboyRepo(), state: .open,
                                              query: nil, cursor: nil)
            XCTFail("expected .missingScope for a 403 scope refusal")
        } catch {
            XCTAssertEqual(error as? ForgeError, .missingScope("read:issue"))
        }
    }
}

// MARK: - GitHub

extension ForgeIssuesTests {
    private func githubIssueJSON(number: Int, title: String = "Crash on launch") -> String {
        """
        {"number":\(number),"title":"\(title)","body":"Steps to reproduce.",
         "user":{"login":"octo"},"state":"open",
         "labels":[{"name":"bug","color":"d73a4a"}],"assignees":[{"login":"ada"}],
         "comments":2,"updated_at":"2026-11-03T10:00:00Z",
         "html_url":"https://github.com/octo/app/issues/\(number)"}
        """
    }

    func testGitHubListDropsPullRequests() async throws {
        StubURLProtocol.stub("repos/octo/app/issues", status: 200, body: """
        [
          \(githubIssueJSON(number: 5)),
          {"number":4,"title":"Add pulls","body":"","user":{"login":"octo"},"state":"open",
           "pull_request":{"url":"https://api.github.com/repos/octo/app/pulls/4"},"comments":0,
           "updated_at":"2026-11-02T10:00:00Z",
           "html_url":"https://github.com/octo/app/pull/4"}
        ]
        """)

        let page = try await makeGitHub().issues(in: githubRepo(), state: .open, query: nil, cursor: nil)

        XCTAssertEqual(page.items.map(\.number), [5], "a row with pull_request is a pull request")
        XCTAssertNil(page.next, "a short page is the end")
        XCTAssertEqual(page.items[0].labels.compactMap(\.colorHex), ["d73a4a"])
        XCTAssertEqual(page.items[0].assignees, ["ada"])
        XCTAssertEqual(page.items[0].comments, 2)
        XCTAssertEqual(page.items[0].author, "octo")
        XCTAssertEqual(page.items[0].webURL.absoluteString,
                       "https://github.com/octo/app/issues/5")

        let url = try XCTUnwrap(StubURLProtocol.requests.last?.url)
        XCTAssertTrue(url.contains("repos/octo/app/issues"), url)
        XCTAssertTrue(url.contains("state=open"), url)
        XCTAssertTrue(url.contains("per_page=50"), url)
        XCTAssertTrue(url.contains("page=1"), url)
    }

    func testGitHubQueryGoesToIssueSearch() async throws {
        StubURLProtocol.stub("search/issues", status: 200, body: """
        {"total_count":1,"incomplete_results":false,
         "items":[\(githubIssueJSON(number: 5))]}
        """)

        let page = try await makeGitHub().issues(in: githubRepo(), state: .open,
                                                 query: "crash", cursor: nil)

        XCTAssertEqual(page.items.map(\.number), [5])
        let url = try XCTUnwrap(StubURLProtocol.requests.last?.url)
        XCTAssertTrue(url.contains("search/issues"), url)
        XCTAssertFalse(url.contains("repos/octo/app/issues"), url)

        let q = try XCTUnwrap(queryItems(in: url).first { $0.name == "q" }?.value)
        XCTAssertTrue(q.contains("repo:octo/app"), q)
        XCTAssertTrue(q.contains("is:issue"), q)
        XCTAssertTrue(q.contains("is:open"), q)
        XCTAssertTrue(q.contains("crash"), q)
    }

    func testGitHubDetailReadsBodyAndComments() async throws {
        StubURLProtocol.stub("repos/octo/app/issues/5", status: 200,
                             body: githubIssueJSON(number: 5))
        StubURLProtocol.stub("repos/octo/app/issues/5/comments", status: 200, body: """
        [{"id":101,"user":{"login":"ada"},"body":"Same here",
          "created_at":"2026-11-02T10:00:00Z"}]
        """)

        let detail = try await makeGitHub().issue(in: githubRepo(), number: 5)

        XCTAssertEqual(detail.body, "Steps to reproduce.")
        XCTAssertEqual(detail.comments.map(\.id), ["101"])
        XCTAssertEqual(detail.comments[0].author, "ada")
        XCTAssertEqual(detail.comments[0].body, "Same here")
        XCTAssertEqual(detail.comments[0].createdAt, ISO8601Dates.parse("2026-11-02T10:00:00Z"))
    }

    func testGitHubCloseSendsTheStateInThePatchBody() async throws {
        StubURLProtocol.stub("repos/octo/app/issues/5", status: 200, body: """
        {"number":5,"title":"Crash on launch","body":"Steps to reproduce.","user":{"login":"octo"},
         "state":"closed","labels":[],"assignees":[],"comments":2,
         "updated_at":"2026-11-03T12:00:00Z",
         "html_url":"https://github.com/octo/app/issues/5"}
        """)

        let closed = try await makeGitHub().setState(of: githubIssue(number: 5), to: .closed)

        XCTAssertEqual(closed.state, .closed)
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "PATCH")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://api.github.com/repos/octo/app/issues/5")
        XCTAssertEqual(try XCTUnwrap(StubURLProtocol.bodies.last), #"{"state":"closed"}"#)
    }
}
