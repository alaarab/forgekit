import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ForgeKit

/// CI runs, jobs, actions and logs over gitboy: the pipeline vocabulary out of
/// the server, the order a screen draws jobs in, and the SSE log stream parsed
/// from a canned byte stream.
final class ForgeRunsTests: XCTestCase {
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

    private func gitboyRepo() -> ForgeRepo {
        ForgeRepo(host: .testGitboy, owner: "octo", name: "app", description: nil,
                  isPrivate: false, defaultBranch: "main", isArchived: false,
                  updatedAt: nil,
                  webURL: URL(string: "https://gitboy.example.com/octo/app")!)
    }

    private func makeGitboy() -> GitboyClient {
        GitboyClient(host: .testGitboy, token: "test-token", session: StubURLProtocol.session())
    }

    private func makeRun(iid: Int = 7, status: ForgeRunStatus = .failed) -> ForgeRun {
        ForgeRun(repo: gitboyRepo(), runID: String(iid), number: iid,
                 title: "Pipeline #\(iid)", workflow: ".github/workflows/ci.yml",
                 branch: "main", sha: "sha-\(iid)", event: "push", actor: "octo",
                 status: status,
                 createdAt: ISO8601Dates.parse("2026-11-03T10:00:00Z"),
                 updatedAt: nil,
                 webURL: URL(string: "https://gitboy.example.com/octo/app/pipelines/\(iid)")!)
    }

    private func makeJob(run: ForgeRun, jobID: String = "j-build-2",
                     name: String = "build", status: ForgeRunStatus = .failed) -> ForgeJob {
        ForgeJob(run: run, jobID: jobID, name: name, stage: "build", status: status,
                 attempt: 1, allowFailure: false, failureReason: nil,
                 startedAt: nil, finishedAt: nil, runnerName: nil,
                 webURL: run.webURL)
    }

    private func queryItems(in url: String) throws -> [URLQueryItem] {
        try XCTUnwrap(URLComponents(string: url)).queryItems ?? []
    }

