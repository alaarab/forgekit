import Foundation

// MARK: - Agent session rows

/// One agent session as gitboy describes it (`agentSessionJson`). The start,
/// cancel and list endpoints all answer this shape.
struct GitboyAgentSessionDTO: Decodable, Sendable {
    struct RepositoryDTO: Decodable, Sendable {
        let fullName: String?

        enum CodingKeys: String, CodingKey { case fullName = "full_name" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fullName = c.lenient(.fullName)
        }
    }

    struct RunnerDTO: Decodable, Sendable {
        let id: String?
        let name: String?

        enum CodingKeys: String, CodingKey { case id, name }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lenient(.id)
            name = c.lenient(.name)
        }
    }

    struct PullDTO: Decodable, Sendable {
        let index: Int?
        let url: String?

        enum CodingKeys: String, CodingKey { case index, url }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            index = c.lenient(.index)
            url = c.lenient(.url)
        }
    }

    let id: String?
    let issueIndex: Int?
    let repository: RepositoryDTO?
    let runner: RunnerDTO?
    let harness: String?
    let status: String?
    let branch: String?
    let requestedByUsername: String?
    let pullRequest: PullDTO?
    let errorCode: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, repository, runner, harness, status, branch
        case issueIndex = "issue_index"
        case requestedByUsername = "requested_by_username"
        case pullRequest = "pull_request"
        case errorCode = "error_code"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id)
        issueIndex = c.lenient(.issueIndex)
        repository = c.lenient(.repository)
        runner = c.lenient(.runner)
        harness = c.lenient(.harness)
        status = c.lenient(.status)
        branch = c.lenient(.branch)
        requestedByUsername = c.lenient(.requestedByUsername)
        pullRequest = c.lenient(.pullRequest)
        errorCode = c.lenient(.errorCode)
        createdAt = c.lenient(.createdAt)
        updatedAt = c.lenient(.updatedAt)
    }

    /// nil only when the row has no id: nothing could key or cancel it.
    /// `issue` fills in the repository and number a row leaves out.
    func forgeSession(host: ForgeHost, issue: ForgeIssue? = nil) -> ForgeAgentSession? {
        guard let sessionID = GitboyRunnerMapping.nonEmpty(id) else { return nil }
        return ForgeAgentSession(
            host: host,
            sessionID: sessionID,
            repository: GitboyRunnerMapping.nonEmpty(repository?.fullName) ?? issue?.repo.fullName,
            issueNumber: issueIndex ?? issue?.number,
            computerID: GitboyRunnerMapping.nonEmpty(runner?.id),
            computerName: GitboyRunnerMapping.nonEmpty(runner?.name),
            harness: GitboyRunnerMapping.nonEmpty(harness) ?? "",
            status: GitboyClient.agentStatus(status),
            branch: GitboyRunnerMapping.nonEmpty(branch),
            requestedBy: GitboyRunnerMapping.nonEmpty(requestedByUsername),
            pullRequestNumber: pullRequest?.index,
            pullRequestURL: GitboyPullDTO.webLink(pullRequest?.url),
            errorCode: GitboyRunnerMapping.nonEmpty(errorCode),
            createdAt: ISO8601Dates.parse(createdAt),
            updatedAt: ISO8601Dates.parse(updatedAt))
    }
}

// MARK: - Client

extension GitboyClient {
    /// The user's own runners that say they run agents. gitboy has no separate
    /// list: a computer is a `user/runners` row with a harness, unless it says
    /// outright that it doesn't take agent sessions.
    public func computers() async throws -> [ForgeComputer] {
        let bearer = try authorization()
        let (data, _) = try await transport.send(Self.runnersPath(.mine), bearer: bearer)
        guard let page = try? JSONDecoder().decode(GitboyPage<GitboyRunnerDTO>.self, from: data) else {
            throw ForgeError.invalidResponse
        }
        let mapping = GitboyRunnerMapping(host: host, scope: .mine)
        return page.items.compactMap { dto -> ForgeComputer? in
            let harnesses = dto.harnesses
            guard dto.capabilities?.agentV1 != false, !harnesses.isEmpty,
                  let runner = mapping.runner(from: dto) else { return nil }
            // gitboy starts a session only on a computer whose status is
            // exactly "online" and that checked in within the last minute. A
            // runner list is looser (two minutes, and paused still counts as
            // reachable), so the session rule is applied here.
            let fresh = runner.lastSeenAt.map {
                mapping.now().timeIntervalSince($0) <= Self.agentOnlineWindow
            } == true
            let online = (dto.status ?? "").lowercased() == "online" && fresh
            return ForgeComputer(runner: runner, harnesses: harnesses, isOnline: online)
        }
    }

