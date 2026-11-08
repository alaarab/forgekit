import XCTest
@testable import ForgeKit

/// Runner fleets over both forges: gitboy's heartbeat-window status and live
/// job rows, GitHub's admin-only list that knows neither.
final class ForgeRunnersTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeGitboy() -> GitboyClient {
        GitboyClient(host: .testGitboy, token: "test-token", session: StubURLProtocol.session())
    }

    private func makeGitHub() -> GitHubForge {
        GitHubForge(client: GitHubHTTPTransport(session: StubURLProtocol.session(), token: "test-token"))
    }

    private func gitboyJob() -> ForgeRunnerJob {
        ForgeRunnerJob(jobID: "j1", name: "test", status: "running", repository: "octo/app",
                       runNumber: 42,
                       startedAt: ISO8601Dates.parse("2026-11-03T11:59:00Z"),
                       webURL: URL(string: "https://gitboy.example.com/octo/app/pipelines/42?job=j1")!)
    }

    private func gitboyRunner(scope: ForgeRunnerScope = .mine) -> ForgeRunner {
        ForgeRunner(host: .testGitboy, scope: scope, runnerID: "r1", name: "mini",
                    labels: ["macos", "xcode"], isOnline: true, isPaused: false, isBusy: true,
                    lastSeenAt: ISO8601Dates.parse("2026-11-03T11:59:00Z"), version: "1.2.0",
                    os: "mini.local", capacity: 4, isEphemeral: false,
                    currentJobs: [gitboyJob()])
    }

    private func githubRunner(scope: ForgeRunnerScope) -> ForgeRunner {
        ForgeRunner(host: .github, scope: scope, runnerID: "7", name: "mac-mini",
                    labels: ["self-hosted"], isOnline: true, isPaused: false, isBusy: false,
                    lastSeenAt: nil, version: nil, os: "macOS", capacity: nil,
                    isEphemeral: false, currentJobs: [])
    }

    private func decodeRunnerDTO(_ json: String) throws -> GitboyRunnerDTO {
        try JSONDecoder().decode(GitboyRunnerDTO.self, from: Data(json.utf8))
    }
}

// MARK: - gitboy

extension ForgeRunnersTests {
    func testGitboyMineListMapsFreshnessPauseAndJobs() async throws {
        let fresh = ISO8601Dates.string(from: Date().addingTimeInterval(-30))
        let stale = ISO8601Dates.string(from: Date().addingTimeInterval(-600))
        StubURLProtocol.stub("user/runners", status: 200, body: """
        [
          {"id":"r1","name":"mini","labels":["macos","xcode"],"status":"online",
           "last_seen_at":"\(fresh)","version":"1.2.0","capacity":4,"host":"mini.local",
           "ephemeral":false,"busy":true,
           "current_jobs":[{"id":"j1","name":"test","status":"running",
             "started_at":"2026-11-03T11:59:00Z","pipeline_iid":42,"repository":"octo/app",
             "html_url":"https://gitboy.example.com/octo/app/pipelines/42?job=j1"}]},
          {"id":"r2","name":"old-box","labels":[],"status":"online",
           "last_seen_at":"\(stale)","version":null,"capacity":null,"host":null,
           "ephemeral":true,"busy":false,"current_jobs":[]},
          {"id":"r3","name":"paused-box","labels":["linux"],"status":"paused",
           "last_seen_at":"\(fresh)","busy":false,"current_jobs":[]}
        ]
        """)

        let runners = try await makeGitboy().runners(.mine)

        XCTAssertEqual(runners.map(\.runnerID), ["r1", "r2", "r3"])
        XCTAssertEqual(runners[0].id, "gitboy:gitboy.example.com/runner/r1")
        XCTAssertEqual(runners[0].scope, .mine)
        XCTAssertEqual(runners[0].host, .testGitboy)
        XCTAssertEqual(runners[0].labels, ["macos", "xcode"])
        XCTAssertTrue(runners[0].isOnline, "seen 30 s ago is online")
        XCTAssertFalse(runners[0].isPaused)
        XCTAssertTrue(runners[0].isBusy)
        XCTAssertEqual(runners[0].version, "1.2.0")
        XCTAssertEqual(runners[0].capacity, 4)
        XCTAssertEqual(runners[0].os, "mini.local")
        XCTAssertFalse(runners[0].isEphemeral)
        XCTAssertEqual(runners[0].currentJobs.map(\.jobID), ["j1"])
        XCTAssertEqual(runners[0].currentJobs[0].name, "test")
        XCTAssertEqual(runners[0].currentJobs[0].status, "running")
        XCTAssertEqual(runners[0].currentJobs[0].repository, "octo/app")
        XCTAssertEqual(runners[0].currentJobs[0].runNumber, 42)
        XCTAssertEqual(runners[0].currentJobs[0].startedAt,
                       ISO8601Dates.parse("2026-11-03T11:59:00Z"))
        XCTAssertEqual(runners[0].currentJobs[0].webURL?.absoluteString,
                       "https://gitboy.example.com/octo/app/pipelines/42?job=j1")

        XCTAssertFalse(runners[1].isOnline, "seen 10 minutes ago is stale")
        XCTAssertTrue(runners[1].isEphemeral)
        XCTAssertEqual(runners[1].currentJobs, [])

        XCTAssertTrue(runners[2].isPaused)
        XCTAssertEqual(runners[2].labels, ["linux"])

        XCTAssertEqual(StubURLProtocol.requests.last?.method, "GET")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/user/runners")
    }

