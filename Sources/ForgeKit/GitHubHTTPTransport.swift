import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A small URLSession-backed GitHub REST transport: exactly the requests
/// `GitHubForge` makes, with a bearer token and origin-pinned redirects.
///
/// This is the client ForgeKit can use alone. A host app that already has a
/// A host app's existing GitHub client can conform that instead; see
/// `PHRENKIT_ADAPTER.md`.
public actor GitHubHTTPTransport: GitHubTransport {
    /// Trailing slash matters: relative paths resolve against it directly,
    /// avoiding `//`-doubling from appendingPathComponent normalization.
    public static let apiBase = URL(string: "https://api.github.com/")!

    private let session: URLSession
    private var token: String?

    public init(session: URLSession = GitHubHTTPTransport.privateSession(), token: String? = nil) {
        self.session = session
        self.token = token
    }

    /// The same session, exposed to the other transport extensions (job logs
    /// need it for the credential-free signed-blob fetch).
    var networkSession: URLSession { session }

    /// GitHub credentials and responses must never enter the disk URL cache.
    public nonisolated static func privateSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    public func setToken(_ token: String?) {
        self.token = token
    }

    // MARK: - Request plumbing

    /// Dynamic values are path data, never URL syntax. In particular, Git
    /// permits `#` and `%` in branch names; resolving those raw reads another
    /// ref while contents writes still use the original branch from JSON.
    static func encodePath(_ value: String, nested: Bool = false) throws -> String {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (nested || parts.count == 1),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !value.contains("\\"), value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw GitHubError.invalidResponse
        }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return try parts.map { part in
            guard let encoded = String(part).addingPercentEncoding(withAllowedCharacters: unreserved) else {
                throw GitHubError.invalidResponse
            }
            return encoded
        }.joined(separator: "/")
    }

    static func repoPath(owner: String, repo: String) throws -> String {
        try "repos/\(encodePath(owner))/\(encodePath(repo))"
    }

    /// `method`/`path` are carried into the error so `errorDescription` can
    /// explain a 403/404 as the token-scope problem it usually is.
    static func ensureOK(_ http: HTTPURLResponse, data: Data,
                         method: String = "GET", path: String? = nil) throws {
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw GitHubError.http(status: http.statusCode, message: message ?? "request failed",
                                   method: method, path: path)
        }
    }

    @discardableResult
    func request(_ path: String, method: String = "GET",
                 accept: String = "application/vnd.github+json",
                 body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let token else { throw GitHubError.notAuthenticated }
        // Not appendingPathComponent — several paths carry query strings
        // ("?recursive=1"), which it would percent-encode.
        guard let url = URL(string: path, relativeTo: Self.apiBase)?.absoluteURL,
              GitHubRedirectPolicy.allows(url) else {
            throw GitHubError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: req, delegate: GitHubRedirectPolicy.shared)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }

        if http.statusCode == 403 || http.statusCode == 429,
           let throttled = Self.rateLimitError(http, data: data) {
            throw throttled
        }
        return (data, http)
    }

    /// GitHub throttles in three shapes, and only one of them zeroes the
    /// remaining counter:
    ///
    /// - primary limit: 403/429 with `x-ratelimit-remaining: 0`
    /// - secondary ("abuse") limit: 403/429 with a **non-zero** remaining, a
    ///   `retry-after` header and a "secondary rate limit" message
    /// - 429 without either header
    ///
    /// `x-ratelimit-reset` rides *every* response, so it is read for timing
    /// but never used as the signal — treating its presence as throttling
    /// would relabel every permissions 403 as a rate limit.
    static func rateLimitError(_ http: HTTPURLResponse, data: Data) -> GitHubError? {
        let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset")
            .flatMap(TimeInterval.init)
            .map { Date(timeIntervalSince1970: $0) }
        let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)

        if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
            return .rateLimited(resetAt: reset, retryAfter: retryAfter)
        }
        if let retryAfter {
            // The reset header describes the hourly window, not this backoff.
            return .rateLimited(resetAt: Date().addingTimeInterval(retryAfter), retryAfter: retryAfter)
        }
        let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
        let lowered = (message ?? "").lowercased()
        if lowered.contains("secondary rate limit") || lowered.contains("abuse detection") {
            return .rateLimited(resetAt: reset, retryAfter: nil)
        }
        if http.statusCode == 429 {
            return .rateLimited(resetAt: reset, retryAfter: nil)
        }
        return nil
    }

    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, http) = try await request(path)
        try Self.ensureOK(http, data: data, path: path)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Identity + repos

    public func currentUser() async throws -> GitHubUser {
        try await get("user", as: GitHubUser.self)
    }

    /// Most recently pushed repos visible to the token (owner + collaborator + org).
    public func listRepos(page: Int = 1, perPage: Int = 100) async throws -> [GitHubRepo] {
        try await get("user/repos?sort=pushed&per_page=\(perPage)&page=\(page)&affiliation=owner,collaborator,organization_member",
                      as: [GitHubRepo].self)
    }
}
