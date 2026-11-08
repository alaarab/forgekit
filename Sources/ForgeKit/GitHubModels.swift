import Foundation

/// The signed-in GitHub identity, as the REST API sends it.
public struct GitHubUser: Codable, Equatable, Sendable {
    public let login: String
    public let name: String?
    public let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case login, name
        case avatarUrl = "avatar_url"
    }
}

/// The repository fields the forge layer reads from `GET user/repos`.
public struct GitHubRepo: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let fullName: String
    public let name: String
    public let owner: Owner
    public let isPrivate: Bool
    public let defaultBranch: String
    public let pushedAt: String?
    public let permissions: Permissions?

    public struct Owner: Codable, Equatable, Sendable {
        public let login: String
    }

    public struct Permissions: Codable, Equatable, Sendable {
        public let push: Bool
    }

    enum CodingKeys: String, CodingKey {
        case id, name, owner, permissions
        case fullName = "full_name"
        case isPrivate = "private"
        case defaultBranch = "default_branch"
        case pushedAt = "pushed_at"
    }
}

/// GitHub failures, worded for the user. Copied from the app so the forge
/// layer can carry the same error type the app already catches.
public enum GitHubError: Error, LocalizedError, Sendable {
    /// Carries the failing request, not just its status: a bare "404 Not
    /// Found" is actively misleading on a `repos/…` path, where GitHub hides
    /// repositories the token isn't scoped to behind the same status as a
    /// repository that doesn't exist.
    case http(status: Int, message: String, method: String, path: String?)
    /// 409/422 sha mismatch on a contents PUT — the file changed remotely.
    case shaConflict(path: String)
    /// Primary (`x-ratelimit-remaining: 0`) or secondary/abuse limit; the
    /// latter carries GitHub's `retry-after` delay.
    case rateLimited(resetAt: Date?, retryAfter: TimeInterval?)
    case notAuthenticated
    case invalidResponse
    case treeTruncated

    /// True for the 409/422 optimistic-concurrency failure the sync engine
    /// recovers from by refetching and re-applying.
    public var isShaConflict: Bool {
        if case .shaConflict = self { return true }
        return false
    }

    /// GitHub refused the repository itself: its 404 for a private repo the
    /// token can't see, or a 403 on a write. A GitHub App sign-in gets this
    /// for any repo left out of the installation.
    public var isRepoAccessDenied: Bool {
        guard case .http(let status, _, let method, let path) = self, Self.repoSlug(from: path) != nil else { return false }
        return status == 404 || (status == 403 && (method == "PUT" || method == "DELETE"))
    }

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message, let method, let path):
            return Self.describe(status: status, message: message, method: method, path: path)
        case .shaConflict(let path):
            return "\(path) changed on GitHub while editing."
        case .rateLimited(let resetAt, let retryAfter):
            if let retryAfter {
                return "GitHub is throttling requests (secondary rate limit) — retry in "
                    + Self.wait(Int(retryAfter.rounded(.up))) + "."
            }
            if let resetAt, resetAt.timeIntervalSinceNow > 0 {
                return "GitHub rate limit reached — try again in about "
                    + Self.wait(Int(resetAt.timeIntervalSinceNow.rounded(.up))) + "."
            }
            return "GitHub rate limit reached — try again shortly."
        case .notAuthenticated:
            return "Not signed in to GitHub."
        case .invalidResponse:
            return "Unexpected response from GitHub."
        case .treeTruncated:
            return "Repository tree too large to enumerate."
        }
    }

    /// Token-scope failures name themselves badly, so translate them:
    ///
    /// - 404 on a repo path is the documented answer for a private repository
    ///   the token can't read (REST docs, "Failed login limit"/authentication
    ///   section) — far more often a missing repository grant than a typo.
    /// - 403 on a write is a permission level, not a missing repo.
    /// - 401 anywhere means the credential itself is dead.
    private static func describe(status: Int, message: String, method: String, path: String?) -> String {
        let generic = "GitHub API error \(status): \(message)"
        if status == 401 {
            return "Your GitHub token has expired or been revoked. Sign out in Settings, "
                + "then sign in again with a new token."
        }
        guard let slug = repoSlug(from: path) else { return generic }
        switch status {
        case 404:
            return "GitHub can't see \(slug). It answers \"not found\" for private repositories a "
                + "token isn't allowed to read, so this is usually token access rather than a "
                + "missing repository. A fine-grained token must list \(slug) under Repository "
                + "access, with Contents: Read and write and Metadata: Read."
        case 403 where method == "PUT" || method == "DELETE":
            return "Your GitHub token can't write to \(slug). It needs Contents: Read and write "
                + "on that repository. Fix the token on GitHub, then retry from Settings."
        default:
            return generic
        }
    }

    /// `repos/<owner>/<name>/…` → `<owner>/<name>`; nil for user/auth paths,
    /// which no amount of repository scoping would fix.
    static func repoSlug(from path: String?) -> String? {
        guard let path else { return nil }
        let withoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = withoutQuery.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "repos" else { return nil }
        return "\(parts[1])/\(parts[2])"
    }

    private static func wait(_ seconds: Int) -> String {
        seconds >= 120 ? "\(seconds / 60) minutes" : "\(max(seconds, 1)) seconds"
    }
}
