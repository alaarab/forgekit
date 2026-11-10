import Foundation

/// Which pull requests a list asks for. GitHub's own words, so the query is
/// spelled the same for both hosts.
public enum ForgeStateFilter: String, Sendable, CaseIterable {
    case open
    case closed
    case all
}

/// A pull request's state, folded from each host's own vocabulary: gitboy's
/// `open`/`closed` plus a non-null `merged_at`, GitHub's `state` plus
/// `merged_at`.
public enum ForgePullState: String, Codable, Sendable {
    case open
    case closed
    case merged
}

/// One check on a pull request. The declaration order is the sort order:
/// failing first, so the one thing a screen must show is never scrolled past.
public enum ForgeCheckState: String, Codable, Sendable, Comparable {
    case failing
    case pending
    case passing
    case skipped
    case neutral

    private static let order: [ForgeCheckState] = [.failing, .pending, .passing, .skipped, .neutral]

    /// Written out rather than synthesized so the order is the one documented
    /// here, not one a future case insertion could silently rename.
    public static func < (lhs: ForgeCheckState, rhs: ForgeCheckState) -> Bool {
        (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

/// The aggregate review verdict, GitHub's `reviewDecision` spelled in Swift.
public enum ForgeReviewDecision: String, Codable, Sendable {
    case approved
    case changesRequested
    case reviewRequired
}

/// What a screen asks a reviewer to say. Both hosts take it as their own state
/// or event word, so the screen never branches.
public enum ForgeReviewVerdict: String, Codable, Sendable {
    case approve
    case requestChanges
    case comment
}

/// How a merge is recorded on the base branch.
public enum ForgeMergeMethod: String, Codable, Sendable, CaseIterable {
    case merge
    case squash
    case rebase
}

/// One pull request, normalized so one list renders either host.
public struct ForgePullRequest: Codable, Hashable, Sendable, Identifiable {
    public let repo: ForgeRepo
    public let number: Int
    public let title: String
    public let author: String
    public let state: ForgePullState
    public let isDraft: Bool
    public let headBranch: String
    public let baseBranch: String
    public let updatedAt: Date?
    public let webURL: URL

    public init(repo: ForgeRepo, number: Int, title: String, author: String,
                state: ForgePullState, isDraft: Bool, headBranch: String,
                baseBranch: String, updatedAt: Date?, webURL: URL) {
        self.repo = repo
        self.number = number
        self.title = title
        self.author = author
        self.state = state
        self.isDraft = isDraft
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.updatedAt = updatedAt
        self.webURL = webURL
    }

    public var id: String { "\(repo.id)#\(number)" }
}

/// One review on a pull request. The same row is written by either host.
public struct ForgeReview: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        case approved
        case changesRequested
        case commented
        case dismissed
    }

    public let reviewer: String
    public let state: State
    public let body: String?
    public let submittedAt: Date?

    public init(reviewer: String, state: State, body: String?, submittedAt: Date?) {
        self.reviewer = reviewer
        self.state = state
        self.body = body
        self.submittedAt = submittedAt
    }
}

/// One check or job. `group` is GitHub's workflow name or gitboy's stage.
public struct ForgeCheck: Codable, Hashable, Sendable {
    public let name: String
    public let group: String?
    public let state: ForgeCheckState
    public let webURL: URL?
    public let seconds: Int?
    public let detail: String?

    public init(name: String, group: String?, state: ForgeCheckState,
                webURL: URL?, seconds: Int?, detail: String?) {
        self.name = name
        self.group = group
        self.state = state
        self.webURL = webURL
        self.seconds = seconds
        self.detail = detail
    }
}

/// Whether the base branch can take the head as it stands. `blocked` carries
/// the host's own sentences, so a screen shows why rather than guessing.
public enum ForgeMergeability: Codable, Hashable, Sendable {
    case clean
    case checking
    case conflicts
    case blocked([String])
    case notOpen
    case unknown(String?)
}

/// Everything a pull request screen reads, in one round of requests.
public struct ForgePullRequestDetail: Codable, Hashable, Sendable {
    public let pull: ForgePullRequest
    public let body: String
    public let headSHA: String
    /// Newest last, as both hosts' detail endpoints order them.
    public let reviews: [ForgeReview]
    public let reviewDecision: ForgeReviewDecision?
    public let mergeability: ForgeMergeability
    /// Sorted failing first, then by name.
    public let checks: [ForgeCheck]
    public let commits: Int?
    public let additions: Int?
    public let deletions: Int?
    public let changedFiles: Int?
    public let comments: Int?
    /// The merge that is queued to happen by itself; nil when none is.
    public let autoMerge: ForgeAutoMerge?

    public init(pull: ForgePullRequest, body: String, headSHA: String,
                reviews: [ForgeReview], reviewDecision: ForgeReviewDecision?,
                mergeability: ForgeMergeability, checks: [ForgeCheck],
                commits: Int?, additions: Int?, deletions: Int?,
                changedFiles: Int?, comments: Int?, autoMerge: ForgeAutoMerge? = nil) {
        self.pull = pull
        self.body = body
        self.headSHA = headSHA
        self.reviews = reviews
        self.reviewDecision = reviewDecision
        self.mergeability = mergeability
        self.checks = checks
        self.commits = commits
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.comments = comments
        self.autoMerge = autoMerge
    }
}

/// A merge the host will make by itself once the pull request's checks and
/// reviews allow it.
public struct ForgeAutoMerge: Codable, Hashable, Sendable {
    public let method: ForgeMergeMethod?
    /// Who queued it.
    public let requestedBy: String?
    /// Why it has not merged yet, in the host's words, when the host says.
    public let reason: String?

    public init(method: ForgeMergeMethod?, requestedBy: String?, reason: String?) {
        self.method = method
        self.requestedBy = requestedBy
        self.reason = reason
    }
}

/// What a merge attempt did. A refusal keeps the host's wording because the
/// fix ("Resolve merge conflicts", "2 approval(s) required") is in that text.
public enum ForgeMergeOutcome: Equatable, Sendable {
    case merged(sha: String?)
    case refused([String])
    case headMoved
}

/// A pull request's changes as one unified diff (`git diff` text). `headSHA`
/// is the commit the diff was computed at, when the host says: a screen that
/// reviews from this diff pins its review to that commit.
public struct ForgePullDiff: Codable, Hashable, Sendable {
    public let text: String
    public let headSHA: String?

    public init(text: String, headSHA: String?) {
        self.text = text
        self.headSHA = headSHA
    }
}
