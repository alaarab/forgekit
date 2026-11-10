import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ForgeKit

/// Snapshot of one request a forge made. `StubURLProtocol` answers bodies but
/// keeps no headers, and the bearer token is one of the things under test.
final class ForgeHeaderRecorder: URLProtocol {
    struct Recorded: Equatable {
        let method: String
        let url: String
        let authorization: String?
        let accept: String?
        let contentType: String?
        let body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedRequests: [Recorded] = []
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var responseBody = "{}"

    static func reset(status: Int = 200, body: String = "{}") {
        lock.lock(); defer { lock.unlock() }
        recordedRequests = []
        self.status = status
        self.responseBody = body
    }

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForgeHeaderRecorder.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(Recorded(
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            accept: request.value(forHTTPHeaderField: "Accept"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: Self.bodyText(request)))
        let status = Self.status
        let payload = Self.responseBody
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyText(_ request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private func queryItems(in url: String) throws -> [URLQueryItem] {
    let components = try XCTUnwrap(URLComponents(string: url))
    return components.queryItems ?? []
}

// MARK: - Hosts

final class ForgeHostTests: XCTestCase {
    func testGitboyHostNormalizationAcceptsPlainAndPastedAddresses() throws {
        XCTAssertEqual(try ForgeHost.gitboy(domain: "gitboy.example.com").domain, "gitboy.example.com")
        XCTAssertEqual(try ForgeHost.gitboy(domain: " https://GitBoy.example.com/ ").domain, "gitboy.example.com")
        XCTAssertEqual(try ForgeHost.gitboy(domain: "https://gitboy.example.com").domain, "gitboy.example.com")
        XCTAssertEqual(try ForgeHost.gitboy(domain: "git.example.com:8443").domain, "git.example.com:8443")

        let pasted = try ForgeHost.gitboy(domain: " https://GitBoy.example.com/ ")
        XCTAssertEqual(pasted.kind, .gitboy)
        XCTAssertEqual(pasted.id, "gitboy:gitboy.example.com")
    }

    func testGitboyHostNormalizationRejectsAnythingButAHost() {
        for input in ["", "http://gitboy.example.com", "gitboy.example.com/x", "a@gitboy.example.com", "git boy.dev",
                      "gitboy.example.com?x=1", "gitboy.example.com#top", "gitboy.example.com:0", "gitboy.example.com:70000"] {
            XCTAssertThrowsError(try ForgeHost.gitboy(domain: input), input) { error in
                XCTAssertEqual(error as? ForgeError, .invalidHost, input)
            }
        }
    }

    func testKnownHostsExposeTheirBases() {
        XCTAssertEqual(ForgeHost.github.kind, .github)
        XCTAssertEqual(ForgeHost.github.domain, "github.com")
        XCTAssertEqual(ForgeHost.github.id, "github:github.com")
        XCTAssertEqual(ForgeHost.github.webBase.absoluteString, "https://github.com/")
        XCTAssertEqual(ForgeHost.github.apiBase.absoluteString, "https://api.github.com/")

        XCTAssertEqual(ForgeHost.testGitboy.kind, .gitboy)
        XCTAssertEqual(ForgeHost.testGitboy.webBase.absoluteString, "https://gitboy.example.com/")
        XCTAssertEqual(ForgeHost.testGitboy.apiBase.absoluteString, "https://gitboy.example.com/api/v1/")
    }

    func testHostWithPortKeepsItInBothBases() throws {
        let host = try ForgeHost.gitboy(domain: "git.example.com:8443")
        XCTAssertEqual(host.webBase.absoluteString, "https://git.example.com:8443/")
        XCTAssertEqual(host.apiBase.absoluteString, "https://git.example.com:8443/api/v1/")
    }

    /// `AgentSendLink` lives in the app and calls this directly, so its strict
    /// bare-host rule is public contract, not an implementation detail.
    func testBareHostValidationAcceptsOnlyAHostAndOptionalPort() {
        for input in ["git.example.com", "git.example.com:8443", "internal_host", "a-b.example.com"] {
            XCTAssertTrue(ForgeHost.isValidHost(input), input)
        }
        for input in ["", "https://git.example.com", "http://git.example.com",
                      "git.example.com/path", "git.example.com?x=1", "git.example.com#top",
                      "a@git.example.com", "git boy.example.com", "git.example.com:0",
                      "git.example.com:70000", "-git.example.com", "git-.example.com",
                      "git.example.com:http"] {
            XCTAssertFalse(ForgeHost.isValidHost(input), input)
        }
    }

    func testCapabilitiesDifferPerHost() {
        let gitboy = GitboyClient(host: .testGitboy, token: nil)
        XCTAssertEqual(gitboy.capabilities,
                       [.issues, .pipelines, .liveLogs, .retryFailed, .runners, .pauseRunners])
        XCTAssertFalse(gitboy.capabilities.contains(.rerunWholeRun))

        let github = GitHubForge(client: GitHubHTTPTransport(session: StubURLProtocol.session()))
        XCTAssertEqual(github.capabilities,
                       [.issues, .pipelines, .rerunWholeRun, .retryFailed, .runners])
        XCTAssertFalse(github.capabilities.contains(.liveLogs))
        XCTAssertFalse(github.capabilities.contains(.pauseRunners))
        XCTAssertEqual(github.host, .github)
    }
}

// MARK: - Gitboy client

final class GitboyClientTests: XCTestCase {
    private func makeClient(token: String? = "test-token") -> GitboyClient {
        GitboyClient(host: .testGitboy, token: token, session: StubURLProtocol.session())
    }

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

    func testCurrentUserDecodesProfileAndAvatar() async throws {
        StubURLProtocol.stub("api/v1/user", status: 200,
                             body: #"{"username":"octo","display_name":"Octo Cat"}"#)
        let user = try await makeClient().currentUser()
        XCTAssertEqual(user.login, "octo")
        XCTAssertEqual(user.displayName, "Octo Cat")
        XCTAssertEqual(user.avatarURL?.absoluteString, "https://gitboy.example.com/api/v1/users/octo/avatar")
        XCTAssertEqual(StubURLProtocol.requests.last?.url, "https://gitboy.example.com/api/v1/user")
    }

    func testRequestsCarryTheBearerTokenAndJSONAccept() async throws {
        ForgeHeaderRecorder.reset(status: 200, body: #"{"username":"octo"}"#)
        let client = GitboyClient(host: .testGitboy, token: "gb-secret",
                                  session: ForgeHeaderRecorder.session())
        _ = try await client.currentUser()

        let request = try XCTUnwrap(ForgeHeaderRecorder.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.authorization, "Bearer gb-secret")
        XCTAssertEqual(request.accept, "application/json")
        XCTAssertEqual(request.url, "https://gitboy.example.com/api/v1/user")
    }

    func testNoTokenIsNotSignedInAndSendsNothing() async {
        for token in [nil, ""] {
            do {
                _ = try await makeClient(token: token).currentUser()
                XCTFail("expected .notSignedIn for token \(String(describing: token))")
            } catch {
                XCTAssertEqual(error as? ForgeError, .notSignedIn)
            }
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// An explicit :443 is the same origin as no port at all. The request side
    /// drops 443 to nil, so a host configured as "name:443" must normalize it
    /// too, or every request to that host is refused before it is sent.
    func testAHostWithAnExplicit443StillReachesItsOwnOrigin() async throws {
        let host = try ForgeHost.gitboy(domain: "gitboy.example.com:443")
        XCTAssertTrue(GitboyRedirectPolicy.allows(
            URL(string: "https://gitboy.example.com/api/v1/user")!, host: host))
        XCTAssertTrue(GitboyRedirectPolicy.allows(
            URL(string: "https://gitboy.example.com:443/api/v1/user")!, host: host))
        XCTAssertFalse(GitboyRedirectPolicy.allows(
            URL(string: "https://gitboy.example.com:8443/api/v1/user")!, host: host),
            "Another port is another origin")
        XCTAssertFalse(GitboyRedirectPolicy.allows(
            URL(string: "https://other.example.com:443/api/v1/user")!, host: host))
        XCTAssertTrue(GitboyRedirectPolicy.allows(
            URL(string: "https://gitboy.example.com:443/api/v1/user")!, host: .testGitboy),
            "A :443 URL is the same origin as the host without a port")

        StubURLProtocol.stub("api/v1/user", status: 200, body: #"{"username":"octo"}"#)
        let client = GitboyClient(host: host, token: "gb-secret",
                                  session: StubURLProtocol.session())
        let user = try await client.currentUser()
        XCTAssertEqual(user.login, "octo")
        XCTAssertEqual(StubURLProtocol.requests.last?.url,
                       "https://gitboy.example.com:443/api/v1/user")
    }

    func testInvalidateDropsTheTokenAndEveryLaterCall() async throws {
        StubURLProtocol.stub("api/v1/user", status: 200, body: #"{"username":"octo"}"#)
        let client = makeClient()
        _ = try await client.currentUser()
        XCTAssertEqual(StubURLProtocol.requests.count, 1)

        await client.invalidate()

        do {
            _ = try await client.currentUser()
            XCTFail("expected .notSignedIn after invalidate()")
        } catch {
            XCTAssertEqual(error as? ForgeError, .notSignedIn)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "The refused call sends nothing")
    }

    func testReposMapsVisibilityActivityAndCursor() async throws {
        StubURLProtocol.stub("api/v1/repos", status: 200, body: """
        {"items":[
          {"id":1,"owner_username":"octo","name":"public-repo","description":"A repo",
           "visibility":"public","default_branch":"main","is_archived":false,
           "pushed_at":"2026-11-03T10:00:00.123Z","created_at":"2026-01-01T00:00:00Z"},
          {"id":2,"owner_username":"octo","name":"secret","description":null,
           "visibility":"private","default_branch":"trunk","is_archived":true,
           "pushed_at":null,"created_at":"2026-02-02T00:00:00Z"},
          {"id":3,"owner_username":"octo","name":"inner","description":null,
           "visibility":"internal","default_branch":"main","is_archived":false,
           "pushed_at":null,"created_at":null}
        ],"next_cursor":"cursor-2"}
        """)

        let page = try await makeClient().repos(cursor: "cursor-1", query: "octo repos")
        XCTAssertEqual(page.next, "cursor-2")
        XCTAssertEqual(page.items.map(\.name), ["public-repo", "secret", "inner"])

        let publicRepo = page.items[0]
        XCTAssertEqual(publicRepo.host, .testGitboy)
        XCTAssertEqual(publicRepo.fullName, "octo/public-repo")
        XCTAssertFalse(publicRepo.isPrivate)
        XCTAssertEqual(publicRepo.description, "A repo")
        XCTAssertEqual(publicRepo.defaultBranch, "main")
        XCTAssertFalse(publicRepo.isArchived)
        XCTAssertEqual(publicRepo.webURL.absoluteString, "https://gitboy.example.com/octo/public-repo")
        XCTAssertEqual(publicRepo.updatedAt, try XCTUnwrap(ISO8601Dates.parse("2026-11-03T10:00:00.123Z")))

        // Non-public visibilities are private to the picker; a missing
        // pushed_at falls back to created_at (or nothing at all).
        XCTAssertTrue(page.items[1].isPrivate)
        XCTAssertTrue(page.items[1].isArchived)
        XCTAssertEqual(page.items[1].defaultBranch, "trunk")
        XCTAssertEqual(page.items[1].updatedAt, ISO8601Dates.parse("2026-02-02T00:00:00Z"))
        XCTAssertTrue(page.items[2].isPrivate)
        XCTAssertNil(page.items[2].updatedAt)

        let items = try queryItems(in: try XCTUnwrap(StubURLProtocol.requests.last?.url))
        XCTAssertEqual(items.first { $0.name == "paginated" }?.value, "true")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "50")
        XCTAssertEqual(items.first { $0.name == "cursor" }?.value, "cursor-1")
        XCTAssertEqual(items.first { $0.name == "query" }?.value, "octo repos")
    }

    func testReposWithoutCursorHasNoCursorItemAndNullCursorEndsPaging() async throws {
        StubURLProtocol.stub("api/v1/repos", status: 200, body: #"{"items":[],"next_cursor":null}"#)
        let page = try await makeClient().repos(cursor: nil, query: nil)
        XCTAssertNil(page.next)
        XCTAssertTrue(page.items.isEmpty)

        let items = try queryItems(in: try XCTUnwrap(StubURLProtocol.requests.last?.url))
        XCTAssertFalse(items.contains { $0.name == "cursor" })
        XCTAssertFalse(items.contains { $0.name == "query" })
    }

    func testErrorResponsesMapToForgeErrors() async {
        let cases: [(Int, String, ForgeError)] = [
            (401, #"{"error":"Bad credentials"}"#, .unauthorized("Bad credentials")),
            (403, #"{"error":"Token requires read:issue"}"#, .missingScope("read:issue")),
            (403, #"{"error":"Forbidden"}"#, .unauthorized("Forbidden")),
            (404, #"{"error":"Not found"}"#, .notFound),
            (409, #"{"error":"Branch changed on the server"}"#, .conflict("Branch changed on the server")),
            (500, #"{"error":"boom"}"#, .server(status: 500, message: "boom")),
        ]
        for (status, body, expected) in cases {
            StubURLProtocol.reset()
            StubURLProtocol.stub("api/v1/user", status: status, body: body)
            do {
                _ = try await makeClient().currentUser()
                XCTFail("expected \(expected) for HTTP \(status)")
            } catch let error as ForgeError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testMissingScopeErrorSaysWhatToFix() {
        XCTAssertEqual(ForgeError.missingScope("read:issue").errorDescription,
                       "Your gitboy token needs the read:issue scope.")
    }
}

// MARK: - Gitboy device flow

final class GitboyDeviceFlowTests: XCTestCase {
    private func makeFlow() -> GitboyDeviceFlow {
        GitboyDeviceFlow(host: .testGitboy, session: StubURLProtocol.session())
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testRequestCodePostsClientNameAndScopes() async throws {
        StubURLProtocol.stub("auth/device/code", status: 200, body: """
        {"device_code":"device-1","user_code":"ABCD-1234",
         "verification_uri":"https://gitboy.example.com/device",
         "verification_uri_complete":"https://gitboy.example.com/device?code=ABCD-1234",
         "expires_in":600,"interval":5}
        """)

        let code = try await makeFlow().requestCode()
        XCTAssertEqual(code.deviceCode, "device-1")
        XCTAssertEqual(code.userCode, "ABCD-1234")
        XCTAssertEqual(code.verificationURI.absoluteString, "https://gitboy.example.com/device")
        XCTAssertEqual(code.verificationURIComplete?.absoluteString,
                       "https://gitboy.example.com/device?code=ABCD-1234")
        XCTAssertEqual(code.expiresIn, 600)
        XCTAssertEqual(code.interval, 5)

        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url, "https://gitboy.example.com/api/v1/auth/device/code")
        let body = try XCTUnwrap(StubURLProtocol.bodies.last)
        XCTAssertTrue(body.contains(GitboyDeviceFlow.clientName), body)
        for scope in GitboyDeviceFlow.scopes {
            XCTAssertTrue(body.contains(scope), body)
        }
    }

    func testPollAuthorizedSplitsScopesAndParsesExpiry() async throws {
        StubURLProtocol.stub("auth/device/token", status: 200, body: """
        {"access_token":"gb-token","token_type":"bearer",
         "scope":"read:user  read:repo","expires_at":"2026-11-03T10:00:00.123Z",
         "user":{"username":"octo","display_name":"Octo Cat"}}
        """)

        let state = try await makeFlow().poll(deviceCode: "device-1")
        guard case .authorized(let credential) = state else {
            return XCTFail("expected .authorized, got \(state)")
        }
        XCTAssertEqual(credential.host, .testGitboy)
        XCTAssertEqual(credential.token, "gb-token")
        XCTAssertEqual(credential.scopes, ["read:user", "read:repo"])
        XCTAssertEqual(credential.expiresAt, ISO8601Dates.parse("2026-11-03T10:00:00.123Z"))
        XCTAssertEqual(credential.source, .deviceFlow)
        XCTAssertEqual(credential.user?.login, "octo")
        XCTAssertEqual(credential.user?.displayName, "Octo Cat")

        let body = try XCTUnwrap(StubURLProtocol.bodies.last)
        XCTAssertTrue(body.contains("device-1"), body)
        XCTAssertTrue(body.contains("urn:ietf:params:oauth:grant-type:device_code"), body)
    }

    func testPollAcceptsMissingExpiryAndWholeSecondDates() async throws {
        StubURLProtocol.stub("auth/device/token", status: 200, body: """
        {"access_token":"gb-token","scope":"read:user","expires_at":null,
         "user":{"username":"octo"}}
        """)
        var state = try await makeFlow().poll(deviceCode: "device-1")
        guard case .authorized(let noExpiry) = state else {
            return XCTFail("expected .authorized, got \(state)")
        }
        XCTAssertNil(noExpiry.expiresAt)
        XCTAssertEqual(noExpiry.scopes, ["read:user"])
        XCTAssertNil(noExpiry.user?.displayName)

        StubURLProtocol.reset()
        StubURLProtocol.stub("auth/device/token", status: 200, body: """
        {"access_token":"gb-token","scope":"read:user","expires_at":"2026-11-03T10:00:00Z",
         "user":{"username":"octo"}}
        """)
        state = try await makeFlow().poll(deviceCode: "device-1")
        guard case .authorized(let whole) = state else {
            return XCTFail("expected .authorized, got \(state)")
        }
        XCTAssertEqual(whole.expiresAt, ISO8601Dates.parse("2026-11-03T10:00:00Z"))
    }

    func testPollMapsEveryDeviceFlow400() async throws {
        StubURLProtocol.stub("auth/device/token", status: 400,
                             body: #"{"error":"authorization_pending"}"#)
        StubURLProtocol.stub("auth/device/token", status: 400,
                             body: #"{"error":"slow_down","interval":9}"#)
        StubURLProtocol.stub("auth/device/token", status: 400,
                             body: #"{"error":"access_denied"}"#)
        StubURLProtocol.stub("auth/device/token", status: 400,
                             body: #"{"error":"expired_token"}"#)
        StubURLProtocol.stub("auth/device/token", status: 400,
                             body: #"{"error":"invalid_grant"}"#)

        let flow = makeFlow()
        let pending = try await flow.poll(deviceCode: "device-1")
        XCTAssertEqual(pending, .pending)

        let slowed = try await flow.poll(deviceCode: "device-1")
        guard case .slowDown(let interval) = slowed else {
            return XCTFail("expected .slowDown, got \(slowed)")
        }
        XCTAssertEqual(interval, 9)

        let denied = try await flow.poll(deviceCode: "device-1")
        XCTAssertEqual(denied, .denied)

        let expired = try await flow.poll(deviceCode: "device-1")
        XCTAssertEqual(expired, .expired)

        // invalid_grant means the device code is gone: same terminal state.
        let invalid = try await flow.poll(deviceCode: "device-1")
        XCTAssertEqual(invalid, .expired)
    }

    func testSlowDownWithoutIntervalUsesTheSpecDefault() async throws {
        StubURLProtocol.stub("auth/device/token", status: 400, body: #"{"error":"slow_down"}"#)
        let state = try await makeFlow().poll(deviceCode: "device-1")
        guard case .slowDown(let interval) = state else {
            return XCTFail("expected .slowDown, got \(state)")
        }
        XCTAssertEqual(interval, 5)
    }
}

// MARK: - GitHub through the same protocol

final class GitHubForgeTests: XCTestCase {
    private func makeForge() -> GitHubForge {
        GitHubForge(client: GitHubHTTPTransport(session: StubURLProtocol.session(), token: "test-token"))
    }

    private func reposJSON(_ names: [String]) -> String {
        let items = names.enumerated().map { index, name in
            """
            {"id":\(index + 1),"full_name":"octo/\(name)","name":"\(name)","owner":{"login":"octo"},\
            "private":\(name.hasPrefix("hidden") ? "true" : "false"),"default_branch":"main",\
            "pushed_at":"2026-11-03T10:00:00Z"}
            """
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testPageCursorBecomesThePageParameter() async throws {
        StubURLProtocol.stub("user/repos", status: 200,
                             body: reposJSON((1...100).map { "repo-\($0)" }))
        let page = try await makeForge().repos(cursor: "2", query: nil)

        XCTAssertEqual(page.items.count, 100)
        XCTAssertEqual(page.next, "3", "A full page may have another page behind it")
        let url = try XCTUnwrap(StubURLProtocol.requests.last?.url)
        XCTAssertTrue(url.contains("page=2"), url)
    }

    func testShortPageEndsPagingAndMapsRepos() async throws {
        StubURLProtocol.stub("user/repos", status: 200,
                             body: reposJSON(["phren-core", "hidden-store"]))
        let page = try await makeForge().repos(cursor: nil, query: nil)

        XCTAssertNil(page.next)
        XCTAssertEqual(page.items.map(\.name), ["phren-core", "hidden-store"])
        let url = try XCTUnwrap(StubURLProtocol.requests.last?.url)
        XCTAssertTrue(url.contains("page=1"), url)

        let core = try XCTUnwrap(page.items.first)
        XCTAssertEqual(core.host, .github)
        XCTAssertEqual(core.owner, "octo")
        XCTAssertEqual(core.fullName, "octo/phren-core")
        XCTAssertEqual(core.webURL.absoluteString, "https://github.com/octo/phren-core")
        XCTAssertFalse(core.isPrivate)
        XCTAssertEqual(core.defaultBranch, "main")
        XCTAssertEqual(core.updatedAt, ISO8601Dates.parse("2026-11-03T10:00:00Z"))
        XCTAssertTrue(page.items[1].isPrivate)
    }

    func testQueryFiltersByNameCaseInsensitively() async throws {
        StubURLProtocol.stub("user/repos", status: 200,
                             body: reposJSON(["phren-core", "website"]))
        let page = try await makeForge().repos(cursor: nil, query: "PHREN")
        XCTAssertEqual(page.items.map(\.name), ["phren-core"])
    }

    func testCurrentUserMapsToForgeUser() async throws {
        StubURLProtocol.stub("api.github.com/user", status: 200, body: """
        {"login":"octo","name":"Octo Cat","avatar_url":"https://avatars.githubusercontent.com/u/1"}
        """)
        let user = try await makeForge().currentUser()
        XCTAssertEqual(user.login, "octo")
        XCTAssertEqual(user.displayName, "Octo Cat")
        XCTAssertEqual(user.avatarURL?.absoluteString, "https://avatars.githubusercontent.com/u/1")
    }
}

// MARK: - Credential storage

final class ForgeCredentialStoreTests: XCTestCase {
    private var host: ForgeHost!

    override func setUp() {
        super.setUp()
        // Unique per run so a real account on the machine is never overwritten.
        host = ForgeHost(kind: .gitboy,
                         domain: "unit-test-\(UUID().uuidString.lowercased()).example.com")
    }

    override func tearDown() {
        if let host { try? ForgeCredentialStore.delete(host) }
        super.tearDown()
    }

    func testSaveReadStoredHostsAndDelete() throws {
        let user = ForgeUser(login: "octo", displayName: "Octo Cat",
                             avatarURL: URL(string: "https://gitboy.example.com/api/v1/users/octo/avatar"))
        let credential = ForgeCredential(host: host, token: "gb-secret", user: user,
                                         scopes: ["read:user", "read:repo"],
                                         expiresAt: nil, source: .pastedToken)

        do {
            try ForgeCredentialStore.save(credential)
        } catch {
            try skipIfKeychainUnavailable(error)
        }

        switch ForgeCredentialStore.read(host) {
        case .found(let stored):
            XCTAssertEqual(stored, credential)
        case .unavailable(let status) where status == -34018:
            throw XCTSkip("The test host has no Keychain entitlement (\(status)).")
        case .unavailable(let status):
            throw XCTSkip("The Keychain is unavailable in this test host (\(status)).")
        case .locked:
            throw XCTSkip("The Keychain is locked in this test host.")
        default:
            XCTFail("Expected the saved credential back")
        }

        let hosts = ForgeCredentialStore.storedHosts()
        XCTAssertEqual(hosts.map(\.id), hosts.map(\.id).sorted(), "storedHosts is sorted by host id")
        XCTAssertTrue(hosts.contains(host))

        try ForgeCredentialStore.delete(host)
        XCTAssertEqual(ForgeCredentialStore.read(host), .missing)
        XCTAssertFalse(ForgeCredentialStore.storedHosts().contains(host))
    }

    func testSavingAgainReplacesTheCredential() throws {
        var credential = ForgeCredential(host: host, token: "first", user: nil,
                                         scopes: [], expiresAt: nil, source: .deviceFlow)
        do {
            try ForgeCredentialStore.save(credential)
            credential = ForgeCredential(host: host, token: "second", user: nil,
                                         scopes: [], expiresAt: nil, source: .deviceFlow)
            try ForgeCredentialStore.save(credential)
        } catch {
            try skipIfKeychainUnavailable(error)
        }
        switch ForgeCredentialStore.read(host) {
        case .found(let stored):
            XCTAssertEqual(stored.token, "second")
        case .unavailable(let status):
            throw XCTSkip("The Keychain is unavailable in this test host (\(status)).")
        case .locked:
            throw XCTSkip("The Keychain is locked in this test host.")
        default:
            XCTFail("Expected the replacement credential back")
        }
    }

    /// The SPM test host is not always entitled for Keychain access, and a
    /// headless CI runner has no unlocked Keychain. Both are environment gaps,
    /// not storage bugs.
    private func skipIfKeychainUnavailable(_ error: Error) throws {
        if error.localizedDescription.contains("-34018") {
            throw XCTSkip("The test host has no Keychain entitlement (-34018).")
        }
        if error.localizedDescription.contains("-25308") {
            throw XCTSkip("The runner's Keychain is locked (-25308).")
        }
        throw error
    }
}

extension ForgeHost {
    /// A gitboy host for tests; real instance names stay out of the source.
    static let testGitboy = try! ForgeHost.gitboy(domain: "gitboy.example.com")
}
