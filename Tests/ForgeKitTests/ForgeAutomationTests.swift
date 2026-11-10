import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ForgeKit

/// What 0.3.0 added: starting a workflow or pipeline, and the pull request
/// actions that let a merge happen without someone watching it.
final class ForgeAutomationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
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

    private func makeGitboy() -> GitboyClient {
        GitboyClient(host: .testGitboy, token: "test-token", session: StubURLProtocol.session())
    }

    private func makeGitHub() -> GitHubForge {
        GitHubForge(client: GitHubHTTPTransport(session: StubURLProtocol.session(), token: "test-token"))
    }

    private func lastBody() throws -> [String: Any] {
        let body = try XCTUnwrap(StubURLProtocol.bodies.last)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
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

    private let headSHA = "0123456789abcdef0123456789abcdef01234567"
}

// MARK: - Starting a run

extension ForgeAutomationTests {
    func testGitboyListsItsOwnPipelineThenTheWorkflowsThatCanBeStarted() async throws {
        StubURLProtocol.stub("ci/workflows", status: 200, body: """
        [{"path":".github/workflows/release.yml","name":"Release","dispatch":true,
          "inputs":{"version":{"description":"Version to tag","required":true},
                    "dry_run":{"type":"boolean","default":false},
                    "channel":{"type":"choice","options":["stable","preview"],"default":"stable"},
                    "bare":null},
          "errors":[]},
         {"path":".github/workflows/ci.yml","name":"CI","dispatch":false,"inputs":{},"errors":[]},
         {"path":".github/workflows/broken.yml","name":"broken.yml","dispatch":false,"inputs":{},
          "errors":[{"path":".github/workflows/broken.yml","message":"Workflow could not be read"}]}]
        """)

        let workflows = try await makeGitboy().workflows(in: repo(.testGitboy), ref: "release/1.2")

        XCTAssertEqual(workflows.map(\.name), ["Pipeline", "Release"],
                       "Only what a person can start is listed")
        XCTAssertEqual(workflows[0].workflowID, "")
        XCTAssertNil(workflows[0].path)
        let release = workflows[1]
        XCTAssertEqual(release.workflowID, ".github/workflows/release.yml")
        XCTAssertEqual(release.inputs.map(\.name), ["bare", "channel", "dry_run", "version"])
        let byName = Dictionary(uniqueKeysWithValues: release.inputs.map { ($0.name, $0) })
        XCTAssertEqual(byName["version"]?.isRequired, true)
        XCTAssertEqual(byName["version"]?.description, "Version to tag")
        XCTAssertEqual(byName["dry_run"]?.defaultValue, "false", "A boolean default is read as text")
        XCTAssertEqual(byName["channel"]?.options, ["stable", "preview"])
        XCTAssertEqual(byName["channel"]?.defaultValue, "stable")
        XCTAssertEqual(byName["bare"]?.isRequired, false)
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/ci/workflows?ref=release/1.2")
    }

    func testGitboyStartsAWorkflowWithItsInputs() async throws {
        StubURLProtocol.stub("repos/octo/app/pipelines", status: 201, body: """
        {"iid":42,"sha":"abc","ref":"refs/heads/main","status":"queued","source":"manual",
         "html_url":"https://gitboy.example.com/octo/app/pipelines/42"}
        """)
        let workflow = ForgeWorkflow(repo: repo(.testGitboy), workflowID: ".github/workflows/release.yml",
                                     name: "Release", path: ".github/workflows/release.yml", inputs: [])

        let run = try await makeGitboy().start(workflow, ref: "main", inputs: ["version": "1.2.0"])

        XCTAssertEqual(run?.runID, "42")
        XCTAssertEqual(run?.status, .queued)
        XCTAssertEqual(run?.branch, "main")
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/pipelines")
        let body = try lastBody()
        XCTAssertEqual(body["ref"] as? String, "main")
        XCTAssertEqual(body["workflow"] as? String, ".github/workflows/release.yml")
        XCTAssertEqual(body["inputs"] as? [String: String], ["version": "1.2.0"])
        XCTAssertNil(body["variables"])
    }

