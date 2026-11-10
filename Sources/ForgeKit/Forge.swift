import Foundation

/// Which forge a screen is talking to. GitHub stays first-class; a gitboy
/// host is an additional account next to it, never a replacement.
public enum ForgeKind: String, Codable, Sendable, CaseIterable {
    case github
    case gitboy
}

/// A forge origin: the kind plus the bare host[:port] every request and link
/// is built from. Stored and compared by `id` ("gitboy:git.example.com").
public struct ForgeHost: Codable, Hashable, Sendable, Identifiable {
    public let kind: ForgeKind
    /// Lowercased host name with optional :port, no scheme or path. "github.com", "git.example.com".
    public let domain: String

    public init(kind: ForgeKind, domain: String) {
        self.kind = kind
        self.domain = domain
    }

    public var id: String { "\(kind.rawValue):\(domain)" }

    /// https://<domain>/
    public var webBase: URL {
        URL(string: "https://\(domain)/") ?? Self.placeholderBase
    }

    /// github: https://api.github.com/   gitboy: https://<domain>/api/v1/   (trailing slash)
    public var apiBase: URL {
        switch kind {
        case .github:
            return URL(string: "https://api.github.com/")!
        case .gitboy:
            return URL(string: "https://\(domain)/api/v1/") ?? Self.placeholderBase
        }
    }

    public static let github = ForgeHost(kind: .github, domain: "github.com")

    /// Only reachable through an unvalidated `init`; keeps `webBase`/`apiBase`
    /// non-optional without force-unwrapping user input.
    private static let placeholderBase = URL(string: "https://localhost/")!

    /// Normalizes user input: trims, lowercases, strips "https://", one trailing "/" and nothing else.
    /// Throws ForgeError.invalidHost for: empty, whitespace inside, any path/query/fragment,
    /// userinfo ("a@b"), "http://" scheme, or a domain that isn't a valid host[:port].
    public static func gitboy(domain: String) throws -> ForgeHost {
        var value = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("https://") {
            value.removeFirst("https://".count)
        }
        if value.hasSuffix("/") {
            value.removeLast()
        }
        guard isValidHost(value) else { throw ForgeError.invalidHost }
        return ForgeHost(kind: .gitboy, domain: value)
    }

    /// A bare `name` or `name:port`. No scheme, credentials, path, query or
    /// fragment can survive this: those characters are not in the allowed set.
    ///
    /// Public because `AgentSendLink` lives in the app and validates the host
    /// it parsed out of an `agent-send://` link with the same rule.
    public static func isValidHost(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 260,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        let name = String(parts[0])
        if parts.count == 2 {
            let port = String(parts[1])
            guard port.allSatisfy(\.isNumber), let number = Int(port), (1...65535).contains(number) else {
                return false
            }
        }
        // Underscores are tolerated for internal dev hosts; nothing else.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
        guard name.rangeOfCharacter(from: allowed.inverted) == nil else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
        }
    }
}

/// The signed-in identity on a forge, normalized from either API's shape.
public struct ForgeUser: Codable, Hashable, Sendable {
    public let login: String
    public let displayName: String?
    public let avatarURL: URL?