    public func agentSessions(on issue: ForgeIssue) async throws -> [ForgeAgentSession] {
        let bearer = try authorization()
        let (data, _) = try await transport.send(Self.agentSessionsPath(issue), bearer: bearer)
        return try sessions(from: data, issue: issue)
    }

    public func myAgentSessions() async throws -> [ForgeAgentSession] {
        let bearer = try authorization()
        let (data, _) = try await transport.send("user/agent-sessions", bearer: bearer)
        return try sessions(from: data, issue: nil)
    }

    public func startAgentSession(on issue: ForgeIssue, computer: ForgeComputer,
                                  harness: String) async throws -> ForgeAgentSession {
        let bearer = try authorization()
        let payload = try JSONSerialization.data(withJSONObject: [
            "runner_id": computer.runner.runnerID,
            "harness": harness,
        ])
        let (data, http) = try await transport.send(Self.agentSessionsPath(issue), method: "POST",
                                                    body: payload, bearer: bearer, validate: false)
        guard (200..<300).contains(http.statusCode) else {
            // 429 here is the requester's own limit of sessions running at
            // once, in the server's words. It is not request throttling, and
            // waiting a moment does not fix it.
            let message = GitboyTransport.message(from: data)
            if http.statusCode == 429, !message.isEmpty {
                throw ForgeError.conflict(message)
            }
            throw GitboyTransport.error(status: http.statusCode, headers: http, data: data)
        }
        return try session(from: data, issue: issue)
    }

    public func cancel(_ session: ForgeAgentSession) async throws -> ForgeAgentSession {
        // The cancel route is scoped to the session's repository and issue.
        let parts = (session.repository ?? "").split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              let number = session.issueNumber else {
            throw ForgeError.invalidResponse
        }
        let bearer = try authorization()
        let path = "repos/\(Self.pathSegment(String(parts[0])))/\(Self.pathSegment(String(parts[1])))"
            + "/issues/\(number)/agent-sessions/\(Self.pathSegment(session.sessionID))/cancel"
        let (data, _) = try await transport.send(path, method: "POST", bearer: bearer)
        guard let dto = try? JSONDecoder().decode(GitboyAgentSessionDTO.self, from: data),
              let updated = dto.forgeSession(host: host) else {
            throw ForgeError.invalidResponse
        }
        // A cancel answer may leave the repository out; the session asked
        // about already says where it lives.
        guard updated.repository == nil || updated.issueNumber == nil else { return updated }
        return ForgeAgentSession(
            host: updated.host, sessionID: updated.sessionID,
            repository: updated.repository ?? session.repository,
            issueNumber: updated.issueNumber ?? session.issueNumber,
            computerID: updated.computerID, computerName: updated.computerName,
            harness: updated.harness, status: updated.status, branch: updated.branch,
            requestedBy: updated.requestedBy,
            pullRequestNumber: updated.pullRequestNumber,
            pullRequestURL: updated.pullRequestURL, errorCode: updated.errorCode,
            createdAt: updated.createdAt, updatedAt: updated.updatedAt)
    }
}

// MARK: - Internals

extension GitboyClient {
    /// How recently a computer must have checked in for gitboy to start a
    /// session on it.
    static let agentOnlineWindow: TimeInterval = 60

    /// gitboy's session status words. A word this client doesn't know is
    /// `running`: it is not a terminal state, so a screen keeps refreshing.
    static func agentStatus(_ raw: String?) -> ForgeAgentStatus {
        switch (raw ?? "").lowercased() {
        case "queued": return .queued
        case "claimed": return .claimed
        case "running": return .running
        case "needs_you": return .needsYou
        case "done": return .done
        case "failed": return .failed
        case "canceled", "cancelled": return .canceled
        default: return .running
        }
    }

    static func agentSessionsPath(_ issue: ForgeIssue) -> String {
        "\(repoPath(issue.repo))/issues/\(issue.number)/agent-sessions"
    }

    static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func sessions(from data: Data, issue: ForgeIssue?) throws -> [ForgeAgentSession] {
        guard let page = try? JSONDecoder().decode(GitboyPage<GitboyAgentSessionDTO>.self, from: data) else {
            throw ForgeError.invalidResponse
        }
        return page.items.compactMap { $0.forgeSession(host: host, issue: issue) }
    }

    private func session(from data: Data, issue: ForgeIssue?) throws -> ForgeAgentSession {
        guard let dto = try? JSONDecoder().decode(GitboyAgentSessionDTO.self, from: data),
              let session = dto.forgeSession(host: host, issue: issue) else {
            throw ForgeError.invalidResponse
        }
        return session
    }
}