    func testGitboyOnlineWindowReadsTheInjectedClock() throws {
        let fixed = try XCTUnwrap(ISO8601Dates.parse("2026-11-03T12:00:00Z"))
        let mapping = GitboyRunnerMapping(host: .testGitboy, scope: .mine, now: { fixed })

        let fresh = try decodeRunnerDTO("""
        {"id":"r1","name":"mini","status":"online","last_seen_at":"2026-11-03T11:58:30Z"}
        """)
        let edge = try decodeRunnerDTO("""
        {"id":"r2","name":"edge","status":"online","last_seen_at":"2026-11-03T11:58:00Z"}
        """)
        let stale = try decodeRunnerDTO("""
        {"id":"r3","name":"old","status":"online","last_seen_at":"2026-11-03T11:57:59Z"}
        """)
        let offline = try decodeRunnerDTO("""
        {"id":"r4","name":"off","status":"offline","last_seen_at":"2026-11-03T11:59:59Z"}
        """)

        XCTAssertTrue(try XCTUnwrap(mapping.runner(from: fresh)).isOnline)
        XCTAssertTrue(try XCTUnwrap(mapping.runner(from: edge)).isOnline, "exactly 120 s is still online")
        XCTAssertFalse(try XCTUnwrap(mapping.runner(from: stale)).isOnline)
        XCTAssertFalse(try XCTUnwrap(mapping.runner(from: offline)).isOnline,
                       "an offline status wins over a fresh heartbeat")
    }

    func testGitboyOrgAndRepoScopesUseTheirOwnPaths() async throws {
        StubURLProtocol.stub("orgs/acme/runners", status: 200, body: "[]")
        StubURLProtocol.stub("repos/octo/app/runners", status: 200, body: "[]")

        _ = try await makeGitboy().runners(.org("acme"))
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/orgs/acme/runners")

        _ = try await makeGitboy().runners(.repo(owner: "octo", name: "app"))
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/repos/octo/app/runners")
    }

