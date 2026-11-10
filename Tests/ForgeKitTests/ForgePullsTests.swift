import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ForgeKit

/// Pull requests over both forges: the same shapes come out of two different
/// JSON vocabularies, and every mapping that could silently disagree (review
/// verdicts, mergeability, check states) is pinned here.
final class ForgePullsTests: XCTestCase {
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

    private func gitboyPull(number: Int) -> ForgePullRequest {
        ForgePullRequest(repo: gitboyRepo(), number: number, title: "Add pulls", author: "octo",
                         state: .open, isDraft: false, headBranch: "pulls", baseBranch: "main",
                         updatedAt: nil,
                         webURL: URL(string: "https://gitboy.example.com/octo/app/pulls/\(number)")!)
    }

    private func githubPull(number: Int) -> ForgePullRequest {
        ForgePullRequest(repo: githubRepo(), number: number, title: "Add pulls", author: "octo",
                         state: .open, isDraft: false, headBranch: "pulls", baseBranch: "main",
                         updatedAt: nil,
                         webURL: URL(string: "https://github.com/octo/app/pull/\(number)")!)
    }

    private func queryItems(in url: String) throws -> [URLQueryItem] {
        try XCTUnwrap(URLComponents(string: url)).queryItems ?? []
    }

    /// One pull request's detail body with everything but the reviews fixed.
    private func gitboyDetailJSON(number: Int, headSHA: String = "head-sha",
                                  status: String = "mergeable",
                                  blockers: String = "[]",
                                  reviews: String = "[]") -> String {
        """
        {"index":\(number),"number":\(number),"title":"Add pulls","author_username":"octo",
         "state":"open","merged_at":null,"draft":false,"head_branch":"pulls","base_branch":"main",
         "updated_at":"2026-11-03T10:00:00Z","html_url":"https://gitboy.example.com/octo/app/pulls/\(number)",
         "body":"Adds the pull request screen.","head_sha":"\(headSHA)","status":"\(status)",
         "merge_blockers":\(blockers),"comment_count":4,"commits_ahead":3,
         "additions":10,"deletions":2,"changed_files":4,"reviews":\(reviews)}
        """
    }
}

// MARK: - gitboy list

extension ForgePullsTests {
    func testGitboyListReadsABareArrayAndFallsBackToTheWebPath() async throws {
        StubURLProtocol.stub("repos/octo/app/pulls", status: 200, body: """
        [
          {"index":3,"title":"Add pull requests","author_username":"octo","state":"open",
           "merged_at":null,"draft":true,"head_branch":"pulls","base_branch":"main",
           "updated_at":"2026-11-03T10:00:00Z",
           "html_url":"https://gitboy.example.com/octo/app/pulls/3"},
          {"index":2,"title":"Old work","author_username":"ada","state":"closed",
           "merged_at":"2026-11-01T09:00:00Z","head_branch":"old","base_branch":"main"}
        ]
        """)

        let page = try await makeGitboy().pullRequests(in: gitboyRepo(), state: .closed, cursor: nil)

        XCTAssertNil(page.next, "A bare array carries no cursor, so paging ends")
        XCTAssertEqual(page.items.map(\.number), [3, 2])
        XCTAssertEqual(page.items.map(\.state), [.open, .merged])
        XCTAssertEqual(page.items.map(\.isDraft), [true, false])
        XCTAssertEqual(page.items[0].author, "octo")
        XCTAssertEqual(page.items[0].headBranch, "pulls")
        XCTAssertEqual(page.items[0].baseBranch, "main")
        XCTAssertEqual(page.items[0].id, "gitboy:gitboy.example.com/octo/app#3")
        XCTAssertEqual(page.items[0].webURL.absoluteString, "https://gitboy.example.com/octo/app/pulls/3")
        XCTAssertEqual(page.items[0].updatedAt, ISO8601Dates.parse("2026-11-03T10:00:00Z"))

        // No html_url from an older gitboy: the web path is derived.
        XCTAssertEqual(page.items[1].webURL.absoluteString, "https://gitboy.example.com/octo/app/pulls/2")
        XCTAssertNil(page.items[1].updatedAt)

        let url = try XCTUnwrap(StubURLProtocol.requests.last?.url)
        let items = try queryItems(in: url)
        XCTAssertEqual(items.first { $0.name == "paginated" }?.value, "true",
                       "Without paginated=true gitboy omits next_cursor and paging stops at 50")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "closed")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "50")
        XCTAssertFalse(items.contains { $0.name == "cursor" })
    }

    func testGitboyListReadsThePagedEnvelopeAndItsCursor() async throws {
        StubURLProtocol.stub("repos/octo/app/pulls", status: 200, body: """
        {"items":[
          {"index":9,"title":"Next page","author_username":"octo","state":"open","merged_at":null,
           "head_branch":"next","base_branch":"main"}
        ],"next_cursor":"cursor-2"}
        """)

        let page = try await makeGitboy().pullRequests(in: gitboyRepo(), state: .open, cursor: "cursor-1")
        XCTAssertEqual(page.next, "cursor-2")
        XCTAssertEqual(page.items.map(\.number), [9])

        let items = try queryItems(in: try XCTUnwrap(StubURLProtocol.requests.last?.url))
        XCTAssertEqual(items.first { $0.name == "paginated" }?.value, "true")
        XCTAssertEqual(items.first { $0.name == "cursor" }?.value, "cursor-1")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "open")
    }
}

