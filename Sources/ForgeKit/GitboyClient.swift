import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Redirects must never carry a gitboy bearer token to another host or over
/// plain http. Same rule as `GitHubRedirectPolicy`, pinned to the configured
/// host instead of api.github.com.
final class GitboyRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    private let name: String
    private let port: Int?

    init(host: ForgeHost) {
        let parts = Self.split(host.domain)
        self.name = parts.name
        self.port = parts.port
        super.init()
    }

    static func allows(_ url: URL, host: ForgeHost) -> Bool {
        let parts = split(host.domain)
        return allows(url, name: parts.name, port: parts.port)
    }

    private static func split(_ domain: String) -> (name: String, port: Int?) {
        let parts = domain.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first.map(String.init) ?? domain
        let port = parts.count == 2 ? Int(parts[1]) : nil
        return (name, port)
    }

    private static func allows(_ url: URL, name: String, port: Int?) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.host?.lowercased() == name.lowercased() else { return false }
        // A missing port and :443 are the same origin, on both sides: a request
        // URL drops 443 to nil, while a configured "host:443" keeps it.
        return (url.port ?? 443) == (port ?? 443)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { Self.allows($0, name: name, port: port) } == true ? request : nil)
    }
}

/// Path builders for gitboy links. Segments come from the server, so they are
/// percent-encoded instead of being pasted into a path.
enum GitboyURLs {
    static func web(host: ForgeHost, owner: String, name: String) -> URL {
        URL(string: "https://\(host.domain)/\(segment(owner))/\(segment(name))") ?? host.webBase
    }

    static func avatar(host: ForgeHost, username: String) -> URL {
        URL(string: "https://\(host.domain)/api/v1/users/\(segment(username))/avatar") ?? host.webBase
    }

    private static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Shared request plumbing for gitboy's REST API: bearer auth, JSON accept,
/// origin-pinned redirects, and the contract's error mapping.
struct GitboyTransport: Sendable {
    let host: ForgeHost
    let session: URLSession
    private let redirects: GitboyRedirectPolicy

    init(host: ForgeHost, session: URLSession) {
        self.host = host
        self.session = session
        self.redirects = GitboyRedirectPolicy(host: host)
    }

    /// `validate: false` lets device-flow polling read an expected 400 body
    /// (authorization_pending, slow_down, …) instead of throwing on it.
    func send(_ path: String, method: String = "GET",
              query: [URLQueryItem] = [],
              body: Data? = nil,
              bearer: String?,
              validate: Bool = true) async throws -> (Data, HTTPURLResponse) {
        // Not appendingPathComponent: query strings would be percent-encoded.
        guard let base = URL(string: path, relativeTo: host.apiBase)?.absoluteURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ForgeError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url, GitboyRedirectPolicy.allows(url, host: host) else {
            throw ForgeError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request, delegate: redirects)
        guard let http = response as? HTTPURLResponse else { throw ForgeError.invalidResponse }
        if validate, !(200..<300).contains(http.statusCode) {
            throw Self.error(status: http.statusCode, headers: http, data: data)
        }
        return (data, http)
    }

    /// gitboy error bodies are `{"error": "message", "details": …}`. The 403
    /// split matters: "Token requires read:issue" is a scope problem a screen
    /// can offer to fix, not a revoked token.
    static func error(status: Int, headers: HTTPURLResponse, data: Data) -> ForgeError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let raw = (json?["error"] as? String) ?? (json?["message"] as? String) ?? ""
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        switch status {
        case 401:
            return .unauthorized(message.isEmpty ? "The server rejected this token." : message)
        case 403:
            let prefix = "Token requires "
            if message.hasPrefix(prefix) {
                let scope = message.dropFirst(prefix.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !scope.isEmpty { return .missingScope(scope) }
            }
            return .unauthorized(message.isEmpty ? "The server rejected this request." : message)
        case 404:
            return .notFound
        case 409:
            return .conflict(message)
        case 429:
            let until = headers.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
                .map { Date().addingTimeInterval($0) }
            return .rateLimited(until: until)
        default:
            return .server(status: status, message: message.isEmpty ? "request failed" : message)
        }
    }
}

/// The user half of `GET user`. Kept private to the forge layer: screens see
/// `ForgeUser`, which both hosts produce.
struct GitboyUserDTO: Decodable, Sendable {
    let username: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
    }

