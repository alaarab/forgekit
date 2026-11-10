import Foundation

/// A computer that can take an agent session: one of the user's runners that
/// says it runs agents, with the harnesses it offers.
public struct ForgeComputer: Codable, Hashable, Sendable, Identifiable {
    public let runner: ForgeRunner
    /// "claude", "codex", … in the order the computer lists them.
    public let harnesses: [String]

    public init(runner: ForgeRunner, harnesses: [String]) {
        self.runner = runner
        self.harnesses = harnesses
    }

    public var id: String { runner.id }
    public var name: String { runner.name }
    /// A session can only be started on a computer that is online.
    public var isOnline: Bool { runner.isOnline }
}

/// Where an agent session is in its life. `queued`, `claimed`, `running` and
/// `needsYou` are active; the rest never change again.
public enum ForgeAgentStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case claimed
    case running
    /// The agent asked its requester a question.
    case needsYou
    case done
    case failed
    case canceled

    public var isActive: Bool {
        switch self {
        case .queued, .claimed, .running, .needsYou: return true
        case .done, .failed, .canceled: return false
        }
    }
}

/// One agent session: an issue handed to an AI coding agent on one of the
/// requester's computers. Only lifecycle metadata; what the agent asks or says
/// stays with the requester.
public struct ForgeAgentSession: Codable, Hashable, Sendable, Identifiable {
    public let host: ForgeHost
    public let sessionID: String
    /// "owner/name"
    public let repository: String?
    public let issueNumber: Int?
    public let computerID: String?
    public let computerName: String?
    public let harness: String
    public let status: ForgeAgentStatus
    /// The branch the agent works on.
    public let branch: String?
    public let requestedBy: String?
    public let pullRequestNumber: Int?
    public let pullRequestURL: URL?
    /// The host's fixed code for a failed session: "queue_timeout",
    /// "runner_lost", "dispatch_failed", "agent_failed", …
    public let errorCode: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(host: ForgeHost, sessionID: String, repository: String?, issueNumber: Int?,
                computerID: String?, computerName: String?, harness: String,
                status: ForgeAgentStatus, branch: String?, requestedBy: String?,
                pullRequestNumber: Int?, pullRequestURL: URL?, errorCode: String?,
                createdAt: Date?, updatedAt: Date?) {
        self.host = host
        self.sessionID = sessionID
        self.repository = repository
        self.issueNumber = issueNumber
        self.computerID = computerID
        self.computerName = computerName
        self.harness = harness
        self.status = status
        self.branch = branch
        self.requestedBy = requestedBy
        self.pullRequestNumber = pullRequestNumber
        self.pullRequestURL = pullRequestURL
        self.errorCode = errorCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var id: String { "\(host.id)/agent-session/\(sessionID)" }
}