    /// The repository's own pipeline is started by naming no workflow, and
    /// what an Actions workflow calls inputs it takes as variables.
    func testGitboyStartsItsOwnPipelineWithVariables() async throws {
        StubURLProtocol.stub("repos/octo/app/pipelines", status: 201,
                             body: #"{"iid":43,"sha":"abc","status":"queued"}"#)
        let own = ForgeWorkflow(repo: repo(.testGitboy), workflowID: "", name: "Pipeline",
                                path: nil, inputs: [])

        let run = try await makeGitboy().start(own, ref: "main", inputs: ["DEPLOY_ENV": "staging"])

        XCTAssertEqual(run?.runID, "43")
        let body = try lastBody()
        XCTAssertNil(body["workflow"])
        XCTAssertNil(body["inputs"])
        XCTAssertEqual(body["variables"] as? [String: String], ["DEPLOY_ENV": "staging"])
    }

    func testGitboyStartWithNothingToRunSaysWhy() async {
        StubURLProtocol.stub("repos/octo/app/pipelines", status: 400,
                             body: #"{"error":"No matching CI workflow exists at this ref or CI is disabled"}"#)
        let own = ForgeWorkflow(repo: repo(.testGitboy), workflowID: "", name: "Pipeline",
                                path: nil, inputs: [])
        let gitboy = makeGitboy()
        let error = await forgeError { _ = try await gitboy.start(own, ref: "main", inputs: [:]) }
        XCTAssertEqual(error, .server(status: 400,
                                      message: "No matching CI workflow exists at this ref or CI is disabled"))
    }

    func testGitHubListsTheWorkflowsThatAreNotDisabled() async throws {
        StubURLProtocol.stub("repos/octo/app/actions/workflows", status: 200, body: """
        {"total_count":3,"workflows":[
          {"id":11,"name":"Release","path":".github/workflows/release.yml","state":"active"},
          {"id":12,"name":"Old","path":".github/workflows/old.yml","state":"disabled_manually"},
          {"id":10,"name":"CI","path":".github/workflows/ci.yml","state":"active"}]}
        """)

        let workflows = try await makeGitHub().workflows(in: repo(.github), ref: nil)

        XCTAssertEqual(workflows.map(\.name), ["CI", "Release"])
        XCTAssertEqual(workflows.map(\.workflowID), ["10", "11"])
        XCTAssertEqual(workflows.first?.path, ".github/workflows/ci.yml")
        XCTAssertTrue(workflows.allSatisfy { $0.inputs.isEmpty })
    }

    func testGitHubStartDispatchesTheWorkflowAndHasNoRunToAnswerWith() async throws {
        StubURLProtocol.stub("actions/workflows/11/dispatches", status: 204, body: "")
        let workflow = ForgeWorkflow(repo: repo(.github), workflowID: "11", name: "Release",
                                     path: ".github/workflows/release.yml", inputs: [])

        let run = try await makeGitHub().start(workflow, ref: "main", inputs: ["version": "1.2.0"])

        XCTAssertNil(run, "GitHub accepts the request and does not say which run it started")
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://api.github.com/repos/octo/app/actions/workflows/11/dispatches")
        let body = try lastBody()
        XCTAssertEqual(body["ref"] as? String, "main")
        XCTAssertEqual(body["inputs"] as? [String: String], ["version": "1.2.0"])
    }

    func testGitHubStartOfAWorkflowWithoutAManualTriggerKeepsGitHubsSentence() async {
        StubURLProtocol.stub("actions/workflows/10/dispatches", status: 422,
                             body: #"{"message":"Workflow does not have 'workflow_dispatch' trigger"}"#)
        let workflow = ForgeWorkflow(repo: repo(.github), workflowID: "10", name: "CI", path: nil, inputs: [])
        let github = makeGitHub()
        let error = await forgeError { _ = try await github.start(workflow, ref: "main", inputs: [:]) }
        XCTAssertEqual(error, .server(status: 422,
                                      message: "Workflow does not have 'workflow_dispatch' trigger"))
    }
}

// MARK: - Capabilities follow the transport

extension ForgeAutomationTests {
    func testBothHostsOfferTheNewActionsWithForgeKitsOwnTransport() {
        let added: ForgeCapabilities = [.startRuns, .autoMerge, .updateBranch, .markReady]
        XCTAssertTrue(makeGitboy().capabilities.isSuperset(of: added))
        XCTAssertTrue(makeGitHub().capabilities.isSuperset(of: added))
    }

    /// An app's own GitHub client that has not added the new requests keeps
    /// compiling. The forge then does not offer what that client cannot do,
    /// and refuses instead of crashing if asked anyway.
    func testAGitHubTransportWithoutTheNewRequestsDoesNotOfferThem() async {
        // GitHubMappedTransport conforms to GitHubTransport only.
        let older = GitHubMappedTransport(base: GitHubHTTPTransport(session: StubURLProtocol.session(),
                                                                    token: "test-token"))
        let github = GitHubForge(client: older)

        for flag: ForgeCapabilities in [.startRuns, .autoMerge, .updateBranch, .markReady] {
            XCTAssertFalse(github.capabilities.contains(flag))
        }
        XCTAssertTrue(github.capabilities.contains(.pullDiffs), "What it can do is still offered")

        let listing = await forgeError { _ = try await github.workflows(in: self.repo(.github), ref: nil) }
        let merging = await forgeError {
            try await github.enableAutoMerge(self.pull(.github), method: .squash,
                                             expectedHeadSHA: self.headSHA)
        }
        for error in [listing, merging] {
            guard case .server(let status, let message) = error else {
                return XCTFail("Expected a refusal, got \(String(describing: error))")
            }
            XCTAssertEqual(status, 0)
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "Nothing is sent for an unsupported call")
    }
}

// MARK: - Pull requests that move by themselves

extension ForgeAutomationTests {
    func testGitboyQueuesAMergePinnedToTheHead() async throws {
        StubURLProtocol.stub("pulls/7/auto-merge", status: 200,
                             body: #"{"method":"squash","state":"pending","actor_username":"octo"}"#)

        try await makeGitboy().enableAutoMerge(pull(.testGitboy), method: .squash, expectedHeadSHA: headSHA)

        XCTAssertEqual(StubURLProtocol.requests.last?.method, "PUT")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/pulls/7/auto-merge")
        let body = try lastBody()
        XCTAssertEqual(body["method"] as? String, "squash")
        XCTAssertEqual(body["expected_head_sha"] as? String, headSHA)
    }

    func testGitboyRefusesAQueuedRebaseBeforeAskingTheServer() async {
        let gitboy = makeGitboy()
        let error = await forgeError {
            try await gitboy.enableAutoMerge(self.pull(.testGitboy), method: .rebase,
                                             expectedHeadSHA: self.headSHA)
        }
        guard case .validation = error else {
            return XCTFail("Expected a local refusal, got \(String(describing: error))")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testGitboyHeadThatMovedIsWordedForTheScreen() async {
        StubURLProtocol.stub("pulls/7/auto-merge", status: 409, body: """
        {"error":"Pull request head changed; inspect the current source before merging"}
        """)
        StubURLProtocol.stub("pulls/7/update-branch", status: 409, body: """
        {"error":"Pull request head changed; inspect the current source before updating it"}
        """)
        let gitboy = makeGitboy()

        let queued = await forgeError {
            try await gitboy.enableAutoMerge(self.pull(.testGitboy), method: .merge,
                                             expectedHeadSHA: self.headSHA)
        }
        let updated = await forgeError {
            try await gitboy.updateBranch(of: self.pull(.testGitboy), expectedHeadSHA: self.headSHA)
        }

        XCTAssertEqual(queued, .conflict("The branch moved. Reload and try again."))
        XCTAssertEqual(updated, .conflict("The branch moved. Reload and try again."))
    }

    /// Any other 409 keeps the server's own sentence: it names the fix.
    func testGitboyClosedPullRequestKeepsTheServersSentence() async {
        StubURLProtocol.stub("pulls/7/ready", status: 409, body: #"{"error":"Pull request is closed"}"#)
        let gitboy = makeGitboy()
        let error = await forgeError { try await gitboy.markReady(self.pull(.testGitboy)) }
        XCTAssertEqual(error, .conflict("Pull request is closed"))
    }

    func testGitboyTakesBackUpdatesAndMarksReady() async throws {
        StubURLProtocol.stub("pulls/7/auto-merge", status: 200, body: "null")
        StubURLProtocol.stub("pulls/7/update-branch", status: 200, body: #"{"index":7}"#)
        StubURLProtocol.stub("pulls/7/ready", status: 200, body: #"{"index":7}"#)
        let gitboy = makeGitboy()

        try await gitboy.disableAutoMerge(pull(.testGitboy))
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "DELETE")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/pulls/7/auto-merge")

        try await gitboy.updateBranch(of: pull(.testGitboy), expectedHeadSHA: headSHA)
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/pulls/7/update-branch")
        XCTAssertEqual(try lastBody()["expected_head_sha"] as? String, headSHA)

        try await gitboy.markReady(pull(.testGitboy))
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/pulls/7/ready")
    }

    /// gitboy keeps the auto-merge row after the merge is made or taken back.
    /// Only a pending one is a merge still to come.
    func testGitboyDetailSaysWhetherAMergeIsQueued() async throws {
        let base = #"{"index":7,"title":"Add pulls","state":"open","head_sha":"abc","head_branch":"","status":"mergeable""#
        StubURLProtocol.stub("pulls/7", status: 200, body: base + """
        ,"auto_merge":{"method":"squash","state":"pending","reason":"Waiting for 1 check",
                       "actor_username":"octo"}}
        """)
        let queued = try await makeGitboy().pullRequest(in: repo(.testGitboy), number: 7)
        XCTAssertEqual(queued.autoMerge,
                       ForgeAutoMerge(method: .squash, requestedBy: "octo", reason: "Waiting for 1 check"))

        StubURLProtocol.reset()
        StubURLProtocol.stub("pulls/7", status: 200, body: base + """
        ,"auto_merge":{"method":"squash","state":"canceled","reason":"Canceled by octo",
                       "actor_username":"octo"}}
        """)
        let canceled = try await makeGitboy().pullRequest(in: repo(.testGitboy), number: 7)
        XCTAssertNil(canceled.autoMerge)

        StubURLProtocol.reset()
        StubURLProtocol.stub("pulls/7", status: 200, body: base + #","auto_merge":null}"#)
        let never = try await makeGitboy().pullRequest(in: repo(.testGitboy), number: 7)
        XCTAssertNil(never.autoMerge)
    }

    private func stubGitHubPull(extra: String = "") {
        StubURLProtocol.stub("repos/octo/app/pulls/7", status: 200, body: """
        {"number":7,"title":"Add pulls","state":"open","node_id":"PR_kwDOexample",
         "head":{"ref":"pulls","sha":"\(headSHA)"},"base":{"ref":"main","sha":"def"}\(extra)}
        """)
    }

    func testGitHubQueuesAMergeThroughGraphQLWithThePullRequestsNodeID() async throws {
        stubGitHubPull()
        StubURLProtocol.stub("api.github.com/graphql", status: 200,
                             body: #"{"data":{"enablePullRequestAutoMerge":{"clientMutationId":null}}}"#)

        try await makeGitHub().enableAutoMerge(pull(.github), method: .squash, expectedHeadSHA: headSHA)

        XCTAssertEqual(StubURLProtocol.requests.map(\.url), [
            "https://api.github.com/repos/octo/app/pulls/7",
            "https://api.github.com/graphql",
        ])
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        let body = try lastBody()
        XCTAssertTrue((body["query"] as? String ?? "").contains("enablePullRequestAutoMerge"))
        let variables = try XCTUnwrap(body["variables"] as? [String: String])
        XCTAssertEqual(variables, ["id": "PR_kwDOexample", "method": "SQUASH", "oid": headSHA])
    }

    /// GitHub answers a refused mutation with 200 and an `errors` list.
    func testGitHubRefusedMutationIsAnErrorInGitHubsWords() async {
        stubGitHubPull()
        StubURLProtocol.stub("api.github.com/graphql", status: 200, body: """
        {"data":{"enablePullRequestAutoMerge":null},
         "errors":[{"type":"UNPROCESSABLE","message":"Pull request is in clean status"}]}
        """)
        let github = makeGitHub()
        let error = await forgeError {
            try await github.enableAutoMerge(self.pull(.github), method: .merge,
                                             expectedHeadSHA: self.headSHA)
        }
        XCTAssertEqual(error, .server(status: 422, message: "Pull request is in clean status"))
    }

    func testGitHubTakesAMergeBackAndMarksReadyThroughGraphQL() async throws {
        stubGitHubPull()
        StubURLProtocol.stub("api.github.com/graphql", status: 200, body: #"{"data":{}}"#)
        let github = makeGitHub()

        try await github.disableAutoMerge(pull(.github))
        var body = try lastBody()
        XCTAssertTrue((body["query"] as? String ?? "").contains("disablePullRequestAutoMerge"))
        XCTAssertEqual(body["variables"] as? [String: String], ["id": "PR_kwDOexample"])

        try await github.markReady(pull(.github))
        body = try lastBody()
        XCTAssertTrue((body["query"] as? String ?? "").contains("markPullRequestReadyForReview"))
        XCTAssertEqual(body["variables"] as? [String: String], ["id": "PR_kwDOexample"])
    }

    func testGitHubUpdatesTheBranchPinnedToTheHead() async throws {
        StubURLProtocol.stub("pulls/7/update-branch", status: 202,
                             body: #"{"message":"Updating pull request branch.","url":"https://github.com/octo/app/pull/7"}"#)

        try await makeGitHub().updateBranch(of: pull(.github), expectedHeadSHA: headSHA)

        XCTAssertEqual(StubURLProtocol.requests.last?.method, "PUT")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://api.github.com/repos/octo/app/pulls/7/update-branch")
        XCTAssertEqual(try lastBody()["expected_head_sha"] as? String, headSHA)
    }

    func testGitHubDetailSaysWhetherAMergeIsQueued() async throws {
        stubGitHubPull(extra: #","auto_merge":{"merge_method":"squash","enabled_by":{"login":"octo"}}"#)
        StubURLProtocol.stub("repos/octo/app/pulls/7/reviews", status: 200, body: "[]")
        StubURLProtocol.stub("check-runs", status: 200, body: #"{"check_runs":[]}"#)

        let queued = try await makeGitHub().pullRequest(in: repo(.github), number: 7)
        XCTAssertEqual(queued.autoMerge, ForgeAutoMerge(method: .squash, requestedBy: "octo", reason: nil))

        StubURLProtocol.reset()
        stubGitHubPull(extra: #","auto_merge":null"#)
        StubURLProtocol.stub("repos/octo/app/pulls/7/reviews", status: 200, body: "[]")
        StubURLProtocol.stub("check-runs", status: 200, body: #"{"check_runs":[]}"#)
        let plain = try await makeGitHub().pullRequest(in: repo(.github), number: 7)
        XCTAssertNil(plain.autoMerge)
    }
}