    func testGitboySetPausedSendsStatusAndKeepsCurrentJobs() async throws {
        StubURLProtocol.stub("user/runners/r1", status: 200, body: """
        {"id":"r1","name":"mini","labels":["macos","xcode"],"ephemeral":false,
         "last_seen_at":"2026-01-01T00:00:00Z","version":"1.3.0","status":"paused"}
        """)
        StubURLProtocol.stub("user/runners/r1", status: 200, body: """
        {"id":"r1","name":"mini","labels":["macos","xcode"],"ephemeral":false,
         "last_seen_at":"\(ISO8601Dates.string(from: Date().addingTimeInterval(-10)))",
         "version":"1.3.0","status":"online"}
        """)

        let paused = try await makeGitboy().setPaused(true, runner: gitboyRunner())
        let resumed = try await makeGitboy().setPaused(false, runner: gitboyRunner())

        XCTAssertTrue(paused.isPaused)
        XCTAssertFalse(paused.isOnline, "an old heartbeat stays stale")
        XCTAssertEqual(paused.version, "1.3.0", "the answer wins")
        XCTAssertEqual(paused.capacity, 4, "the answer omits capacity")
        XCTAssertEqual(paused.os, "mini.local", "the answer omits the host")
        XCTAssertEqual(paused.labels, ["macos", "xcode"])
        XCTAssertTrue(paused.isBusy, "the answer omits busy")
        XCTAssertEqual(paused.currentJobs, [gitboyJob()], "the answer omits current jobs")

        XCTAssertFalse(resumed.isPaused)
        XCTAssertTrue(resumed.isOnline)
        XCTAssertEqual(resumed.currentJobs, [gitboyJob()])

        XCTAssertEqual(StubURLProtocol.requests.map { $0.method }, ["PATCH", "PATCH"])
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/user/runners/r1")
        XCTAssertEqual(StubURLProtocol.bodies, [
            #"{"status":"paused"}"#,
            #"{"status":"online"}"#,
        ])
    }

    func testGitboyRemoveDeletesTheRunner() async throws {
        StubURLProtocol.stub("user/runners/r1", status: 200, body: "{}")

        try await makeGitboy().remove(gitboyRunner())

        XCTAssertEqual(StubURLProtocol.requests.last?.method, "DELETE")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com/api/v1/user/runners/r1")
    }

    func testGitboyRunnerListNeedsWriteRepo() async {
        StubURLProtocol.stub("user/runners", status: 403,
                             body: #"{"error":"Token requires write:repo"}"#)

        do {
            _ = try await makeGitboy().runners(.mine)
            XCTFail("expected .missingScope for a 403 scope refusal")
        } catch {
            XCTAssertEqual(error as? ForgeError, .missingScope("write:repo"))
        }
    }
}

// MARK: - GitHub

extension ForgeRunnersTests {
    private var githubRepoScope: ForgeRunnerScope { .repo(owner: "octo", name: "app") }

    func testGitHubRepoListMapsRunnersAndLabels() async throws {
        StubURLProtocol.stub("repos/octo/app/actions/runners", status: 200, body: """
        {"total_count":2,"runners":[
          {"id":7,"name":"mac-mini","os":"macOS","status":"online","busy":true,
           "labels":[{"id":1,"name":"self-hosted","type":"read-only"},
                     {"id":2,"name":"macOS","type":"read-only"}]},
          {"id":8,"name":"old-box","os":"Linux","status":"offline","busy":false,
           "labels":[{"id":3,"name":"linux","type":"read-only"}]}
        ]}
        """)

        let runners = try await makeGitHub().runners(githubRepoScope)

        XCTAssertEqual(runners.map(\.runnerID), ["7", "8"])
        XCTAssertEqual(runners[0].id, "github:github.com/runner/7")
        XCTAssertEqual(runners[0].host, .github)
        XCTAssertEqual(runners[0].scope, githubRepoScope)
        XCTAssertEqual(runners[0].name, "mac-mini")
        XCTAssertEqual(runners[0].labels, ["self-hosted", "macOS"])
        XCTAssertEqual(runners[0].os, "macOS")
        XCTAssertTrue(runners[0].isOnline)
        XCTAssertTrue(runners[0].isBusy)
        XCTAssertFalse(runners[0].isPaused, "GitHub has no paused runners")
        XCTAssertFalse(runners[0].isEphemeral)
        XCTAssertNil(runners[0].lastSeenAt)
        XCTAssertEqual(runners[0].currentJobs, [], "GitHub never says")

        XCTAssertFalse(runners[1].isOnline)
        XCTAssertFalse(runners[1].isBusy)
        XCTAssertEqual(runners[1].labels, ["linux"])

        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://api.github.com/repos/octo/app/actions/runners?per_page=100")
    }

