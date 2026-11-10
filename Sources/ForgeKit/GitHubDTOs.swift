import Foundation

// MARK: - Issues

struct GitHubIssueLabelDTO: Decodable, Sendable {
    let name: String?
    let color: String?
}

public struct GitHubIssueCommentDTO: Decodable, Sendable {
    let id: Int
    let user: GitHubPullActor?
    let body: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, user, body
        case createdAt = "created_at"
    }

    var date: Date? { ISO8601Dates.parse(createdAt) }
}

/// `pull_request` is a key whose value this client never reads: its presence
/// is the whole signal that an issue-list row is a pull request in disguise.
struct GitHubPullRequestMarker: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

public struct GitHubIssueDTO: Decodable, Sendable {
    let number: Int
    let title: String?
    let body: String?
    let user: GitHubPullActor?
    let state: String?
    let labels: [GitHubIssueLabelDTO]?
    let assignees: [GitHubPullActor]?
    let comments: Int?
    let updatedAt: String?
    let htmlURL: String?
    let pullRequest: GitHubPullRequestMarker?

    enum CodingKeys: String, CodingKey {
        case number, title, body, user, state, labels, assignees, comments
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
        case pullRequest = "pull_request"
    }

    var isPull: Bool { pullRequest != nil }
}

struct GitHubIssueSearchPage: Decodable, Sendable {
    let items: [GitHubIssueDTO]
}

// MARK: - Pull requests

/// One pull request as GitHub sends it. The list endpoint omits the detail
/// fields, so everything past the identity is optional and one shape serves
/// both calls.
public struct GitHubPullDTO: Decodable, Sendable {
    let number: Int
    let title: String
    let body: String?
    let user: GitHubPullActor?
    let state: String?
    let draft: Bool?
    let head: GitHubPullBranchRef?
    let base: GitHubPullBranchRef?
    let updatedAt: String?
    let htmlURL: String?
    let mergedAt: String?
    let mergeable: Bool?
    let mergeableState: String?
    let commits: Int?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let comments: Int?
    let reviewComments: Int?
    /// The GraphQL id, which the auto-merge and ready-for-review mutations take.
    let nodeID: String?
    let autoMerge: GitHubAutoMergeDTO?

    enum CodingKeys: String, CodingKey {
        case number, title, body, user, state, draft, head, base, commits, additions, deletions, comments
        case nodeID = "node_id"
        case autoMerge = "auto_merge"
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
        case mergedAt = "merged_at"
        case mergeable
        case mergeableState = "mergeable_state"
        case changedFiles = "changed_files"
        case reviewComments = "review_comments"
    }
}

struct GitHubPullActor: Decodable, Sendable {
    let login: String
}

/// `auto_merge` on a pull request: present while a merge is queued.
struct GitHubAutoMergeDTO: Decodable, Sendable {
    let mergeMethod: String?
    let enabledBy: GitHubPullActor?

    enum CodingKeys: String, CodingKey {
        case mergeMethod = "merge_method"
        case enabledBy = "enabled_by"
    }
}

/// One workflow in `GET repos/…/actions/workflows`.
public struct GitHubWorkflowDTO: Decodable, Sendable {
    let id: Int
    let name: String?
    let path: String?
    let state: String?
}

struct GitHubWorkflowsPage: Decodable, Sendable {
    let workflows: [GitHubWorkflowDTO]
}

struct GitHubPullBranchRef: Decodable, Sendable {
    let ref: String?
    let sha: String?

    enum CodingKeys: String, CodingKey { case ref, sha }
}

public struct GitHubPullReviewDTO: Decodable, Sendable {
    let user: GitHubPullActor?
    let state: String?
    let body: String?
    let submittedAt: String?

    enum CodingKeys: String, CodingKey {
        case user, state, body
        case submittedAt = "submitted_at"
    }

    var date: Date? { ISO8601Dates.parse(submittedAt) }
}

public struct GitHubCheckRunDTO: Decodable, Sendable {
    let name: String?
    let status: String?
    let conclusion: String?
    let htmlURL: String?
    let startedAt: String?
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case name, status, conclusion
        case htmlURL = "html_url"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

struct GitHubCheckRunsPage: Decodable, Sendable {
    let checkRuns: [GitHubCheckRunDTO]

    enum CodingKeys: String, CodingKey {
        case checkRuns = "check_runs"
    }
}

struct GitHubMergeResultDTO: Decodable, Sendable {
    let sha: String?
    let merged: Bool?
    let message: String?
}

// MARK: - Actions

/// One workflow run as GitHub sends it. The list endpoint omits nothing this
/// layer reads, so one shape serves the list and the detail call.
public struct GitHubRunDTO: Decodable, Sendable {
    let id: Int
    let runNumber: Int?
    let name: String?
    let displayTitle: String?
    let headBranch: String?
    let headSha: String?
    let event: String?
    let actor: GitHubPullActor?
    let status: String?
    let conclusion: String?
    let createdAt: String?
    let updatedAt: String?
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, event, actor, status, conclusion
        case runNumber = "run_number"
        case displayTitle = "display_title"
        case headBranch = "head_branch"
        case headSha = "head_sha"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
    }
}

struct GitHubRunsPage: Decodable, Sendable {
    let workflowRuns: [GitHubRunDTO]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

/// One job of a run. `run_attempt` is what makes the "latest attempt of each
/// name" rule checkable without another request.
public struct GitHubJobDTO: Decodable, Sendable {
    let id: Int
    let name: String?
    let status: String?
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?
    let runnerName: String?
    let htmlURL: String?
    let runAttempt: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case runnerName = "runner_name"
        case htmlURL = "html_url"
        case runAttempt = "run_attempt"
    }
}

struct GitHubJobsPage: Decodable, Sendable {
    let jobs: [GitHubJobDTO]
}

// MARK: - Runners

struct GitHubRunnerLabelDTO: Decodable, Sendable {
    let name: String?
}

public struct GitHubRunnerDTO: Decodable, Sendable {
    let id: Int
    let name: String?
    let os: String?
    let status: String?
    let busy: Bool?
    let labels: [GitHubRunnerLabelDTO]?
}

struct GitHubRunnersPage: Decodable, Sendable {
    let totalCount: Int?
    let runners: [GitHubRunnerDTO]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case runners
    }
}