// MARK: - gitboy detail

extension ForgePullsTests {
    func testGitboyReviewDecisionChangesRequestedWins() async throws {
        let reviews = """
        [
          {"reviewer_username":"alice","state":"approved","commit_sha":"old-sha",
           "created_at":"2026-11-01T10:00:00Z","body":"LGTM"},
          {"reviewer_username":"octo","state":"approved","commit_sha":"head-sha",
           "created_at":"2026-11-01T11:00:00Z"},
          {"reviewer_username":"bob","state":"approved","commit_sha":"head-sha",
           "created_at":"2026-11-02T10:00:00Z"},
          {"reviewer_username":"carol","state":"changes_requested","commit_sha":"head-sha",
           "created_at":"2026-11-02T11:00:00Z","body":"Please fix"}
        ]
        """
        StubURLProtocol.stub("pulls/7", status: 200,
                             body: gitboyDetailJSON(number: 7, reviews: reviews))

        let detail = try await makeGitboy().pullRequest(in: gitboyRepo(), number: 7)

        XCTAssertEqual(detail.reviewDecision, .changesRequested)
        XCTAssertEqual(detail.pull.number, 7)
        XCTAssertEqual(detail.body, "Adds the pull request screen.")
        XCTAssertEqual(detail.headSHA, "head-sha")
        // Newest last, authored rows included.
        XCTAssertEqual(detail.reviews.map(\.reviewer), ["alice", "octo", "bob", "carol"])
        XCTAssertEqual(detail.reviews.map(\.state), [.approved, .approved, .approved, .changesRequested])
        XCTAssertEqual(detail.reviews.last?.body, "Please fix")
        XCTAssertEqual(detail.reviews.first?.submittedAt, ISO8601Dates.parse("2026-11-01T10:00:00Z"))
        XCTAssertEqual(detail.comments, 4)
        XCTAssertEqual(detail.commits, 3)
        XCTAssertEqual(detail.additions, 10)
        XCTAssertEqual(detail.deletions, 2)
        XCTAssertEqual(detail.changedFiles, 4)
    }

