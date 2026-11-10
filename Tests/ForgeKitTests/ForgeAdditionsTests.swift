import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ForgeKit

/// What 0.2.0 added on top of the extracted layer: GitHub failures in the
/// forge's own error cases, the pull request conversation and diff, agent
/// sessions, token lookup, and the request hooks an app builds on.
final class ForgeAdditionsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        ForgeHeaderRecorder.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        ForgeHeaderRecorder.reset()
        super.tearDown()
    }

    private func repo(_ host: ForgeHost) -> ForgeRepo {
        ForgeRepo(host: host, owner: "octo", name: "app", description: nil,
                  isPrivate: false, defaultBranch: "main", isArchived: false,
                  updatedAt: nil,
                  webURL: URL(string: "https://\(host.domain)/octo/app")!)
    }

    private func pull(_ host: ForgeHost, number: Int = 7) -> ForgePullRequest {
        ForgePullRequest(repo: repo(host), number: number, title: "Add pulls", author: "octo",
                         state: .open, isDraft: false, headBranch: "pulls", baseBranch: "main",
                         updatedAt: nil,
                         webURL: URL(string: "https://\(host.domain)/octo/app/pulls/\(number)")!)
    }

    private func issue(_ host: ForgeHost, number: Int = 12) -> ForgeIssue {
        ForgeIssue(repo: repo(host), number: number, title: "Fix sync", author: "octo",
                   state: .open, labels: [], assignees: [], comments: 0, updatedAt: nil,
                   webURL: URL(string: "https://\(host.domain)/octo/app/issues/\(number)")!)
    }

    private func makeGitboy() -> GitboyClient {
        GitboyClient(host: .testGitboy, token: "test-token", session: StubURLProtocol.session())
    }

    private func makeGitHub(token: String? = "test-token") -> GitHubForge {
        GitHubForge(client: GitHubHTTPTransport(session: StubURLProtocol.session(), token: token))
    }

    private func forgeError(_ work: () async throws -> Void,
                            file: StaticString = #filePath, line: UInt = #line) async -> ForgeError? {
        do {
            try await work()
            XCTFail("Expected the call to throw", file: file, line: line)
            return nil
        } catch let error as ForgeError {
            return error
        } catch {
            XCTFail("Expected a ForgeError, got \(type(of: error)): \(error)", file: file, line: line)
            return nil
        }
    }
}

// MARK: - GitHub failures as ForgeError