    func forgeUser(host: ForgeHost) -> ForgeUser {
        ForgeUser(login: username, displayName: displayName,
                  avatarURL: GitboyURLs.avatar(host: host, username: username))
    }
}

/// One repo in `GET repos`. `isPrivate` is deliberately "not public": the
/// internal visibility must not be shown as a public repo.
struct GitboyRepoDTO: Decodable, Sendable {
    let ownerUsername: String
    let name: String
    let description: String?
    let visibility: String
    let defaultBranch: String
    let isArchived: Bool
    let pushedAt: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case name, description, visibility
        case ownerUsername = "owner_username"
        case defaultBranch = "default_branch"
        case isArchived = "is_archived"
        case pushedAt = "pushed_at"
        case createdAt = "created_at"
    }

    func forgeRepo(host: ForgeHost) -> ForgeRepo {
        ForgeRepo(host: host,
                  owner: ownerUsername,
                  name: name,
                  description: description,
                  isPrivate: visibility != "public",
                  defaultBranch: defaultBranch,
                  isArchived: isArchived,
                  updatedAt: ISO8601Dates.parse(pushedAt) ?? ISO8601Dates.parse(createdAt),
                  webURL: GitboyURLs.web(host: host, owner: ownerUsername, name: name))
    }
}

struct GitboyReposPage: Decodable, Sendable {
    let items: [GitboyRepoDTO]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

/// A self-hosted gitboy instance. Thin: the transport does the request work,
/// this type only knows where the two read endpoints are and what they return.
public actor GitboyClient: Forge {
    public nonisolated let host: ForgeHost
    public nonisolated var capabilities: ForgeCapabilities { ForgeCapabilities.gitboy }

    /// Internal, not private: the pulls extension in another file reads these.
    let transport: GitboyTransport
    var token: String?
    /// The live-log streams this client started, so `invalidate()` can end
    /// them. Internal for the runs extension that registers and clears them.
    var logStreams: [UUID: AsyncThrowingStream<ForgeLogEvent, Error>.Continuation] = [:]
    /// Set by `invalidate()`: a stream that starts after it never connects, and
    /// one already running must not reconnect with the token it began with.
    var invalidated = false

    public init(host: ForgeHost, token: String?, session: URLSession = GitHubHTTPTransport.privateSession()) {
        self.host = host
        self.token = token
        self.transport = GitboyTransport(host: host, session: session)
    }

    public func setToken(_ token: String?) {
        self.token = token
    }

    /// Signs this host out for good: the token is dropped, every live-log
    /// stream this client started is ended, and every later call — a stream's
    /// next reconnect included — throws `.notSignedIn` instead of reusing a
    /// token held from before.
    public func invalidate() {
        invalidated = true
        token = nil
        let live = Array(logStreams.values)
        logStreams.removeAll()
        for continuation in live {
            continuation.finish(throwing: ForgeError.notSignedIn)
        }
    }

    public func currentUser() async throws -> ForgeUser {
        let bearer = try authorization()
        let (data, _) = try await transport.send("user", bearer: bearer)
        guard let user = try? JSONDecoder().decode(GitboyUserDTO.self, from: data) else {
            throw ForgeError.invalidResponse
        }
        return user.forgeUser(host: host)
    }

    public func repos(cursor: String?, query: String?) async throws -> ForgePage<ForgeRepo> {
        var items = [
            URLQueryItem(name: "paginated", value: "true"),
            URLQueryItem(name: "limit", value: "50"),
        ]
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "query", value: query))
        }
        let bearer = try authorization()
        let (data, _) = try await transport.send("repos", query: items, bearer: bearer)
        guard let page = try? JSONDecoder().decode(GitboyReposPage.self, from: data) else {
            throw ForgeError.invalidResponse
        }
        let repos = page.items.map { $0.forgeRepo(host: host) }
        // An empty cursor is "no more pages", the same as null.
        let next = (page.nextCursor?.isEmpty == false) ? page.nextCursor : nil
        return ForgePage(items: repos, next: next)
    }

    func authorization() throws -> String {
        guard let token, !token.isEmpty else { throw ForgeError.notSignedIn }
        return token
    }
}