    func testGitboyApprovalsCountOnlyOnTheHeadAndNeverTheAuthor() async throws {
        // Only a stale approval and the author's own: no decision at all.
        StubURLProtocol.stub("pulls/8", status: 200, body: gitboyDetailJSON(number: 8, reviews: """
        [
          {"reviewer_username":"alice","state":"approved","commit_sha":"old-sha",
           "created_at":"2026-11-01T10:00:00Z"},
          {"reviewer_username":"octo","state":"approved","commit_sha":"head-sha",
           "created_at":"2026-11-01T11:00:00Z"}
        ]
        """))
        let stale = try await makeGitboy().pullRequest(in: gitboyRepo(), number: 8)
        XCTAssertNil(stale.reviewDecision)

        // A second reviewer on the head is an approval.
        StubURLProtocol.stub("pulls/9", status: 200, body: gitboyDetailJSON(number: 9, reviews: """
        [
          {"reviewer_username":"bob","state":"approved","commit_sha":"head-sha",
           "created_at":"2026-11-02T10:00:00Z"}
        ]
        """))
        let approved = try await makeGitboy().pullRequest(in: gitboyRepo(), number: 9)
        XCTAssertEqual(approved.reviewDecision, .approved)
    }

    func testGitboyMergeabilityFollowsItsStatusAndBlockers() async throws {
        // Queued in call order; the pipeline lookups that follow are 404 and
        // are treated as "no jobs", which is the old-gitboy case.
        StubURLProtocol.stub("pulls/30", status: 200,
                             body: gitboyDetailJSON(number: 30, status: "conflict"))
        StubURLProtocol.stub("pulls/30", status: 200,
                             body: gitboyDetailJSON(number: 30, status: "checking"))
        StubURLProtocol.stub("pulls/30", status: 200, body: gitboyDetailJSON(
            number: 30, blockers: #"["1 approval(s) required for main","A reviewer has requested changes"]"#))
        StubURLProtocol.stub("pulls/30", status: 200,
                             body: gitboyDetailJSON(number: 30, status: "mergeable"))
        StubURLProtocol.stub("pulls/30", status: 200, body: """
        {"index":30,"title":"Closed","author_username":"octo","state":"closed","merged_at":null,
         "status":"mergeable","head_sha":"head-sha","head_branch":"pulls"}
        """)

        let client = makeGitboy()
        let repo = gitboyRepo()
        let requested: [ForgeMergeability] = [
            .conflicts,
            .checking,
            .blocked(["1 approval(s) required for main", "A reviewer has requested changes"]),
            .clean,
            .notOpen,
        ]
        for expected in requested {
            let detail = try await client.pullRequest(in: repo, number: 30)
            XCTAssertEqual(detail.mergeability, expected)
        }
    }

    func testGitboyChecksComeFromTheNewestPipelineAndItsNewestAttempts() async throws {
        StubURLProtocol.stub("pulls/40", status: 200, body: """
        {"index":40,"title":"Add pulls","author_username":"octo","state":"open","merged_at":null,
         "head_branch":"feature","base_branch":"main","head_sha":"head-sha","status":"mergeable",
         "merge_blockers":[],"reviews":[],"checks":[]}
        """)
        // Two pipelines for the commit; only the highest iid is read.
        StubURLProtocol.stub("pipelines?", status: 200, body: """
        {"items":[
          {"iid":1,"sha":"head-sha","status":"failed"},
          {"iid":5,"sha":"head-sha","status":"failed"},
          {"iid":9,"sha":"other-sha","status":"success"}
        ]}
        """)
        StubURLProtocol.stub("pipelines/5", status: 200, body: """
        {"status":"failed","jobs":[
          {"id":"j1","name":"build","stage":"build","status":"failed","attempt":1,
           "started_at":"2026-11-03T10:00:00Z","finished_at":"2026-11-03T10:00:30Z",
           "failure_reason":"exit 1"},
          {"id":"j2","name":"build","stage":"build","status":"success","attempt":2,
           "started_at":"2026-11-03T10:01:00Z","finished_at":"2026-11-03T10:01:45Z"},
          {"id":"j3","name":"test","stage":"test","status":"failed","attempt":1},
          {"id":"j4","name":"docs","stage":"docs","status":"failed","allow_failure":true},
          {"id":"j5","name":"deploy","stage":"release","status":"running"}
        ]}
        """)

        let detail = try await makeGitboy().pullRequest(in: gitboyRepo(), number: 40)

        // Failing first, then by name within a state.
        XCTAssertEqual(detail.checks.map(\.name), ["test", "deploy", "build", "docs"])
        XCTAssertEqual(detail.checks.map(\.state), [.failing, .pending, .passing, .neutral])

        let build = try XCTUnwrap(detail.checks.first { $0.name == "build" })
        XCTAssertEqual(build.group, "build")
        XCTAssertEqual(build.seconds, 45, "The newest attempt's timing is shown")
        XCTAssertEqual(build.webURL?.absoluteString,
                       "https://gitboy.example.com/octo/app/pipelines/5?job=j2")
        XCTAssertTrue(detail.checks.first { $0.name == "test" }?.detail == nil)

        let pipelineRequests = StubURLProtocol.requests.filter { $0.url.contains("/pipelines?") }
        let query = try queryItems(in: try XCTUnwrap(pipelineRequests.first?.url))
        XCTAssertEqual(query.first { $0.name == "sha" }?.value, "head-sha")
        XCTAssertEqual(query.first { $0.name == "branch" }?.value, "feature")
    }
}

// MARK: - gitboy merge and review

extension ForgePullsTests {
    func testGitboyMergeReturnsTheMergeCommit() async throws {
        StubURLProtocol.stub("pulls/7/merge", status: 200,
                             body: #"{"merged":true,"merge_commit_sha":"merge-sha"}"#)

        let outcome = try await makeGitboy().merge(gitboyPull(number: 7), method: .squash,
                                                   expectedHeadSHA: "head-sha")
        XCTAssertEqual(outcome, .merged(sha: "merge-sha"))
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")

        let body = try XCTUnwrap(StubURLProtocol.bodies.last)
        XCTAssertTrue(body.contains(#""method":"squash""#), body)
        XCTAssertTrue(body.contains(#""expected_head_sha":"head-sha""#), body)
    }

    func testGitboyMergeRefusalKeepsItsBlockerSentences() async throws {
        StubURLProtocol.stub("pulls/7/merge", status: 409, body: """
        {"error":"Pull request cannot be merged",
         "details":["Resolve merge conflicts","2 approval(s) required for main"]}
        """)

        let outcome = try await makeGitboy().merge(gitboyPull(number: 7), method: .merge,
                                                   expectedHeadSHA: "head-sha")
        XCTAssertEqual(outcome, .refused(["Resolve merge conflicts", "2 approval(s) required for main"]))
    }

    func testGitboyMergeReportsAHeadThatMoved() async throws {
        StubURLProtocol.stub("pulls/7/merge", status: 409,
                             body: #"{"error":"Pull request head changed; inspect the current source before merging"}"#)

        let outcome = try await makeGitboy().merge(gitboyPull(number: 7), method: .rebase,
                                                   expectedHeadSHA: "head-sha")
        XCTAssertEqual(outcome, .headMoved)
    }

    func testGitboyMergeReportsATargetThatMoved() async throws {
        StubURLProtocol.stub("pulls/7/merge", status: 409,
                             body: #"{"error":"Pull request target changed; inspect the current target before merging"}"#)

        let outcome = try await makeGitboy().merge(gitboyPull(number: 7), method: .merge,
                                                   expectedHeadSHA: "head-sha")
        XCTAssertEqual(outcome, .headMoved)
    }

    func testGitboyMergeKeepsABlockerThatMerelyMentionsAHead() async throws {
        // "head" inside a blocker is about the branch, not about a moved merge.
        StubURLProtocol.stub("pulls/7/merge", status: 409, body: """
        {"error":"Pull request cannot be merged",
         "details":["The head branch is behind main","A successful pipeline is required"]}
        """)

        let outcome = try await makeGitboy().merge(gitboyPull(number: 7), method: .merge,
                                                   expectedHeadSHA: "head-sha")
        XCTAssertEqual(outcome, .refused(["The head branch is behind main",
                                          "A successful pipeline is required"]))
    }

    func testGitboyRebaseMergePinsTheTargetCommit() async throws {
        StubURLProtocol.stub("pulls/7", status: 200, body: """
        {"index":7,"title":"Add pulls","author_username":"octo","state":"open","merged_at":null,
         "head_branch":"pulls","base_branch":"main","head_sha":"head-sha","base_sha":"base-sha",
         "status":"mergeable","merge_blockers":[]}
        """)
        StubURLProtocol.stub("pulls/7/merge", status: 200,
                             body: #"{"merged":true,"merge_commit_sha":"merge-sha"}"#)

        let outcome = try await makeGitboy().merge(gitboyPull(number: 7), method: .rebase,
                                                   expectedHeadSHA: "head-sha")
        XCTAssertEqual(outcome, .merged(sha: "merge-sha"))

        let body = try XCTUnwrap(StubURLProtocol.bodies.last)
        XCTAssertTrue(body.contains(#""method":"rebase""#), body)
        XCTAssertTrue(body.contains(#""expected_base_sha":"base-sha""#), body)
        XCTAssertTrue(body.contains(#""expected_head_sha":"head-sha""#), body)

        // The target commit is read before the merge is asked for.
        let requests = StubURLProtocol.requests.map { $0.url }
        XCTAssertEqual(requests.filter { $0.hasSuffix("/pulls/7") }.count, 1)
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
    }

    func testGitboyReviewSendsItsStateAndTheHeadItPinned() async throws {
        StubURLProtocol.stub("pulls/7/reviews", status: 201, body: "{}")

        let client = makeGitboy()
        let pull = gitboyPull(number: 7)
        try await client.review(pull, verdict: .approve, body: "Looks good",
                                expectedHeadSHA: "pinned-sha")
        try await client.review(pull, verdict: .requestChanges, body: "Needs tests",
                                expectedHeadSHA: "pinned-sha")
        try await client.review(pull, verdict: .comment, body: "A note",
                                expectedHeadSHA: "pinned-sha")

        let sent = StubURLProtocol.bodies.filter { $0.contains("\"state\"") }
        XCTAssertEqual(sent.count, 3)
        XCTAssertTrue(sent[0].contains(#""state":"approved""#), sent[0])
        XCTAssertTrue(sent[1].contains(#""state":"changes_requested""#), sent[1])
        XCTAssertTrue(sent[2].contains(#""state":"commented""#), sent[2])
        for body in sent {
            XCTAssertTrue(body.contains(#""expected_head_sha":"pinned-sha""#), body)
        }
        XCTAssertTrue(sent[1].contains("Needs tests"), sent[1])
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        // The head is the caller's; the pull request is never re-read for it.
        XCTAssertFalse(StubURLProtocol.requests.contains { request in
            request.url.hasSuffix("/pulls/7")
        }, "The current head must not be read to sign a review")
    }

    func testGitboyReviewReportsAHeadThatMoved() async {
        StubURLProtocol.stub("pulls/7/reviews", status: 409, body: """
        {"error":"Pull request head changed; reload and inspect the current diff before reviewing"}
        """)

        do {
            try await makeGitboy().review(gitboyPull(number: 7), verdict: .approve,
                                          body: "Looks good", expectedHeadSHA: "pinned-sha")
            XCTFail("expected .conflict for a review of a head that moved")
        } catch {
            XCTAssertEqual(error as? ForgeError,
                           .conflict("The branch moved. Reload before reviewing."))
        }
    }
}

// MARK: - GitHub list

extension ForgePullsTests {
    private func githubPullsJSON(_ count: Int) -> String {
        let items = (1...max(1, count)).prefix(count).map { index in
            """
            {"number":\(index),"title":"Pull \(index)","user":{"login":"octo"},"state":"open",\
            "draft":false,"head":{"ref":"pulls-\(index)","sha":"sha-\(index)"},\
            "base":{"ref":"main"},"updated_at":"2026-11-03T10:00:00Z"}
            """
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    func testGitHubListPagesByNumberAndEndsOnAShortPage() async throws {
        StubURLProtocol.stub("repos/octo/app/pulls", status: 200, body: githubPullsJSON(50))
        StubURLProtocol.stub("repos/octo/app/pulls", status: 200, body: githubPullsJSON(2))

        let forge = makeGitHub()
        let repo = githubRepo()
        let full = try await forge.pullRequests(in: repo, state: .open, cursor: "2")
        XCTAssertEqual(full.items.count, 50)
        XCTAssertEqual(full.next, "3", "A full page may have another behind it")

        var items = try queryItems(in: try XCTUnwrap(StubURLProtocol.requests.last?.url))
        XCTAssertEqual(items.first { $0.name == "page" }?.value, "2")
        XCTAssertEqual(items.first { $0.name == "per_page" }?.value, "50")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "open")

        let short = try await forge.pullRequests(in: repo, state: .open, cursor: "3")
        XCTAssertNil(short.next)
        XCTAssertEqual(short.items.map(\.number), [1, 2])
        XCTAssertEqual(short.items[0].webURL.absoluteString, "https://github.com/octo/app/pull/1")
        XCTAssertEqual(short.items[0].headBranch, "pulls-1")

        items = try queryItems(in: try XCTUnwrap(StubURLProtocol.requests.last?.url))
        XCTAssertEqual(items.first { $0.name == "page" }?.value, "3")
    }
}

// MARK: - GitHub detail

extension ForgePullsTests {
    private func githubDetailJSON(mergeableState: String?) -> String {
        let state = mergeableState.map { #""mergeable_state":"\#($0)","# } ?? ""
        return """
        {"number":12,"title":"Add pulls","body":"Hello from GitHub","user":{"login":"octo"},
         "state":"open","draft":false,"head":{"ref":"pulls","sha":"head-sha"},"base":{"ref":"main"},
         "updated_at":"2026-11-03T10:00:00Z","html_url":"https://github.com/octo/app/pull/12",
         "merged_at":null,"mergeable":false,\(state)"commits":3,"additions":10,"deletions":2,
         "changed_files":4,"comments":3,"review_comments":2}
        """
    }

    func testGitHubDetailMapsMergeabilityAndEveryCheckConclusion() async throws {
        StubURLProtocol.stub("pulls/12", status: 200,
                             body: githubDetailJSON(mergeableState: "dirty"))
        StubURLProtocol.stub("pulls/12/reviews", status: 200, body: """
        [{"user":{"login":"alice"},"state":"APPROVED","submitted_at":"2026-11-02T10:00:00Z"},
         {"user":{"login":"bob"},"state":"CHANGES_REQUESTED","submitted_at":"2026-11-02T11:00:00Z"},
         {"user":{"login":"bob"},"state":"APPROVED","submitted_at":"2026-11-02T12:00:00Z"},
         {"user":{"login":"carol"},"state":"COMMENTED","submitted_at":"2026-11-02T13:00:00Z"}]
        """)
        StubURLProtocol.stub("commits/head-sha/check-runs", status: 200, body: """
        {"total_count":8,"check_runs":[
          {"name":"a-success","status":"completed","conclusion":"success",
           "started_at":"2026-11-03T10:00:00Z","completed_at":"2026-11-03T10:00:20Z"},
          {"name":"b-failure","status":"completed","conclusion":"failure",
           "html_url":"https://github.com/octo/app/runs/1"},
          {"name":"c-timed","status":"completed","conclusion":"timed_out"},
          {"name":"d-cancelled","status":"completed","conclusion":"cancelled"},
          {"name":"e-action","status":"completed","conclusion":"action_required"},
          {"name":"f-skipped","status":"completed","conclusion":"skipped"},
          {"name":"g-neutral","status":"completed","conclusion":"neutral"},
          {"name":"h-running","status":"in_progress","conclusion":null}
        ]}
        """)

        let detail = try await makeGitHub().pullRequest(in: githubRepo(), number: 12)

        XCTAssertEqual(detail.pull.number, 12)
        XCTAssertEqual(detail.body, "Hello from GitHub")
        XCTAssertEqual(detail.headSHA, "head-sha")
        XCTAssertEqual(detail.mergeability, .conflicts, "dirty is a conflict")
        XCTAssertEqual(detail.commits, 3)
        XCTAssertEqual(detail.additions, 10)
        XCTAssertEqual(detail.deletions, 2)
        XCTAssertEqual(detail.changedFiles, 4)
        XCTAssertEqual(detail.comments, 5, "comments plus review comments")
        // bob's later approval replaces his request; carol's comment says nothing.
        XCTAssertEqual(detail.reviewDecision, .approved)
        XCTAssertEqual(detail.reviews.map(\.reviewer), ["alice", "bob", "bob", "carol"])

        XCTAssertEqual(detail.checks.map(\.name),
                       ["b-failure", "c-timed", "d-cancelled", "e-action", "h-running",
                        "a-success", "f-skipped", "g-neutral"])
        let states = Dictionary(uniqueKeysWithValues: detail.checks.map { ($0.name, $0.state) })
        XCTAssertEqual(states["b-failure"], .failing)
        XCTAssertEqual(states["c-timed"], .failing)
        XCTAssertEqual(states["d-cancelled"], .failing)
        XCTAssertEqual(states["e-action"], .failing)
        XCTAssertEqual(states["a-success"], .passing)
        XCTAssertEqual(states["f-skipped"], .skipped)
        XCTAssertEqual(states["g-neutral"], .neutral)
        XCTAssertEqual(states["h-running"], .pending, "A run that hasn't finished is pending")
        XCTAssertEqual(detail.checks.first { $0.name == "a-success" }?.seconds, 20)
        XCTAssertEqual(detail.checks.first { $0.name == "b-failure" }?.webURL?.absoluteString,
                       "https://github.com/octo/app/runs/1")
    }

    func testGitHubMergeableStateMapping() async throws {
        StubURLProtocol.stub("pulls/1/reviews", status: 200, body: "[]")
        for state in ["clean", "dirty", "blocked", "behind", "unstable", "has_hooks", "unknown"] {
            StubURLProtocol.stub("pulls/1", status: 200, body: githubDetailJSON(mergeableState: state))
        }
        // No mergeable_state at all is GitHub still deciding.
        StubURLProtocol.stub("pulls/1", status: 200, body: githubDetailJSON(mergeableState: nil))

        let forge = makeGitHub()
        let repo = githubRepo()
        let expected: [ForgeMergeability] = [
            .clean,
            .conflicts,
            .blocked(["Merge is blocked by branch protection or required checks."]),
            .blocked(["The branch is behind the base branch."]),
            // Only non-required checks are failing, or a hook ran: still mergeable.
            .clean,
            .clean,
            .checking,
            .checking,
        ]
        for mergeability in expected {
            let detail = try await forge.pullRequest(in: repo, number: 1)
            XCTAssertEqual(detail.mergeability, mergeability)
        }
    }

    /// One page's worth of reviews JSON, every reviewer distinct.
    private func githubReviewsJSON(count: Int, state: String,
                                   start: Int, at time: String) -> String {
        let rows = (0..<count).map { offset in
            """
            {"user":{"login":"reviewer-\(start + offset)"},"state":"\(state)",\
            "submitted_at":"\(time)"}
            """
        }
        return "[" + rows.joined(separator: ",") + "]"
    }

    func testGitHubReviewsBehindTheFirstPageStillCount() async throws {
        StubURLProtocol.stub("pulls/12", status: 200,
                             body: githubDetailJSON(mergeableState: "clean"))
        StubURLProtocol.stub("pulls/12/reviews", status: 200,
                             body: githubReviewsJSON(count: 100, state: "APPROVED",
                                                     start: 0, at: "2026-11-02T10:00:00Z"))
        StubURLProtocol.stub("pulls/12/reviews", status: 200,
                             body: githubReviewsJSON(count: 1, state: "CHANGES_REQUESTED",
                                                     start: 100, at: "2026-11-02T11:00:00Z"))

        let detail = try await makeGitHub().pullRequest(in: githubRepo(), number: 12)

        XCTAssertEqual(detail.reviews.count, 101, "Every page of reviews is read")
        XCTAssertEqual(detail.reviews.last?.reviewer, "reviewer-100")
        XCTAssertEqual(detail.reviews.last?.state, .changesRequested)
        XCTAssertEqual(detail.reviewDecision, .changesRequested,
                       "A verdict behind the first page still decides")
        let reviewRequests = StubURLProtocol.requests.filter { $0.url.contains("/pulls/12/reviews") }
        XCTAssertEqual(reviewRequests.map(\.url), [
            "https://api.github.com/repos/octo/app/pulls/12/reviews?per_page=100",
            "https://api.github.com/repos/octo/app/pulls/12/reviews?per_page=100&page=2",
        ])
    }
}

// MARK: - GitHub merge and review

extension ForgePullsTests {
    func testGitHubMergeSendsTheMethodAndPinnedHead() async throws {
        StubURLProtocol.stub("pulls/12/merge", status: 200,
                             body: #"{"sha":"merge-sha","merged":true,"message":"Pull Request successfully merged"}"#)

        let outcome = try await makeGitHub().merge(githubPull(number: 12), method: .rebase,
                                                   expectedHeadSHA: "head-sha")
        XCTAssertEqual(outcome, .merged(sha: "merge-sha"))
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "PUT")

        let body = try XCTUnwrap(StubURLProtocol.bodies.last)
        XCTAssertTrue(body.contains(#""merge_method":"rebase""#), body)
        XCTAssertTrue(body.contains(#""sha":"head-sha""#), body)
    }

    func testGitHubMerge409MeansTheHeadMoved() async throws {
        StubURLProtocol.stub("pulls/12/merge", status: 409, body: """
        {"message":"Head branch was modified. Review and try the merge again."}
        """)

        let outcome = try await makeGitHub().merge(githubPull(number: 12), method: .merge,
                                                    expectedHeadSHA: "head-sha")
        XCTAssertEqual(outcome, .headMoved)
    }

    func testGitHubMerge405KeepsTheBlockerMessage() async throws {
        StubURLProtocol.stub("pulls/12/merge", status: 405, body: """
        {"message":"Pull Request is not mergeable: the merge commit cannot be cleanly created."}
        """)

        let outcome = try await makeGitHub().merge(githubPull(number: 12), method: .merge,
                                                    expectedHeadSHA: "head-sha")
        XCTAssertEqual(outcome, .refused(["Pull Request is not mergeable: the merge commit cannot be cleanly created."]))
    }

    func testGitHubReviewSendsTheEventWordAndThePinnedCommit() async throws {
        StubURLProtocol.stub("pulls/12/reviews", status: 200, body: "{}")

        let forge = makeGitHub()
        let pull = githubPull(number: 12)
        try await forge.review(pull, verdict: .approve, body: "Looks good",
                               expectedHeadSHA: "pinned-sha")
        try await forge.review(pull, verdict: .requestChanges, body: "Needs tests",
                               expectedHeadSHA: "pinned-sha")
        try await forge.review(pull, verdict: .comment, body: "A note",
                               expectedHeadSHA: "pinned-sha")

        let sent = StubURLProtocol.bodies.filter { $0.contains("\"event\"") }
        XCTAssertEqual(sent.count, 3)
        XCTAssertTrue(sent[0].contains(#""event":"APPROVE""#), sent[0])
        XCTAssertTrue(sent[1].contains(#""event":"REQUEST_CHANGES""#), sent[1])
        XCTAssertTrue(sent[2].contains(#""event":"COMMENT""#), sent[2])
        for body in sent {
            XCTAssertTrue(body.contains(#""commit_id":"pinned-sha""#), body)
        }
        XCTAssertTrue(sent[1].contains("Needs tests"), sent[1])
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
    }
}