    func testGitHubOrgListUsesTheOrgPath() async throws {
        StubURLProtocol.stub("orgs/acme/actions/runners", status: 200,
                             body: #"{"total_count":0,"runners":[]}"#)

        let runners = try await makeGitHub().runners(.org("acme"))

        XCTAssertEqual(runners, [])
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://api.github.com/orgs/acme/actions/runners?per_page=100")
    }

    /// One page of the runner list JSON: `count` runners whose ids run from
    /// `start + 1`, all offline and idle so only their count matters here.
    private func githubRunnersJSON(count: Int, start: Int, total: Int) -> String {
        let rows = (1...max(1, count)).prefix(count).map { offset -> String in
            let id = start + offset
            return """
            {"id":\(id),"name":"runner-\(id)","os":"Linux","status":"offline","busy":false,\
            "labels":[{"id":1,"name":"linux","type":"read-only"}]}
            """
        }
        return #"{"total_count":\#(total),"runners":["# + rows.joined(separator: ",") + "]}"
    }

    func testGitHubRunnerFleetReadsEveryPageUpToItsTotal() async throws {
        StubURLProtocol.stub("repos/octo/app/actions/runners", status: 200,
                             body: githubRunnersJSON(count: 100, start: 0, total: 101))
        StubURLProtocol.stub("repos/octo/app/actions/runners", status: 200,
                             body: githubRunnersJSON(count: 1, start: 100, total: 101))

        let runners = try await makeGitHub().runners(githubRepoScope)

        XCTAssertEqual(runners.count, 101, "The fleet does not stop at the first page")
        XCTAssertEqual(runners.first?.runnerID, "1")
        XCTAssertEqual(runners.last?.runnerID, "101")
        XCTAssertEqual(StubURLProtocol.requests.map(\.url), [
            "https://api.github.com/repos/octo/app/actions/runners?per_page=100",
            "https://api.github.com/repos/octo/app/actions/runners?per_page=100&page=2",
        ])
    }

    func testGitHubAdminRefusalNamesAdminAccess() async {
        StubURLProtocol.stub("repos/octo/app/actions/runners", status: 403,
                             body: #"{"message":"Resource not accessible by integration"}"#)

        do {
            _ = try await makeGitHub().runners(githubRepoScope)
            XCTFail("expected .unauthorized for a runner list the token can't administer")
        } catch {
            XCTAssertEqual(error as? ForgeError,
                           .unauthorized("You need admin access to see this repository's runners."))
        }
    }

    func testGitHubMineIsNotAListableScope() async {
        do {
            _ = try await makeGitHub().runners(.mine)
            XCTFail("expected .server for GitHub's missing runner scope")
        } catch {
            XCTAssertEqual(error as? ForgeError,
                           .server(status: 0,
                                   message: "GitHub lists runners per repository or organization."))
        }
    }

    func testGitHubSetPausedIsRefused() async {
        do {
            _ = try await makeGitHub().setPaused(true, runner: githubRunner(scope: githubRepoScope))
            XCTFail("expected .server for GitHub's missing pause API")
        } catch {
            XCTAssertEqual(error as? ForgeError,
                           .server(status: 0, message: "GitHub runners can't be paused."))
        }
    }

    func testGitHubRemoveDeletesTheRunner() async throws {
        StubURLProtocol.stub("repos/octo/app/actions/runners/7", status: 204, body: "")

        try await makeGitHub().remove(githubRunner(scope: githubRepoScope))

        XCTAssertEqual(StubURLProtocol.requests.last?.method, "DELETE")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://api.github.com/repos/octo/app/actions/runners/7")
    }
}