    public init(login: String, displayName: String?, avatarURL: URL?) {
        self.login = login
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

/// A repository on a forge, normalized so one list renders either host.
public struct ForgeRepo: Codable, Hashable, Sendable, Identifiable {
    public let host: ForgeHost
    public let owner: String
    public let name: String
    public let description: String?
    public let isPrivate: Bool
    public let defaultBranch: String
    public let isArchived: Bool
    public let updatedAt: Date?
    public let webURL: URL

    public init(host: ForgeHost, owner: String, name: String, description: String?,
                isPrivate: Bool, defaultBranch: String, isArchived: Bool,
                updatedAt: Date?, webURL: URL) {
        self.host = host
        self.owner = owner
        self.name = name
        self.description = description
        self.isPrivate = isPrivate
        self.defaultBranch = defaultBranch
        self.isArchived = isArchived
        self.updatedAt = updatedAt
        self.webURL = webURL
    }

    public var fullName: String { "\(owner)/\(name)" }
    public var id: String { "\(host.id)/\(owner)/\(name)" }
}

/// One page of a list. `next` is an opaque cursor; nil means last page.
public struct ForgePage<Item: Sendable & Hashable>: Sendable, Hashable {
    public let items: [Item]
    public let next: String?

    public init(items: [Item], next: String?) {
        self.items = items
        self.next = next
    }
}

/// What a host can do, so screens show or hide controls instead of forking per host.
public struct ForgeCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let issues        = ForgeCapabilities(rawValue: 1 << 0)
    public static let pipelines     = ForgeCapabilities(rawValue: 1 << 1)
    public static let liveLogs      = ForgeCapabilities(rawValue: 1 << 2) // streamed (SSE) job logs
    public static let rerunWholeRun = ForgeCapabilities(rawValue: 1 << 3)
    public static let retryFailed   = ForgeCapabilities(rawValue: 1 << 4)
    public static let runners       = ForgeCapabilities(rawValue: 1 << 5)
    public static let pauseRunners  = ForgeCapabilities(rawValue: 1 << 6)
    public static let pullRequests  = ForgeCapabilities(rawValue: 1 << 7)
    /// Cancel one job and leave the rest of its run going.
    public static let cancelJob     = ForgeCapabilities(rawValue: 1 << 8)
    /// Start a job that is waiting on a person.
    public static let playJob       = ForgeCapabilities(rawValue: 1 << 9)
    /// `ForgeRunnerScope.mine`: the signed-in account's own runners.
    public static let accountRunners = ForgeCapabilities(rawValue: 1 << 10)
    /// Read and write the conversation on a pull request.
    public static let pullComments  = ForgeCapabilities(rawValue: 1 << 11)
    /// Read a pull request's changes as a unified diff.
    public static let pullDiffs     = ForgeCapabilities(rawValue: 1 << 12)
    /// Send an issue to an agent on one of the user's computers.
    public static let agentSessions = ForgeCapabilities(rawValue: 1 << 13)

    public static let github: ForgeCapabilities = [
        .issues, .pipelines, .rerunWholeRun, .retryFailed, .runners,
        .pullRequests, .pullComments, .pullDiffs,
    ]
    public static let gitboy: ForgeCapabilities = [
        .issues, .pipelines, .liveLogs, .retryFailed, .runners, .pauseRunners,
        .pullRequests, .cancelJob, .playJob, .accountRunners,
        .pullComments, .pullDiffs, .agentSessions,
    ]
}

/// Everything the forge layer can fail with, worded for the user rather than
/// for a log: the message a screen shows is the fix the user can apply.
public enum ForgeError: Error, Equatable, Sendable, LocalizedError {
    case invalidHost
    case notSignedIn
    case unauthorized(String)          // 401, or 403 that is not a scope problem; message from server
    case missingScope(String)          // e.g. "read:issue" (gitboy 403 "Token requires read:issue")
    case notFound
    case rateLimited(until: Date?)
    case conflict(String)              // 409 with server message
    case server(status: Int, message: String)
    case invalidResponse
    /// Local validation or storage failure (for example a Keychain write).
    case validation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "That isn't a valid gitboy address. Use a host name like git.example.com."
        case .notSignedIn:
            return "You're not signed in to this host."
        case .unauthorized(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "The server rejected this token." : trimmed
        case .missingScope(let scope):
            return "Your token needs the \(scope) scope."
        case .notFound:
            return "That item wasn't found. It may have been deleted, or your token can't see it."
        case .rateLimited(let until):
            guard let until else { return "The forge is limiting requests. Try again in a moment." }
            let seconds = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
            if seconds >= 120 { return "The forge is limiting requests. Try again in \(seconds / 60) minutes." }
            return "The forge is limiting requests. Try again in \(seconds) seconds."
        case .conflict(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Someone else changed this first. Reload and try again." : trimmed
        case .server(let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "The forge returned an error (\(status))."
                                   : "The forge returned an error (\(status)): \(trimmed)"
        case .invalidResponse:
            return "The forge sent a response this app couldn't read."
        case .validation(let message):
            return message
        }
    }
}

/// One interface for both forges. GitHub keeps its own client and memory-store
/// sync; this is only the app-facing repo/user view of each host.
public protocol Forge: Sendable {
    var host: ForgeHost { get }
    var capabilities: ForgeCapabilities { get }
    func currentUser() async throws -> ForgeUser
    /// Repos the signed-in user can see, newest activity first. `query` filters by name.
    func repos(cursor: String?, query: String?) async throws -> ForgePage<ForgeRepo>
    /// Pull requests in one repo, newest activity first by each host's order.
    func pullRequests(in repo: ForgeRepo, state: ForgeStateFilter, cursor: String?) async throws -> ForgePage<ForgePullRequest>
    /// One pull request with its reviews, mergeability and checks.
    func pullRequest(in repo: ForgeRepo, number: Int) async throws -> ForgePullRequestDetail
    /// Merge as `method`, but only if the head is still `expectedHeadSHA`.
    func merge(_ pull: ForgePullRequest, method: ForgeMergeMethod, expectedHeadSHA: String) async throws -> ForgeMergeOutcome
    /// Submit `verdict` with `body`, pinned to the head the screen read
    /// (`expectedHeadSHA`). A head that moved since then is refused, never
    /// reviewed by accident.
    func review(_ pull: ForgePullRequest, verdict: ForgeReviewVerdict, body: String,
                expectedHeadSHA: String) async throws
    /// Issues in one repo, newest activity first by each host's order. `query`
    /// searches titles and bodies where the host supports it.
    func issues(in repo: ForgeRepo, state: ForgeStateFilter, query: String?, cursor: String?) async throws -> ForgePage<ForgeIssue>
    /// One issue with its body and the first page of comments, oldest first.
    func issue(in repo: ForgeRepo, number: Int) async throws -> ForgeIssueDetail
    /// Open a new issue.
    func createIssue(in repo: ForgeRepo, title: String, body: String) async throws -> ForgeIssue
    /// Add a comment to an issue.
    func comment(on issue: ForgeIssue, body: String) async throws -> ForgeComment
    /// Close or reopen an issue.
    func setState(of issue: ForgeIssue, to state: ForgeIssueState) async throws -> ForgeIssue
    /// CI runs in one repo, newest first by each host's order. `branch` filters
    /// to one branch where the host supports it.
    func runs(in repo: ForgeRepo, branch: String?, cursor: String?) async throws -> ForgePage<ForgeRun>
    /// One run with its jobs, in the order a screen lists them (a job is
    /// unique by its id, not its display name).
    func run(in repo: ForgeRepo, id runID: String) async throws -> ForgeRunDetail
    /// Re-run, retry the failed jobs of, or cancel a whole run.
    func perform(_ action: ForgeRunAction, on run: ForgeRun) async throws
    /// Retry, cancel or start one job.
    func perform(_ action: ForgeJobAction, on job: ForgeJob) async throws
    /// The whole log so far (bounded to the last 512 KB; prefix "… earlier output trimmed\n" when trimmed).
    func log(of job: ForgeJob) async throws -> String
    /// Live log: yields .text chunks as they arrive and ends with .finished. A host without .liveLogs
    /// has no log to read until the job ends: it yields nothing while the job runs, then the whole
    /// log once, then .finished.
    func liveLog(of job: ForgeJob) -> AsyncThrowingStream<ForgeLogEvent, Error>
    /// The runner fleet visible to the signed-in user at `scope`.
    func runners(_ scope: ForgeRunnerScope) async throws -> [ForgeRunner]
    /// Pause or resume one runner; only hosts with `.pauseRunners` accept it.
    func setPaused(_ paused: Bool, runner: ForgeRunner) async throws -> ForgeRunner
    /// Remove a runner registration from its scope.
    func remove(_ runner: ForgeRunner) async throws

