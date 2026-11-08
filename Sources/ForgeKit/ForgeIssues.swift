import Foundation

/// An issue's state. Both hosts speak the same two words, so nothing is folded.
public enum ForgeIssueState: String, Codable, Sendable { case open, closed }

/// One label. `colorHex` is bare hex ("d73a4a"): gitboy sends a leading "#"
/// and GitHub does not, and a screen must not have to know which.
public struct ForgeLabel: Codable, Hashable, Sendable {
    public let name: String
    public let colorHex: String?     // "d73a4a", no leading #
    public init(name: String, colorHex: String?) {
        self.name = name
        self.colorHex = colorHex
    }
}

/// One issue, normalized so one list renders either host.
public struct ForgeIssue: Codable, Hashable, Sendable, Identifiable {
    public let repo: ForgeRepo
    public let number: Int
    public let title: String
    public let author: String
    public let state: ForgeIssueState
    public let labels: [ForgeLabel]
    public let assignees: [String]
    public let comments: Int
    public let updatedAt: Date?
    public let webURL: URL

    public init(repo: ForgeRepo, number: Int, title: String, author: String,
                state: ForgeIssueState, labels: [ForgeLabel], assignees: [String],
                comments: Int, updatedAt: Date?, webURL: URL) {
        self.repo = repo
        self.number = number
        self.title = title
        self.author = author
        self.state = state
        self.labels = labels
        self.assignees = assignees
        self.comments = comments
        self.updatedAt = updatedAt
        self.webURL = webURL
    }

    public var id: String { "\(repo.id)#\(number)" }
}

/// One comment on an issue. Event rows (opened, closed, …) are not comments
/// and never reach a screen.
public struct ForgeComment: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let author: String
    public let body: String
    public let createdAt: Date?

    public init(id: String, author: String, body: String, createdAt: Date?) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }
}

/// Everything an issue screen reads: the issue, its body and its comments.
public struct ForgeIssueDetail: Codable, Hashable, Sendable {
    public let issue: ForgeIssue
    public let body: String
    public let comments: [ForgeComment]   // oldest first; first page is enough (up to 100)

    public init(issue: ForgeIssue, body: String, comments: [ForgeComment]) {
        self.issue = issue
        self.body = body
        self.comments = comments
    }
}