    private func pipelineRow(iid: Int, status: String,
                             ref: String = "refs/heads/main",
                             htmlURL: String? = nil,
                             finishedAt: String? = nil) -> String {
        let finished = finishedAt.map { #""finished_at":"\#($0)","# } ?? ""
        let link = htmlURL.map { #""html_url":"\#($0)","# } ?? ""
        return """
        {"iid":\(iid),"sha":"sha-\(iid)","ref":"\(ref)","status":"\(status)",\
        "source":"push","author_username":"octo",\
        "workflow_path":".github/workflows/ci.yml",\(link)\(finished)\
        "created_at":"2026-11-03T10:00:00Z","updated_at":"2026-11-03T10:05:00Z"}
        """
    }
}

// MARK: - Runs

extension ForgeRunsTests {
    func testGitboyRunsPageMapsStatusesAndStripsTheBranchRef() async throws {
        let words: [(String, ForgeRunStatus)] = [
            ("created", .queued), ("queued", .queued), ("pending", .queued), ("claimed", .queued),
            ("running", .running), ("success", .success), ("failed", .failed), ("error", .failed),
            ("canceled", .canceled), ("cancelled", .canceled), ("skipped", .skipped),
            ("blocked", .waiting), ("manual", .waiting), ("waiting", .waiting),
        ]
        let rows = words.enumerated()
            .map { pipelineRow(iid: $0.offset + 1, status: $0.element.0) }
            .joined(separator: ",")
        StubURLProtocol.stub("repos/octo/app/pipelines", status: 200,
                             body: #"{"items":[\#(rows)],"next_cursor":"cursor-2"}"#)

        let page = try await makeGitboy().runs(in: gitboyRepo(), branch: "main", cursor: "cursor-1")

        XCTAssertEqual(page.next, "cursor-2")
        XCTAssertEqual(page.items.map(\.status), words.map { $0.1 })
        XCTAssertEqual(page.items.map(\.runID), (1...words.count).map { String($0) })

        let first = try XCTUnwrap(page.items.first)
        XCTAssertEqual(first.id, "gitboy:gitboy.example.com/octo/app/run/1")
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.title, "Pipeline #1")
        XCTAssertEqual(first.workflow, ".github/workflows/ci.yml")
        XCTAssertEqual(first.branch, "main", "refs/heads/ is stripped")
        XCTAssertEqual(first.sha, "sha-1")
        XCTAssertEqual(first.event, "push")
        XCTAssertEqual(first.actor, "octo")
        XCTAssertEqual(first.createdAt, ISO8601Dates.parse("2026-11-03T10:00:00Z"))
        XCTAssertEqual(first.updatedAt, ISO8601Dates.parse("2026-11-03T10:05:00Z"))
        XCTAssertEqual(first.webURL.absoluteString,
                       "https://gitboy.example.com/octo/app/pipelines/1")

        let items = try queryItems(in: try XCTUnwrap(StubURLProtocol.requests.last?.url))
        XCTAssertEqual(items.first { $0.name == "paginated" }?.value, "true")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "30")
        XCTAssertEqual(items.first { $0.name == "branch" }?.value, "main")
        XCTAssertEqual(items.first { $0.name == "cursor" }?.value, "cursor-1")
    }

    func testGitboyRunsPreferTheServerLinkAndTheFinishTime() async throws {
        let row = pipelineRow(iid: 9, status: "success", ref: "refs/heads/fix/sync",
                              htmlURL: "https://gitboy.example.com/octo/app/pipelines/9",
                              finishedAt: "2026-11-03T10:09:00Z")
        StubURLProtocol.stub("repos/octo/app/pipelines", status: 200,
                             body: #"{"items":[\#(row)],"next_cursor":null}"#)

        let page = try await makeGitboy().runs(in: gitboyRepo(), branch: nil, cursor: nil)

        let only = try XCTUnwrap(page.items.first)
        XCTAssertEqual(only.branch, "fix/sync")
        XCTAssertEqual(only.webURL.absoluteString, "https://gitboy.example.com/octo/app/pipelines/9")
        XCTAssertEqual(only.updatedAt, ISO8601Dates.parse("2026-11-03T10:09:00Z"))
        XCTAssertNil(page.next, "a null cursor is the last page")

        let items = try queryItems(in: try XCTUnwrap(StubURLProtocol.requests.last?.url))
        XCTAssertFalse(items.contains { $0.name == "branch" })
        XCTAssertFalse(items.contains { $0.name == "cursor" })
    }
}

// MARK: - Run detail

extension ForgeRunsTests {
    private var detailJSON: String {
        """
        {"iid":7,"sha":"sha-7","ref":"refs/heads/main","status":"failed","source":"push",
         "author_username":"octo","workflow_path":".github/workflows/ci.yml",
         "created_at":"2026-11-03T10:00:00Z","finished_at":"2026-11-03T10:09:00Z",
         "html_url":"https://gitboy.example.com/octo/app/pipelines/7",
         "stages":["build","test","deploy"],
         "jobs":[
           {"id":"j-deploy","name":"deploy","stage":"deploy","status":"skipped","attempt":1,
            "allow_failure":false,"started_at":null,"finished_at":null,"runner_name":null},
           {"id":"j-lint","name":"lint","stage":"test","status":"success","attempt":1,
            "allow_failure":true,"started_at":"2026-11-03T10:02:00Z",
            "finished_at":"2026-11-03T10:03:00Z","runner_name":"runner-1"},
           {"id":"j-build-1","name":"build","stage":"build","status":"success","attempt":1,
            "allow_failure":false,"started_at":"2026-11-03T10:00:30Z",
            "finished_at":"2026-11-03T10:01:00Z","runner_name":"runner-1"},
           {"id":"j-build-2","name":"build","stage":"build","status":"failed","attempt":2,
            "allow_failure":false,"failure_reason":"script_failure",
            "started_at":"2026-11-03T10:01:10Z","finished_at":"2026-11-03T10:02:00Z",
            "runner_name":"runner-2"},
           {"id":"j-audit","name":"audit","stage":"nightly","status":"waiting","attempt":1,
            "allow_failure":true,"started_at":null,"finished_at":null}
         ]}
        """
    }

    func testGitboyRunDetailKeepsTheNewestAttemptInStageOrder() async throws {
        StubURLProtocol.stub("pipelines/7", status: 200, body: detailJSON)

        let detail = try await makeGitboy().run(in: gitboyRepo(), id: "7")

        XCTAssertEqual(detail.jobs.map(\.name), ["build", "lint", "deploy", "audit"],
                       "stage order, then name; a stage the pipeline does not list sorts last")
        XCTAssertEqual(detail.jobs.map(\.jobID), ["j-build-2", "j-lint", "j-deploy", "j-audit"])
        XCTAssertEqual(detail.jobs.map(\.status), [.failed, .success, .skipped, .waiting])

        let build = try XCTUnwrap(detail.jobs.first)
        XCTAssertEqual(build.attempt, 2, "the older attempt of build is dropped")
        XCTAssertEqual(build.stage, "build")
        XCTAssertEqual(build.failureReason, "script_failure")
        XCTAssertFalse(build.allowFailure)
        XCTAssertEqual(build.runnerName, "runner-2")
        XCTAssertEqual(build.startedAt, ISO8601Dates.parse("2026-11-03T10:01:10Z"))
        XCTAssertEqual(build.finishedAt, ISO8601Dates.parse("2026-11-03T10:02:00Z"))
        XCTAssertEqual(build.id, "gitboy:gitboy.example.com/octo/app/run/7/job/j-build-2")
        XCTAssertEqual(build.webURL.absoluteString,
                       "https://gitboy.example.com/octo/app/pipelines/7?job=j-build-2")

        XCTAssertEqual(detail.run.title, "Pipeline #7")
        XCTAssertEqual(detail.run.branch, "main")
        XCTAssertFalse(detail.canRerunAll, "gitboy has no whole-run re-run")
        XCTAssertTrue(detail.canRetryFailed, "the newest build failed")
        XCTAssertFalse(detail.canCancel, "a failed pipeline is terminal")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/pipelines/7")
    }

    func testGitboyRunDetailCanCancelARunningPipeline() async throws {
        StubURLProtocol.stub("pipelines/8", status: 200, body: """
        {"iid":8,"sha":"sha-8","ref":"refs/heads/main","status":"running","source":"push",
         "stages":["build"],
         "jobs":[{"id":"j-8","name":"build","stage":"build","status":"running","attempt":1,
                  "allow_failure":false}]}
        """)

        let detail = try await makeGitboy().run(in: gitboyRepo(), id: "8")

        XCTAssertTrue(detail.canCancel)
        XCTAssertFalse(detail.canRetryFailed)
        XCTAssertEqual(detail.jobs.map(\.status), [.running])
        XCTAssertEqual(detail.jobs.first?.webURL.absoluteString,
                       "https://gitboy.example.com/octo/app/pipelines/8?job=j-8")
    }
}

// MARK: - Actions

extension ForgeRunsTests {
    func testGitboyRunActionsPostToTheirEndpoints() async throws {
        StubURLProtocol.stub("pipelines/7/retry-failed", status: 201, body: "[]")
        StubURLProtocol.stub("pipelines/7/cancel", status: 200,
                             body: #"{"status":"cancel_requested"}"#)
        let client = makeGitboy()

        try await client.perform(.retryFailed, on: makeRun())
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/pipelines/7/retry-failed")

        try await client.perform(.cancel, on: makeRun(status: .running))
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/pipelines/7/cancel")
    }

    func testGitboyRerunAllIsUnsupported() async {
        do {
            try await makeGitboy().perform(.rerunAll, on: makeRun())
            XCTFail("expected gitboy to refuse a whole-run re-run")
        } catch {
            XCTAssertEqual(error as? ForgeError,
                           .server(status: 0, message: "gitboy can't re-run a whole pipeline."))
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "an unsupported action sends nothing")
    }

    func testGitboyJobActionsPostToTheirEndpoints() async throws {
        StubURLProtocol.stub("jobs/j-build-2/retry", status: 201, body: "{}")
        StubURLProtocol.stub("jobs/j-build-2/cancel", status: 200,
                             body: #"{"status":"cancel_requested"}"#)
        StubURLProtocol.stub("jobs/j-build-2/play", status: 200, body: #"{"status":"queued"}"#)
        let client = makeGitboy()
        let build = makeJob(run: makeRun())

        try await client.perform(.retry, on: build)
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/jobs/j-build-2/retry")

        try await client.perform(.cancel, on: build)
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/jobs/j-build-2/cancel")

        try await client.perform(.play, on: makeJob(run: makeRun(status: .waiting), status: .waiting))
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/jobs/j-build-2/play")
    }
}

// MARK: - Logs

extension ForgeRunsTests {
    func testGitboyLogReadsPlainTextWithTheBearerToken() async throws {
        ForgeHeaderRecorder.reset(status: 200, body: "line 1\nline 2\n")
        let client = GitboyClient(host: .testGitboy, token: "gb-secret",
                                  session: ForgeHeaderRecorder.session())

        let text = try await client.log(of: makeJob(run: makeRun()))

        XCTAssertEqual(text, "line 1\nline 2\n")
        let request = try XCTUnwrap(ForgeHeaderRecorder.requests.last)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.accept, "text/plain")
        XCTAssertEqual(request.authorization, "Bearer gb-secret")
        XCTAssertEqual(request.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/jobs/j-build-2/log")
    }

    func testLogStreamParserYieldsTextThenFinished() throws {
        // Two log chunks and a done event, with a keepalive comment between
        // them: the comment must not become a chunk.
        let stream = """
        : connected

        event: log
        id: 6
        data: {"offset":0,"text":"Hello "}

        : keepalive

        event: log
        id: 13
        data: {"offset":6,"text":"world\\n"}

        event: done
        data: {"status":"success"}


        """
        var parser = ForgeSSEParser()
        var events: [ForgeLogEvent] = []
        for byte in Array(stream.utf8) {
            guard let event = try parser.feed(byte) else { continue }
            guard let decoded = try ForgeLogStreamEvent(event) else { continue }
            switch decoded {
            case .chunk(_, _, let text):
                events.append(.text(text))
            case .done(let status):
                events.append(.finished(GitboyClient.runStatus(status)))
            }
        }

        XCTAssertEqual(events, [.text("Hello "), .text("world\n"), .finished(.success)])
    }

    func testSSEParserFinishFlushesAnEventWithNoDispatchingBlankLine() throws {
        // A server that closes right after its last event leaves the final
        // `data:` line undelivered until the reader flushes the parser.
        let text = "event: done\ndata: {\"status\":\"failed\"}"
        var parser = ForgeSSEParser()
        var events: [ForgeSSEEvent] = []
        for byte in Array(text.utf8) {
            guard let event = try parser.feed(byte) else { continue }
            events.append(event)
        }
        XCTAssertTrue(events.isEmpty, "no blank line has dispatched an event yet")

        XCTAssertEqual(try parser.finish(),
                       ForgeSSEEvent(event: "done", id: nil, data: #"{"status":"failed"}"#))
        XCTAssertTrue(try parser.finish() == nil, "nothing is left to flush after the event is taken")
    }

    func testGitboyLiveLogStreamsFromTheRepoScopedPath() async throws {
        // The body ends right after `done`, with no trailing blank line: the
        // reader's flush still has to finish the stream.
        ForgeHeaderRecorder.reset(status: 200, body: """
        : connected

        event: log
        id: 6
        data: {"offset":0,"text":"Hello "}

        event: done
        data: {"status":"success"}
        """)
        let client = GitboyClient(host: .testGitboy, token: "gb-secret",
                                  session: ForgeHeaderRecorder.session())

        var events: [ForgeLogEvent] = []
        for try await event in client.liveLog(of: makeJob(run: makeRun())) {
            events.append(event)
        }

        XCTAssertEqual(events, [.text("Hello "), .finished(.success)])
        let request = try XCTUnwrap(ForgeHeaderRecorder.requests.last)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.accept, "text/event-stream")
        XCTAssertEqual(request.authorization, "Bearer gb-secret")
        XCTAssertEqual(request.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/jobs/j-build-2/log/stream")
    }

    func testLogTrimKeepsTheTailAndMarksTheCut() {
        let text = "start " + String(repeating: "x", count: 100) + " end"
        XCTAssertEqual(ForgeLogTrim.lastBytes(text, limit: 10_000), text,
                       "a log inside the limit is returned untouched")

        let trimmed = ForgeLogTrim.lastBytes(text, limit: 8)
        XCTAssertEqual(trimmed, ForgeLogTrim.trimmedPrefix + "xxxx end")
        XCTAssertEqual(ForgeLogTrim.lastBytes("abc", limit: 0), ForgeLogTrim.trimmedPrefix)
    }

    func testLogTrimNeverSplitsAMultiByteCharacter() {
        // Three two-byte "é"; a three-byte tail starts inside the second one.
        let trimmed = ForgeLogTrim.lastBytes("ééé", limit: 3)

        XCTAssertEqual(trimmed, ForgeLogTrim.trimmedPrefix + "é")
        XCTAssertFalse(trimmed.contains("\u{FFFD}"), trimmed)
    }

    func testRunStatusTerminalSet() {
        for status in [ForgeRunStatus.success, .failed, .canceled, .skipped] {
            XCTAssertTrue(status.isTerminal, status.rawValue)
        }
        for status in [ForgeRunStatus.queued, .running, .waiting] {
            XCTAssertFalse(status.isTerminal, status.rawValue)
        }
    }
}