extension ForgeAdditionsTests {
    func testGitHubStatusesArriveAsForgeErrors() async {
        let expectations: [(status: Int, body: String, expected: ForgeError)] = [
            (401, #"{"message":"Bad credentials"}"#,
             .unauthorized("Your GitHub token has expired or been revoked. Sign out in Settings, "
                           + "then sign in again with a new token.")),
            (403, #"{"message":"Resource not accessible by personal access token"}"#,
             .unauthorized("Resource not accessible by personal access token")),
            (409, #"{"message":"Git Repository is empty."}"#, .conflict("Git Repository is empty.")),
            (500, #"{"message":"boom"}"#, .server(status: 500, message: "boom")),
        ]
        for expectation in expectations {
            StubURLProtocol.reset()
            StubURLProtocol.stub("repos/octo/app/issues/12", status: expectation.status,
                                 body: expectation.body)
            let github = makeGitHub()
            let error = await forgeError { _ = try await github.issue(in: self.repo(.github), number: 12) }
            XCTAssertEqual(error, expectation.expected, "HTTP \(expectation.status)")
        }
    }

    /// GitHub answers 404 for a repository the token may not see. The forge
    /// keeps the sentence that says so; a 404 anywhere else is plain.
    func testGitHubNotFoundOnARepositoryKeepsTheAccessExplanation() async {
        StubURLProtocol.stub("repos/octo/app/issues/12", status: 404, body: #"{"message":"Not Found"}"#)
        let github = makeGitHub()
        let onRepo = await forgeError { _ = try await github.issue(in: self.repo(.github), number: 12) }
        guard case .unauthorized(let message) = onRepo else {
            return XCTFail("Expected the access explanation, got \(String(describing: onRepo))")
        }
        XCTAssertTrue(message.contains("octo/app"), message)
        XCTAssertTrue(message.contains("token"), message)

        StubURLProtocol.reset()
        StubURLProtocol.stub("api.github.com/user", status: 404, body: #"{"message":"Not Found"}"#)
        let elsewhere = await forgeError { _ = try await self.makeGitHub().currentUser() }
        XCTAssertEqual(elsewhere, .notFound)
    }

    func testGitHubWithoutATokenIsNotSignedIn() async {
        let github = makeGitHub(token: nil)
        let error = await forgeError { _ = try await github.currentUser() }
        XCTAssertEqual(error, .notSignedIn)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "Nothing is sent without a token")
    }

    func testGitHubThrottlingCarriesTheTimeToWaitUntil() async throws {
        StubURLProtocol.stub("api.github.com/user", status: 429,
                             headers: ["retry-after": "30"],
                             body: #"{"message":"You have exceeded a secondary rate limit."}"#)
        let before = Date()
        let github = makeGitHub()
        let error = await forgeError { _ = try await github.currentUser() }
        guard case .rateLimited(let until) = error else {
            return XCTFail("Expected .rateLimited, got \(String(describing: error))")
        }
        let wait = try XCTUnwrap(until).timeIntervalSince(before)
        XCTAssertGreaterThanOrEqual(wait, 29)
        XCTAssertLessThanOrEqual(wait, 40)
    }

    func testGitHubAnswerThatDoesNotDecodeIsAnInvalidResponse() async {
        StubURLProtocol.stub("api.github.com/user", status: 200, body: #"{"unexpected":true}"#)
        let github = makeGitHub()
        let error = await forgeError { _ = try await github.currentUser() }
        XCTAssertEqual(error, .invalidResponse)
    }

    func testEveryGitHubErrorHasAForgeCase() {
        XCTAssertEqual(ForgeError(GitHubError.notAuthenticated), .notSignedIn)
        XCTAssertEqual(ForgeError(GitHubError.invalidResponse), .invalidResponse)
        XCTAssertEqual(ForgeError(GitHubError.shaConflict(path: "notes.md")),
                       .conflict("notes.md changed on GitHub while editing."))
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ForgeError(GitHubError.rateLimited(resetAt: reset, retryAfter: nil)),
                       .rateLimited(until: reset))
        // A 403 on a write to a repository keeps GitHub's explanation of the fix.
        let denied = GitHubError.http(status: 403, message: "Forbidden", method: "PUT",
                                      path: "repos/octo/app/contents/notes.md")
        guard case .unauthorized(let message) = ForgeError(denied) else {
            return XCTFail("Expected .unauthorized")
        }
        XCTAssertTrue(message.contains("octo/app"), message)
    }
}

// MARK: - Pull request conversation and diff

extension ForgeAdditionsTests {
    func testGitboyPullCommentsLeaveOutEventRows() async throws {
        StubURLProtocol.stub("issues/7/comments", status: 200, body: """
        [{"id":"c1","body":"Looks good","author_username":"ada","created_at":"2026-11-03T08:00:00Z"},
         {"id":"e1","body":"","author_username":"octo","kind":"closed","created_at":"2026-11-03T08:30:00Z"},
         {"id":"c2","body":"Merging","author_username":"octo","kind":"comment","created_at":"2026-11-03T09:00:00Z"}]
        """)

        let comments = try await makeGitboy().comments(on: pull(.testGitboy))

        XCTAssertEqual(comments.map(\.id), ["c1", "c2"])
        XCTAssertEqual(comments.map(\.author), ["ada", "octo"])
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/issues/7/comments")
    }

    /// An issue detail treats a refused comments read as "no comments". A
    /// caller that asked for the conversation is told why it has none.
    func testGitboyPullCommentsRefusalIsThrown() async {
        StubURLProtocol.stub("issues/7/comments", status: 403,
                             body: #"{"error":"Token requires read:issue"}"#)
        let gitboy = makeGitboy()
        let error = await forgeError { _ = try await gitboy.comments(on: self.pull(.testGitboy)) }
        XCTAssertEqual(error, .missingScope("read:issue"))
    }

    func testGitboyPullCommentPostsToTheSharedConversationRoute() async throws {
        StubURLProtocol.stub("issues/7/comments", status: 201, body: """
        {"id":"c9","body":"Ship it","author_username":"octo","created_at":"2026-11-03T10:00:00Z"}
        """)

        let comment = try await makeGitboy().comment(on: pull(.testGitboy), body: "Ship it")

        XCTAssertEqual(comment.id, "c9")
        XCTAssertEqual(comment.body, "Ship it")
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/issues/7/comments")
        XCTAssertTrue(try XCTUnwrap(StubURLProtocol.bodies.last).contains("Ship it"))
    }

    func testGitHubPullCommentsReadAndWriteTheIssueConversation() async throws {
        StubURLProtocol.stub("repos/octo/app/issues/7/comments", status: 200, body: """
        [{"id":101,"user":{"login":"ada"},"body":"Looks good","created_at":"2026-11-03T08:00:00Z"}]
        """)
        let github = makeGitHub()

        let comments = try await github.comments(on: pull(.github))
        XCTAssertEqual(comments.map(\.id), ["101"])
        XCTAssertEqual(comments.first?.author, "ada")

        StubURLProtocol.reset()
        StubURLProtocol.stub("repos/octo/app/issues/7/comments", status: 201, body: """
        {"id":102,"user":{"login":"octo"},"body":"Ship it","created_at":"2026-11-03T10:00:00Z"}
        """)
        let posted = try await github.comment(on: pull(.github), body: "Ship it")
        XCTAssertEqual(posted.id, "102")
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
    }

    func testGitboyDiffCarriesTheCommitItWasComputedAt() async throws {
        StubURLProtocol.stub("pulls/7/diff", status: 200, body: """
        {"diff":"diff --git a/a.txt b/a.txt\\n+hello\\n","head_sha":"abc123","merge_base":"def456"}
        """)

        let diff = try await makeGitboy().diff(of: pull(.testGitboy))

        XCTAssertEqual(diff.text, "diff --git a/a.txt b/a.txt\n+hello\n")
        XCTAssertEqual(diff.headSHA, "abc123")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/pulls/7/diff")
    }

    func testGitboyDiffTooLargeSaysSo() async {
        StubURLProtocol.stub("pulls/7/diff", status: 413,
                             body: #"{"error":"Pull request diff exceeds 8 MiB"}"#)
        let gitboy = makeGitboy()
        let error = await forgeError { _ = try await gitboy.diff(of: self.pull(.testGitboy)) }
        XCTAssertEqual(error, .server(status: 413, message: "Pull request diff exceeds 8 MiB"))
    }

    func testGitHubDiffAsksForTheDiffMediaType() async throws {
        StubURLProtocol.stub("repos/octo/app/pulls/7", status: 200,
                             body: "diff --git a/a.txt b/a.txt\n+hello\n")

        let diff = try await makeGitHub().diff(of: pull(.github))

        XCTAssertEqual(diff.text, "diff --git a/a.txt b/a.txt\n+hello\n")
        XCTAssertNil(diff.headSHA)
        XCTAssertEqual(StubURLProtocol.requests.last?.url, "https://api.github.com/repos/octo/app/pulls/7")
        XCTAssertEqual(StubURLProtocol.headers.last?["Accept"], "application/vnd.github.diff")
    }
}

// MARK: - Agent sessions

extension ForgeAdditionsTests {
    private var sessionJSON: String {
        """
        {"id":"5f0c1d2e-0000-4000-8000-000000000001","issue_index":12,
         "repository":{"id":"r1","full_name":"octo/app"},
         "runner":{"id":"run-1","name":"mini"},"harness":"claude","status":"needs_you",
         "branch":"agent/12-5f0c1d2e","requested_by":"u1","requested_by_username":"octo",
         "pull_request":{"id":"p1","index":14,"url":"https://gitboy.example.com/octo/app/pulls/14"},
         "error_code":null,"created_at":"2026-11-03T10:00:00.000Z","updated_at":"2026-11-03T10:05:00.000Z"}
        """
    }

    func testComputersAreTheUsersRunnersThatRunAgents() async throws {
        let now = ISO8601Dates.string(from: Date())
        StubURLProtocol.stub("user/runners", status: 200, body: """
        [{"id":"run-1","name":"mini","status":"online","last_seen_at":"\(now)",
          "agent_harnesses":["claude","codex","claude"," "],"capabilities":{"agent_v1":true}},
         {"id":"run-2","name":"ci-only","status":"online","last_seen_at":"\(now)","agent_harnesses":[]},
         {"id":"run-3","name":"opted-out","status":"online","last_seen_at":"\(now)",
          "agent_harnesses":["claude"],"capabilities":{"agent_v1":false}},
         {"id":"run-4","name":"older-server","status":"offline","last_seen_at":"2026-01-01T00:00:00Z",
          "agent_harnesses":["codex"]}]
        """)

        let computers = try await makeGitboy().computers()

        XCTAssertEqual(computers.map(\.name), ["mini", "older-server"])
        XCTAssertEqual(computers[0].harnesses, ["claude", "codex"], "repeats and blanks are dropped")
        XCTAssertTrue(computers[0].isOnline)
        XCTAssertFalse(computers[1].isOnline)
        XCTAssertEqual(computers[0].runner.scope, .mine)
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/user/runners")
    }

    /// gitboy refuses a session on a paused computer, or on one that has not
    /// checked in for a minute, although a runner list still calls both
    /// reachable. The computer says what the server will say.
    func testAComputerIsOnlineByTheRuleForStartingASession() async throws {
        let now = ISO8601Dates.string(from: Date())
        let ninetySecondsAgo = ISO8601Dates.string(from: Date().addingTimeInterval(-90))
        StubURLProtocol.stub("user/runners", status: 200, body: """
        [{"id":"run-1","name":"ready","status":"online","last_seen_at":"\(now)","agent_harnesses":["claude"]},
         {"id":"run-2","name":"paused","status":"paused","last_seen_at":"\(now)","agent_harnesses":["claude"]},
         {"id":"run-3","name":"quiet","status":"online","last_seen_at":"\(ninetySecondsAgo)",
          "agent_harnesses":["claude"]}]
        """)

        let computers = try await makeGitboy().computers()

        XCTAssertEqual(computers.map(\.name), ["ready", "paused", "quiet"])
        XCTAssertEqual(computers.map(\.isOnline), [true, false, false])
        XCTAssertTrue(computers[2].runner.isOnline, "The runner list's looser window still applies there")
    }

    func testAgentSessionsOnAnIssueMapTheLifecycleRow() async throws {
        StubURLProtocol.stub("issues/12/agent-sessions", status: 200, body: "[\(sessionJSON)]")

        let sessions = try await makeGitboy().agentSessions(on: issue(.testGitboy))

        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.sessionID, "5f0c1d2e-0000-4000-8000-000000000001")
        XCTAssertEqual(session.repository, "octo/app")
        XCTAssertEqual(session.issueNumber, 12)
        XCTAssertEqual(session.computerID, "run-1")
        XCTAssertEqual(session.computerName, "mini")
        XCTAssertEqual(session.harness, "claude")
        XCTAssertEqual(session.status, .needsYou)
        XCTAssertTrue(session.status.isActive)
        XCTAssertEqual(session.branch, "agent/12-5f0c1d2e")
        XCTAssertEqual(session.requestedBy, "octo")
        XCTAssertEqual(session.pullRequestNumber, 14)
        XCTAssertEqual(session.pullRequestURL?.absoluteString,
                       "https://gitboy.example.com/octo/app/pulls/14")
        XCTAssertNil(session.errorCode)
        XCTAssertEqual(session.createdAt, ISO8601Dates.parse("2026-11-03T10:00:00.000Z"))
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/issues/12/agent-sessions")
    }

    func testAgentStatusWordsAndTheOneThisClientDoesNotKnow() {
        XCTAssertEqual(GitboyClient.agentStatus("queued"), .queued)
        XCTAssertEqual(GitboyClient.agentStatus("claimed"), .claimed)
        XCTAssertEqual(GitboyClient.agentStatus("done"), .done)
        XCTAssertEqual(GitboyClient.agentStatus("failed"), .failed)
        XCTAssertEqual(GitboyClient.agentStatus("canceled"), .canceled)
        XCTAssertEqual(GitboyClient.agentStatus("something_new"), .running,
                       "An unknown word is not a terminal state")
        XCTAssertFalse(ForgeAgentStatus.done.isActive)
        XCTAssertFalse(ForgeAgentStatus.failed.isActive)
        XCTAssertFalse(ForgeAgentStatus.canceled.isActive)
    }

    func testMyAgentSessionsReadTheAccountWideList() async throws {
        StubURLProtocol.stub("user/agent-sessions", status: 200, body: "[\(sessionJSON)]")

        let sessions = try await makeGitboy().myAgentSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/user/agent-sessions")
    }

    private func computer() -> ForgeComputer {
        let runner = ForgeRunner(host: .testGitboy, scope: .mine, runnerID: "run-1", name: "mini",
                                 labels: [], isOnline: true, isPaused: false, isBusy: false,
                                 lastSeenAt: nil, version: nil, os: nil, capacity: nil,
                                 isEphemeral: false, currentJobs: [])
        return ForgeComputer(runner: runner, harnesses: ["claude"])
    }

    func testStartingASessionPostsTheComputerAndHarness() async throws {
        StubURLProtocol.stub("issues/12/agent-sessions", status: 201, body: sessionJSON)

        let session = try await makeGitboy().startAgentSession(on: issue(.testGitboy),
                                                               computer: computer(), harness: "claude")

        XCTAssertEqual(session.sessionID, "5f0c1d2e-0000-4000-8000-000000000001")
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        let body = try XCTUnwrap(StubURLProtocol.bodies.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(json["runner_id"] as? String, "run-1")
        XCTAssertEqual(json["harness"] as? String, "claude")
    }

    /// gitboy answers 429 when the requester already has as many sessions as
    /// may run at once. That is a state to fix, not a moment to wait out.
    func testStartingPastTheSessionLimitIsAConflictInTheServersWords() async {
        StubURLProtocol.stub("issues/12/agent-sessions", status: 429,
                             body: #"{"error":"You already have 3 active agent sessions"}"#)
        let gitboy = makeGitboy()
        let error = await forgeError {
            _ = try await gitboy.startAgentSession(on: self.issue(.testGitboy),
                                                   computer: self.computer(), harness: "claude")
        }
        XCTAssertEqual(error, .conflict("You already have 3 active agent sessions"))
    }

    func testStartingOnAnIssueThatAlreadyHasASessionIsAConflict() async {
        StubURLProtocol.stub("issues/12/agent-sessions", status: 409,
                             body: #"{"error":"This issue already has an active agent session"}"#)
        let gitboy = makeGitboy()
        let error = await forgeError {
            _ = try await gitboy.startAgentSession(on: self.issue(.testGitboy),
                                                   computer: self.computer(), harness: "claude")
        }
        XCTAssertEqual(error, .conflict("This issue already has an active agent session"))
    }

    func testCancelPostsToTheSessionsOwnIssueRoute() async throws {
        let canceled = sessionJSON.replacingOccurrences(of: "needs_you", with: "canceled")
        StubURLProtocol.stub("agent-sessions/5f0c1d2e-0000-4000-8000-000000000001/cancel",
                             status: 200, body: canceled)
        let gitboy = makeGitboy()
        StubURLProtocol.stub("issues/12/agent-sessions", status: 200, body: "[\(sessionJSON)]")
        let listed = try await gitboy.agentSessions(on: issue(.testGitboy))
        let session = try XCTUnwrap(listed.first)

        let updated = try await gitboy.cancel(session)

        XCTAssertEqual(updated.status, .canceled)
        XCTAssertFalse(updated.status.isActive)
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/issues/12/agent-sessions/"
                       + "5f0c1d2e-0000-4000-8000-000000000001/cancel")
    }

    func testAHostWithoutAgentSessionsRefusesInsteadOfGuessing() async {
        let github = makeGitHub()
        XCTAssertFalse(github.capabilities.contains(.agentSessions))
        let error = await forgeError { _ = try await github.computers() }
        guard case .server(let status, let message) = error else {
            return XCTFail("Expected a refusal, got \(String(describing: error))")
        }
        XCTAssertEqual(status, 0)
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "Nothing is sent for an unsupported call")
    }
}

// MARK: - Token lookup

extension ForgeAdditionsTests {
    func testTokenInfoFindsTheTokenByItsLastEightCharacters() async throws {
        // The client signs with "test-token": its last eight are "st-token".
        StubURLProtocol.stub("user/tokens", status: 200, body: """
        [{"id":"t1","name":"laptop","last_eight":"zzzzzzzz","scopes":["read:repo"],"expires_at":null},
         {"id":"t2","name":"phone","last_eight":"st-token","scopes":["read:user","read:repo","write:repo"],
          "expires_at":"2027-02-01T00:00:00.000Z"}]
        """)

        let info = try await makeGitboy().tokenInfo()

        XCTAssertEqual(info, ForgeTokenInfo(name: "phone",
                                            scopes: ["read:user", "read:repo", "write:repo"],
                                            expiresAt: ISO8601Dates.parse("2027-02-01T00:00:00.000Z")))
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/user/tokens")
    }

    func testTokenInfoIsNilWhenTheMatchIsNotUnique() async throws {
        StubURLProtocol.stub("user/tokens", status: 200, body: """
        [{"id":"t1","name":"one","last_eight":"st-token","scopes":["read:repo"]},
         {"id":"t2","name":"two","last_eight":"st-token","scopes":["admin"]}]
        """)
        let ambiguous = try await makeGitboy().tokenInfo()
        XCTAssertNil(ambiguous, "Two candidates: showing either one's scopes would be a guess")

        StubURLProtocol.reset()
        StubURLProtocol.stub("user/tokens", status: 200, body: "[]")
        let absent = try await makeGitboy().tokenInfo()
        XCTAssertNil(absent)
    }
}

// MARK: - Live log

extension ForgeAdditionsTests {
    /// gitboy ends the stream with `access_revoked` when the token loses its
    /// access mid-read. That is a refusal, not the job's final status.
    func testLiveLogEndsWithARefusalWhenAccessIsRevoked() async throws {
        ForgeHeaderRecorder.reset(status: 200, body: """
        : connected

        event: log
        id: 6
        data: {"offset":0,"text":"Hello "}

        event: done
        data: {"status":"access_revoked"}
        """)
        let client = GitboyClient(host: .testGitboy, token: "gb-secret",
                                  session: ForgeHeaderRecorder.session())
        let run = ForgeRun(repo: repo(.testGitboy), runID: "7", number: 7, title: "Pipeline #7",
                           workflow: nil, branch: "main", sha: "sha-7", event: "push", actor: "octo",
                           status: .running, createdAt: nil, updatedAt: nil,
                           webURL: URL(string: "https://gitboy.example.com/octo/app/pipelines/7")!)
        let job = ForgeJob(run: run, jobID: "j1", name: "build", stage: "build", status: .running,
                           attempt: 1, allowFailure: false, failureReason: nil, startedAt: nil,
                           finishedAt: nil, runnerName: nil,
                           webURL: URL(string: "https://gitboy.example.com/octo/app/pipelines/7?job=j1")!)

        var events: [ForgeLogEvent] = []
        var failure: Error?
        do {
            for try await event in client.liveLog(of: job) { events.append(event) }
        } catch {
            failure = error
        }

        XCTAssertEqual(events, [.text("Hello ")], "The text read before the refusal is kept")
        guard case .unauthorized = failure as? ForgeError else {
            return XCTFail("Expected .unauthorized, got \(String(describing: failure))")
        }
    }

    /// gitboy closes a long log stream on a time limit with `timeout`. The
    /// job is not over: the stream reconnects from the last byte read.
    func testLiveLogPicksUpAgainAfterTheServersTimeLimit() async throws {
        ForgeHeaderRecorder.reset(status: 200, body: """
        event: log
        id: 6
        data: {"offset":0,"text":"Hello "}

        event: done
        data: {"status":"timeout","offset":6}
        """)
        ForgeHeaderRecorder.queue(status: 200, body: """
        event: log
        id: 12
        data: {"offset":6,"text":"world!"}

        event: done
        data: {"status":"success"}
        """)
        let client = GitboyClient(host: .testGitboy, token: "gb-secret",
                                  session: ForgeHeaderRecorder.session())
        let run = ForgeRun(repo: repo(.testGitboy), runID: "7", number: 7, title: "Pipeline #7",
                           workflow: nil, branch: "main", sha: "sha-7", event: "push", actor: "octo",
                           status: .running, createdAt: nil, updatedAt: nil,
                           webURL: URL(string: "https://gitboy.example.com/octo/app/pipelines/7")!)
        let job = ForgeJob(run: run, jobID: "j1", name: "build", stage: "build", status: .running,
                           attempt: 1, allowFailure: false, failureReason: nil, startedAt: nil,
                           finishedAt: nil, runnerName: nil,
                           webURL: URL(string: "https://gitboy.example.com/octo/app/pipelines/7?job=j1")!)

        var events: [ForgeLogEvent] = []
        for try await event in client.liveLog(of: job) { events.append(event) }

        XCTAssertEqual(events, [.text("Hello "), .text("world!"), .finished(.success)])
        XCTAssertEqual(ForgeHeaderRecorder.requests.map(\.url), [
            "https://gitboy.example.com/api/v1/repos/octo/app/jobs/j1/log/stream",
            "https://gitboy.example.com/api/v1/repos/octo/app/jobs/j1/log/stream?offset=6",
        ])
    }

    /// A job removed while its log is being read closes the stream with
    /// `deleted`, which is not a status a job can finish in.
    func testLiveLogOfADeletedJobEndsAsNotFound() async {
        ForgeHeaderRecorder.reset(status: 200, body: """
        event: done
        data: {"status":"deleted"}
        """)
        let client = GitboyClient(host: .testGitboy, token: "gb-secret",
                                  session: ForgeHeaderRecorder.session())
        let run = ForgeRun(repo: repo(.testGitboy), runID: "7", number: 7, title: "Pipeline #7",
                           workflow: nil, branch: "main", sha: "sha-7", event: "push", actor: "octo",
                           status: .running, createdAt: nil, updatedAt: nil,
                           webURL: URL(string: "https://gitboy.example.com/octo/app/pipelines/7")!)
        let job = ForgeJob(run: run, jobID: "j1", name: "build", stage: "build", status: .running,
                           attempt: 1, allowFailure: false, failureReason: nil, startedAt: nil,
                           finishedAt: nil, runnerName: nil,
                           webURL: URL(string: "https://gitboy.example.com/octo/app/pipelines/7?job=j1")!)

        var failure: Error?
        do {
            for try await _ in client.liveLog(of: job) {}
        } catch {
            failure = error
        }
        XCTAssertEqual(failure as? ForgeError, .notFound)
    }
}

// MARK: - GitHub repository search and request hooks

extension ForgeAdditionsTests {
    private func reposJSON(count: Int, prefix: String) -> String {
        let rows = (0..<count).map { index in
            """
            {"id":\(index),"full_name":"octo/\(prefix)-\(index)","name":"\(prefix)-\(index)",
             "owner":{"login":"octo"},"private":false,"default_branch":"main","pushed_at":null}
            """
        }
        return "[" + rows.joined(separator: ",") + "]"
    }

    /// The filter is applied to each page here, so a first page with no match
    /// used to come back empty while still offering more.
    func testRepoSearchReadsPastAPageWithNoMatch() async throws {
        StubURLProtocol.stub("&page=1&affiliation", status: 200, body: reposJSON(count: 100, prefix: "alpha"))
        StubURLProtocol.stub("&page=2&affiliation", status: 200, body: reposJSON(count: 1, prefix: "needle"))

        let page = try await makeGitHub().repos(cursor: nil, query: "needle")

        XCTAssertEqual(page.items.map(\.name), ["needle-0"])
        XCTAssertNil(page.next, "The short second page is the end of the list")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testRepoListWithoutASearchStillReadsOnePagePerCall() async throws {
        StubURLProtocol.stub("&page=1&affiliation", status: 200, body: reposJSON(count: 100, prefix: "alpha"))

        let page = try await makeGitHub().repos(cursor: nil, query: nil)

        XCTAssertEqual(page.items.count, 100)
        XCTAssertEqual(page.next, "2")
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testRepoSearchStopsAfterAFewPagesAndKeepsTheCursor() async throws {
        for number in 1...6 {
            StubURLProtocol.stub("&page=\(number)&affiliation", status: 200,
                                 body: reposJSON(count: 100, prefix: "alpha"))
        }

        let page = try await makeGitHub().repos(cursor: nil, query: "needle")

        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.next, "6", "The search can be continued from where it stopped")
        XCTAssertEqual(StubURLProtocol.requests.count, 5)
    }

    private struct Refused: Error {}

    /// An app's demo mode refuses requests before they leave the device.
    func testPreflightCanRefuseARequestBeforeItIsSent() async {
        let transport = GitHubHTTPTransport(session: StubURLProtocol.session(), token: "test-token",
                                            preflight: { throw Refused() })
        do {
            _ = try await transport.currentUser()
            XCTFail("Expected the preflight to refuse the request")
        } catch {
            XCTAssertTrue(error is Refused, "\(error)")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// An app's own GitHub requests are built on the public `request`; a
    /// conditional one sends back the ETag it was last given.
    func testConditionalRequestSendsBackTheLastETag() async throws {
        StubURLProtocol.stub("git/ref/heads/main", status: 200, headers: ["Etag": "\"v1\""],
                             body: #"{"object":{"sha":"abc"}}"#)
        let transport = GitHubHTTPTransport(session: StubURLProtocol.session(), token: "test-token")
        let path = try GitHubHTTPTransport.repoPath(owner: "octo", repo: "app") + "/git/ref/heads/main"

        let (_, first) = try await transport.request(path, etagKey: "head")
        try GitHubHTTPTransport.ensureOK(first, data: Data(), path: path)
        XCTAssertNil(StubURLProtocol.headers.last?["If-None-Match"])

        _ = try await transport.request(path, etagKey: "head")
        XCTAssertEqual(StubURLProtocol.headers.last?["If-None-Match"], "\"v1\"")

        // Another account must not be answered from the first one's cache.
        await transport.setToken("other-token")
        _ = try await transport.request(path, etagKey: "head")
        XCTAssertNil(StubURLProtocol.headers.last?["If-None-Match"])
    }
}