    // Everything below was added after 0.1.0 and has a default that refuses,
    // so a conformer written against 0.1.0 keeps compiling. Check
    // `capabilities` before offering the control.

    /// The conversation on a pull request, oldest first (the first page, up
    /// to 100). Review verdicts are in `pullRequest(in:number:)`, not here.
    func comments(on pull: ForgePullRequest) async throws -> [ForgeComment]
    /// Add a conversation comment to a pull request.
    func comment(on pull: ForgePullRequest, body: String) async throws -> ForgeComment
    /// The pull request's changes as one unified diff.
    func diff(of pull: ForgePullRequest) async throws -> ForgePullDiff
    /// The signed-in user's computers that can take an agent session.
    func computers() async throws -> [ForgeComputer]
    /// The agent sessions on one issue, newest first.
    func agentSessions(on issue: ForgeIssue) async throws -> [ForgeAgentSession]
    /// The signed-in user's own agent sessions across repositories, newest first.
    func myAgentSessions() async throws -> [ForgeAgentSession]
    /// Send `issue` to an agent on `computer`, run by `harness` ("claude", "codex").
    func startAgentSession(on issue: ForgeIssue, computer: ForgeComputer,
                           harness: String) async throws -> ForgeAgentSession
    /// Cancel an agent session that has not finished.
    func cancel(_ session: ForgeAgentSession) async throws -> ForgeAgentSession
}

extension Forge {
    private func refuse<T>(_ what: String) throws -> T {
        throw ForgeError.server(status: 0, message: "This host can't \(what).")
    }

    public func comments(on pull: ForgePullRequest) async throws -> [ForgeComment] {
        try refuse("list pull request comments")
    }

    public func comment(on pull: ForgePullRequest, body: String) async throws -> ForgeComment {
        try refuse("comment on a pull request")
    }

    public func diff(of pull: ForgePullRequest) async throws -> ForgePullDiff {
        try refuse("show a pull request's changes")
    }

    public func computers() async throws -> [ForgeComputer] {
        try refuse("list computers")
    }

    public func agentSessions(on issue: ForgeIssue) async throws -> [ForgeAgentSession] {
        try refuse("list agent sessions")
    }

    public func myAgentSessions() async throws -> [ForgeAgentSession] {
        try refuse("list agent sessions")
    }

    public func startAgentSession(on issue: ForgeIssue, computer: ForgeComputer,
                                  harness: String) async throws -> ForgeAgentSession {
        try refuse("send an issue to an agent")
    }

    public func cancel(_ session: ForgeAgentSession) async throws -> ForgeAgentSession {
        try refuse("cancel an agent session")
    }
}
