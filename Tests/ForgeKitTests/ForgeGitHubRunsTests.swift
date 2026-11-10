import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ForgeKit

/// GitHub Actions through the forge layer: run paging and status mapping, the
/// detail's job list, the four action endpoints GitHub actually has, and the
/// job-log redirect that must not carry the token to another host.
final class ForgeGitHubRunsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func repo() -> ForgeRepo {
        ForgeRepo(host: .github, owner: "octo", name: "app", description: nil,
                  isPrivate: false, defaultBranch: "main", isArchived: false,
                  updatedAt: nil,
                  webURL: URL(string: "https://github.com/octo/app")!)
    }

    private func makeForge() -> GitHubForge {
        GitHubForge(client: GitHubHTTPTransport(session: StubURLProtocol.session(), token: "test-token"))
    }

    private func run(id: String = "77", status: ForgeRunStatus = .failed) -> ForgeRun {
        ForgeRun(repo: repo(), runID: id, number: 7, title: "CI", workflow: "CI",
                 branch: "main", sha: "sha", event: "push", actor: "octo",
                 status: status, createdAt: nil, updatedAt: nil,
                 webURL: URL(string: "https://github.com/octo/app/actions/runs/\(id)")!)
    }

    private func job(run: ForgeRun, jobID: String = "901") -> ForgeJob {
        ForgeJob(run: run, jobID: jobID, name: "test", stage: nil, status: .failed,
                 attempt: 1, allowFailure: false, failureReason: nil,
                 startedAt: nil, finishedAt: nil, runnerName: nil,
                 webURL: run.webURL)
    }

    /// One workflow run as the API sends it; only what a case cares about varies.
    private func runJSON(id: Int, status: String, conclusion: String? = nil,
                         displayTitle: String? = nil, branch: String = "main") -> String {
        let conclusionValue = conclusion.map { "\"\($0)\"" } ?? "null"
        let titleValue = displayTitle.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":\(id),"run_number":\(id),"name":"CI","display_title":\(titleValue),
         "head_branch":"\(branch)","head_sha":"sha-\(id)","event":"push",
         "actor":{"login":"octo"},"status":"\(status)","conclusion":\(conclusionValue),
         "created_at":"2026-11-03T09:00:00Z","updated_at":"2026-11-03T09:10:00Z",
         "html_url":"https://github.com/octo/app/actions/runs/\(id)"}
        """
    }

    private func runsPage(_ rows: [String]) -> String {
        "{\"workflow_runs\":[" + rows.joined(separator: ",") + "]}"
    }

    private func jobsPage(_ rows: [String]) -> String {
        #"{"total_count":\#(rows.count),"jobs":["# + rows.joined(separator: ",") + "]}"
    }

    private func jobJSON(id: Int, name: String = "test", attempt: Int = 1,
                         status: String = "completed", conclusion: String = "success") -> String {
        """
        {"id":\(id),"run_attempt":\(attempt),"name":"\(name)","status":"\(status)",\
        "conclusion":"\(conclusion)","runner_name":"ubuntu-latest",\
        "html_url":"https://github.com/octo/app/actions/runs/77/job/\(id)"}
        """
    }
}

// MARK: - Runs list

extension ForgeGitHubRunsTests {
    func testRunsMapBothWordsAndKeepTheDisplayTitle() async throws {
        StubURLProtocol.stub("actions/runs?", status: 200, body: runsPage([
            runJSON(id: 12, status: "completed", conclusion: "failure", displayTitle: "Fix the build"),
            runJSON(id: 11, status: "completed", conclusion: "success"),
        ]))

        let page = try await makeForge().runs(in: repo(), branch: nil, cursor: nil)

        XCTAssertNil(page.next)
        let first = try XCTUnwrap(page.items.first)
        XCTAssertEqual(first.runID, "12")
        XCTAssertEqual(first.number, 12)
        XCTAssertEqual(first.title, "Fix the build")
        XCTAssertEqual(first.workflow, "CI")
        XCTAssertEqual(first.branch, "main")
        XCTAssertEqual(first.sha, "sha-12")
        XCTAssertEqual(first.event, "push")
        XCTAssertEqual(first.actor, "octo")
        XCTAssertEqual(first.status, .failed)
        XCTAssertEqual(first.createdAt, ISO8601Dates.parse("2026-11-03T09:00:00Z"))
        XCTAssertEqual(first.webURL.absoluteString, "https://github.com/octo/app/actions/runs/12")
        XCTAssertEqual(first.id, "github:github.com/octo/app/run/12")
        // No display title: the workflow name is the title.
        XCTAssertEqual(page.items[1].title, "CI")
    }

    /// Every status/conclusion pair the contract names, in one page: the run
    /// list is where the two-word GitHub outcome becomes one word.
    func testEveryRunStatusAndConclusionMapsToOneWord() async throws {
        let table: [(String, String?, ForgeRunStatus)] = [
            ("queued", nil, .queued),
            ("requested", nil, .queued),
            ("pending", nil, .queued),
            ("waiting", nil, .waiting),
            ("in_progress", nil, .running),
            ("completed", "success", .success),
            ("completed", "failure", .failed),
            ("completed", "timed_out", .failed),
            ("completed", "startup_failure", .failed),
            ("completed", "cancelled", .canceled),
            ("completed", "skipped", .skipped),
            ("completed", "neutral", .skipped),
            ("completed", "action_required", .waiting),
            ("completed", "stale", .failed),
        ]
        let rows = table.enumerated().map { index, row in
            runJSON(id: index + 1, status: row.0, conclusion: row.1)
        }
        StubURLProtocol.stub("actions/runs?", status: 200, body: runsPage(rows))

        let page = try await makeForge().runs(in: repo(), branch: nil, cursor: nil)

        XCTAssertEqual(page.items.map(\.status), table.map { $0.2 })
        XCTAssertEqual(page.items.filter { $0.status.isTerminal }.count, 8,
                       "Only a completed run's success/failure/cancel/skip is terminal")
    }

    func testRunsPageByPageNumberAndFilterByBranch() async throws {
        let rows = (1...30).map { runJSON(id: $0, status: "completed", conclusion: "success") }
        StubURLProtocol.stub("actions/runs?", status: 200, body: runsPage(rows))

        let page = try await makeForge().runs(in: repo(), branch: "release/1.0", cursor: "3")

        XCTAssertEqual(page.next, "4", "A full page means another is behind it")
        let url = try XCTUnwrap(StubURLProtocol.requests.last?.url)
        XCTAssertTrue(url.contains("per_page=30"), url)
        XCTAssertTrue(url.contains("page=3"), url)
        XCTAssertTrue(url.contains("branch=release%2F1.0"), url)

        StubURLProtocol.reset()
        StubURLProtocol.stub("actions/runs?", status: 200,
                             body: runsPage([runJSON(id: 1, status: "queued")]))
        let short = try await makeForge().runs(in: repo(), branch: nil, cursor: nil)
        XCTAssertNil(short.next, "A short page is the end")
        XCTAssertFalse(try XCTUnwrap(StubURLProtocol.requests.last?.url).contains("branch="))
    }
}

// MARK: - Run detail

extension ForgeGitHubRunsTests {
    func testRunDetailKeepsEveryJobAndNeverKeysByName() async throws {
        StubURLProtocol.stub("actions/runs/77/jobs", status: 200, body: """
        {"total_count":3,"jobs":[
          {"id":902,"run_attempt":1,"name":"test","status":"completed","conclusion":"success",
           "started_at":"2026-11-03T09:01:00Z","completed_at":"2026-11-03T09:02:00Z",
           "runner_name":"ubuntu-latest",
           "html_url":"https://github.com/octo/app/actions/runs/77/job/902"},
          {"id":901,"run_attempt":1,"name":"test","status":"completed","conclusion":"failure",
           "started_at":"2026-11-03T09:00:00Z","completed_at":"2026-11-03T09:00:30Z",
           "runner_name":"ubuntu-latest",
           "html_url":"https://github.com/octo/app/actions/runs/77/job/901"},
          {"id":903,"run_attempt":1,"name":"build","status":"completed","conclusion":"failure",
           "html_url":"https://github.com/octo/app/actions/runs/77/job/903"}
        ]}
        """)
        StubURLProtocol.stub("actions/runs/77", status: 200, body: runJSON(id: 77, status: "completed",
                                                                         conclusion: "failure"))

        let detail = try await makeForge().run(in: repo(), id: "77")

        XCTAssertEqual(detail.run.status, .failed)
        // Two matrix jobs share the display name "test": both are jobs and both
        // are kept. The order is (name, job id), never the JSON order.
        XCTAssertEqual(detail.jobs.map(\.name), ["build", "test", "test"])
        XCTAssertEqual(detail.jobs.map(\.jobID), ["903", "901", "902"])
        XCTAssertEqual(detail.jobs.last?.status, .success)
        XCTAssertEqual(detail.jobs.last?.runnerName, "ubuntu-latest")
        XCTAssertNil(detail.jobs.last?.stage, "GitHub has no stages")
        XCTAssertEqual(detail.jobs.last?.webURL.absoluteString,
                       "https://github.com/octo/app/actions/runs/77/job/902")
        XCTAssertTrue(detail.canRerunAll)
        XCTAssertTrue(detail.canRetryFailed)
        XCTAssertFalse(detail.canCancel)
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.url.contains("filter=latest") },
                      "Only the newest attempt of each job name is asked for")
    }

    func testOneJobArrivingTwiceIsListedOnce() {
        let run = self.run(id: "77")
        let rows = [
            GitHubJobDTO(id: 2, name: "test", status: "completed", conclusion: "success",
                         startedAt: nil, completedAt: nil, runnerName: nil, htmlURL: nil,
                         runAttempt: 1),
            GitHubJobDTO(id: 1, name: "test", status: "completed", conclusion: "failure",
                         startedAt: nil, completedAt: nil, runnerName: nil, htmlURL: nil,
                         runAttempt: 1),
            // The same job id again (an overlapping page): still one job.
            GitHubJobDTO(id: 2, name: "test", status: "completed", conclusion: "success",
                         startedAt: nil, completedAt: nil, runnerName: nil, htmlURL: nil,
                         runAttempt: 1),
        ]

        let jobs = GitHubForge.forgeJobs(rows, run: run)

        XCTAssertEqual(jobs.map(\.jobID), ["1", "2"], "Deduped by job id, sorted by (name, id)")
    }

    func testRunDetailReadsEveryPageOfJobs() async throws {
        StubURLProtocol.stub("actions/runs/79/jobs", status: 200, body: jobsPage(
            (1...100).map { jobJSON(id: 1_000 + $0) }))
        StubURLProtocol.stub("actions/runs/79/jobs", status: 200, body: jobsPage(
            [jobJSON(id: 2_000, name: "zz-last")]))
        StubURLProtocol.stub("actions/runs/79", status: 200,
                             body: runJSON(id: 79, status: "in_progress"))

        let detail = try await makeForge().run(in: repo(), id: "79")

        XCTAssertEqual(detail.jobs.count, 101, "A run with more than 100 jobs keeps them all")
        XCTAssertEqual(detail.jobs.last?.name, "zz-last", "The job behind the first page is listed")
        XCTAssertEqual(StubURLProtocol.requests.map(\.url).filter { $0.contains("/jobs") }, [
            "https://api.github.com/repos/octo/app/actions/runs/79/jobs?per_page=100&filter=latest",
            "https://api.github.com/repos/octo/app/actions/runs/79/jobs?per_page=100&filter=latest&page=2",
        ])
    }

    func testARunningRunCanBeCanceledButNotRerun() async throws {
        StubURLProtocol.stub("actions/runs/78/jobs", status: 200, body: #"""
        {"jobs":[{"id":911,"run_attempt":1,"name":"test","status":"in_progress","conclusion":null}]}
        """#)
        StubURLProtocol.stub("actions/runs/78", status: 200, body: runJSON(id: 78, status: "in_progress"))

        let detail = try await makeForge().run(in: repo(), id: "78")

        XCTAssertEqual(detail.run.status, .running)
        XCTAssertEqual(detail.jobs.first?.status, .running)
        XCTAssertFalse(detail.canRerunAll)
        XCTAssertFalse(detail.canRetryFailed)
        XCTAssertTrue(detail.canCancel)
    }
}

// MARK: - Actions

extension ForgeGitHubRunsTests {
    func testEverySupportedActionHitsItsEndpoint() async throws {
        for route in ["rerun-failed-jobs", "rerun", "cancel"] {
            StubURLProtocol.stub("actions/runs/77/" + route, status: 201, body: "{}")
        }
        StubURLProtocol.stub("actions/jobs/901/rerun", status: 201, body: "{}")

        let forge = makeForge()
        let run = self.run(id: "77")
        try await forge.perform(.rerunAll, on: run)
        try await forge.perform(.retryFailed, on: run)
        try await forge.perform(.cancel, on: run)
        try await forge.perform(.retry, on: job(run: run, jobID: "901"))

        XCTAssertEqual(StubURLProtocol.requests.map { $0.method }, ["POST", "POST", "POST", "POST"])
        XCTAssertEqual(StubURLProtocol.requests.map(\.url), [
            "https://api.github.com/repos/octo/app/actions/runs/77/rerun",
            "https://api.github.com/repos/octo/app/actions/runs/77/rerun-failed-jobs",
            "https://api.github.com/repos/octo/app/actions/runs/77/cancel",
            "https://api.github.com/repos/octo/app/actions/jobs/901/rerun",
        ])
    }

    func testJobCancelAndPlayAreRefusedWithoutARequest() async {
        let forge = makeForge()
        for action in [ForgeJobAction.cancel, .play] {
            do {
                try await forge.perform(action, on: job(run: run(), jobID: "901"))
                XCTFail("\(action) should not be supported on GitHub")
            } catch let error as ForgeError {
                guard case let .server(status, message) = error else {
                    return XCTFail("Expected an unsupported-action error, got \(error)")
                }
                XCTAssertEqual(status, 0)
                XCTAssertTrue(message.hasPrefix("GitHub can't "), message)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty,
                      "An unsupported action must not touch the network")
    }
}

// MARK: - Logs

extension ForgeGitHubRunsTests {
    private func logRedirect(_ location: String) {
        StubURLProtocol.stub("actions/jobs/901/logs", status: 302,
                             headers: ["Location": location], body: "", redirect: true)
    }

    /// swift-corelibs-foundation traps when a URLProtocol answers with a
    /// redirect, so the job-log redirect tests run on Apple platforms only.
    private func skipWithoutRedirectStubs() throws {
        #if canImport(FoundationNetworking)
        throw XCTSkip("URLProtocol redirects cannot be stubbed on Linux")
        #endif
    }

    /// The 302 that answers a job-log read points at a signed blob on another
    /// host. The token must stop at api.github.com, and the second request must
    /// be a plain GET of the Location.
    func testLogFollowsTheSignedLocationWithoutTheToken() async throws {
        try skipWithoutRedirectStubs()
        let blob = "https://objects.githubusercontent.com/signed/9001.log?token=abc"
        logRedirect(blob)
        StubURLProtocol.stub("objects.githubusercontent.com/signed/9001.log", status: 200,
                             body: "step 1\nstep 2\nDone\n")

        let text = try await makeForge().log(of: job(run: run(id: "77"), jobID: "901"))

        XCTAssertEqual(text, "step 1\nstep 2\nDone\n")
        XCTAssertEqual(StubURLProtocol.requests.map(\.url), [
            "https://api.github.com/repos/octo/app/actions/jobs/901/logs",
            blob,
        ])
        XCTAssertEqual(StubURLProtocol.headers.count, 2)
        XCTAssertEqual(StubURLProtocol.headers.first?["Authorization"], "Bearer test-token",
                       "The API hop is authenticated")
        XCTAssertNil(StubURLProtocol.headers.last?["Authorization"],
                     "The signed blob URL is the whole grant: no token may ride along")
    }

    func testANonHTTPSLogLocationIsRefused() async throws {
        try skipWithoutRedirectStubs()
        logRedirect("http://objects.example.com/9001.log")
        do {
            _ = try await makeForge().log(of: job(run: run(id: "77"), jobID: "901"))
            XCTFail("A plain-http log location must not be followed")
        } catch let error as GitHubError {
            guard case .invalidResponse = error else {
                return XCTFail("Expected the location to be rejected, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1,
                       "Nothing is sent to the refused location")
    }

    func testLogKeepsOnlyTheLastBytesOfALongLog() async throws {
        try skipWithoutRedirectStubs()
        let blob = "https://objects.githubusercontent.com/signed/huge.log"
        logRedirect(blob)
        let body = String(repeating: "0123456789", count: 60_000) + "THE END"
        StubURLProtocol.stub("objects.githubusercontent.com/signed/huge.log", status: 200, body: body)

        let text = try await makeForge().log(of: job(run: run(id: "77"), jobID: "901"))

        XCTAssertTrue(text.hasSuffix("THE END"))
        XCTAssertTrue(text.hasPrefix("… earlier output trimmed\n"),
                      String(text.prefix(40)))
        XCTAssertLessThan(text.utf8.count, body.utf8.count)
    }
}
