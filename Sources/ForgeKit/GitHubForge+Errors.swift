import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ForgeError {
    /// A GitHub failure in the forge layer's cases, so a screen written
    /// against `ForgeError` handles either host the same way.
    public init(_ error: GitHubError) {
        switch error {
        case .notAuthenticated:
            self = .notSignedIn
        case .invalidResponse:
            self = .invalidResponse
        case .rateLimited(let resetAt, let retryAfter):
            // A secondary limit's delay is the one to wait out; the reset time
            // describes the hourly window.
            self = .rateLimited(until: retryAfter.map { Date().addingTimeInterval($0) } ?? resetAt)
        case .http(let status, let message, _, _):
            switch status {
            case 401:
                // GitHubError words this one as the fix: sign in again.
                self = .unauthorized(error.errorDescription ?? message)
            case 403:
                self = .unauthorized(error.isRepoAccessDenied ? (error.errorDescription ?? message) : message)
            case 404:
                // On a repository path GitHub's 404 is usually a token that
                // may not see the repository, and GitHubError says how to fix
                // that. A screen keeps that sentence instead of "not found".
                if error.isRepoAccessDenied, let explanation = error.errorDescription {
                    self = .unauthorized(explanation)
                } else {
                    self = .notFound
                }
            case 409:
                self = .conflict(message)
            default:
                self = .server(status: status, message: message)
            }
        case .shaConflict:
            self = .conflict(error.errorDescription ?? "")
        case .treeTruncated:
            self = .server(status: 0, message: error.errorDescription ?? "")
        }
    }
}

/// Forwards every request to the app's transport and rethrows what it fails
/// with as a `ForgeError`. A `ForgeError` the transport already threw, and
/// anything that is not a GitHub answer (a dropped connection, a cancelled
/// task), passes through untouched.
struct GitHubMappedTransport: GitHubTransport {
    let base: any GitHubTransport

    static func forgeError(_ error: Error) -> Error {
        if let github = error as? GitHubError { return ForgeError(github) }
        if error is DecodingError { return ForgeError.invalidResponse }
        return error
    }

    private func mapped<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            throw Self.forgeError(error)
        }
    }

    func currentUser() async throws -> GitHubUser {
        try await mapped { try await base.currentUser() }
    }

    func listRepos(page: Int, perPage: Int) async throws -> [GitHubRepo] {
        try await mapped { try await base.listRepos(page: page, perPage: perPage) }
    }

    func listIssues(owner: String, repo: String, state: ForgeStateFilter,
                    page: Int, perPage: Int) async throws -> [GitHubIssueDTO] {
        try await mapped {
            try await base.listIssues(owner: owner, repo: repo, state: state, page: page, perPage: perPage)
        }
    }

    func searchIssues(owner: String, repo: String, state: ForgeStateFilter,
                      query: String, page: Int, perPage: Int) async throws -> [GitHubIssueDTO] {
        try await mapped {
            try await base.searchIssues(owner: owner, repo: repo, state: state, query: query,
                                        page: page, perPage: perPage)
        }
    }

    func issue(owner: String, repo: String, number: Int) async throws -> GitHubIssueDTO {
        try await mapped { try await base.issue(owner: owner, repo: repo, number: number) }
    }

    func issueComments(owner: String, repo: String, number: Int) async throws -> [GitHubIssueCommentDTO] {
        try await mapped { try await base.issueComments(owner: owner, repo: repo, number: number) }
    }

    func createIssue(owner: String, repo: String, title: String,
                     body: String) async throws -> GitHubIssueDTO {
        try await mapped { try await base.createIssue(owner: owner, repo: repo, title: title, body: body) }
    }

    func createIssueComment(owner: String, repo: String, number: Int,
                            body: String) async throws -> GitHubIssueCommentDTO {
        try await mapped {
            try await base.createIssueComment(owner: owner, repo: repo, number: number, body: body)
        }
    }

    func setIssueState(owner: String, repo: String, number: Int,
                       state: ForgeIssueState) async throws -> GitHubIssueDTO {
        try await mapped { try await base.setIssueState(owner: owner, repo: repo, number: number, state: state) }
    }

    func listPulls(owner: String, repo: String, state: ForgeStateFilter,
                   page: Int, perPage: Int) async throws -> [GitHubPullDTO] {
        try await mapped {
            try await base.listPulls(owner: owner, repo: repo, state: state, page: page, perPage: perPage)
        }
    }

    func pull(owner: String, repo: String, number: Int) async throws -> GitHubPullDTO {
        try await mapped { try await base.pull(owner: owner, repo: repo, number: number) }
    }

    func pullReviews(owner: String, repo: String, number: Int) async throws -> [GitHubPullReviewDTO] {
        try await mapped { try await base.pullReviews(owner: owner, repo: repo, number: number) }
    }

    func checkRuns(owner: String, repo: String, sha: String) async throws -> [GitHubCheckRunDTO] {
        try await mapped { try await base.checkRuns(owner: owner, repo: repo, sha: sha) }
    }

    func mergePull(owner: String, repo: String, number: Int, method: ForgeMergeMethod,
                   expectedHeadSHA: String) async throws -> (Data, HTTPURLResponse) {
        try await mapped {
            try await base.mergePull(owner: owner, repo: repo, number: number, method: method,
                                     expectedHeadSHA: expectedHeadSHA)
        }
    }

    func submitPullReview(owner: String, repo: String, number: Int, event: String,
                          body: String, expectedHeadSHA: String) async throws {
        try await mapped {
            try await base.submitPullReview(owner: owner, repo: repo, number: number, event: event,
                                            body: body, expectedHeadSHA: expectedHeadSHA)
        }
    }

    func pullDiff(owner: String, repo: String, number: Int) async throws -> String {
        try await mapped { try await base.pullDiff(owner: owner, repo: repo, number: number) }
    }

    func workflowRuns(owner: String, repo: String, branch: String?,
                      page: Int, perPage: Int) async throws -> [GitHubRunDTO] {
        try await mapped {
            try await base.workflowRuns(owner: owner, repo: repo, branch: branch, page: page, perPage: perPage)
        }
    }

    func workflowRun(owner: String, repo: String, runID: String) async throws -> GitHubRunDTO {
        try await mapped { try await base.workflowRun(owner: owner, repo: repo, runID: runID) }
    }

    func workflowRunJobs(owner: String, repo: String, runID: String) async throws -> [GitHubJobDTO] {
        try await mapped { try await base.workflowRunJobs(owner: owner, repo: repo, runID: runID) }
    }

    func rerunRun(owner: String, repo: String, runID: String) async throws {
        try await mapped { try await base.rerunRun(owner: owner, repo: repo, runID: runID) }
    }

    func rerunFailedJobs(owner: String, repo: String, runID: String) async throws {
        try await mapped { try await base.rerunFailedJobs(owner: owner, repo: repo, runID: runID) }
    }

    func cancelRun(owner: String, repo: String, runID: String) async throws {
        try await mapped { try await base.cancelRun(owner: owner, repo: repo, runID: runID) }
    }

    func rerunJob(owner: String, repo: String, jobID: String) async throws {
        try await mapped { try await base.rerunJob(owner: owner, repo: repo, jobID: jobID) }
    }

    func jobLog(owner: String, repo: String, jobID: String) async throws -> String {
        try await mapped { try await base.jobLog(owner: owner, repo: repo, jobID: jobID) }
    }

    func runners(scope: ForgeRunnerScope) async throws -> [GitHubRunnerDTO] {
        try await mapped { try await base.runners(scope: scope) }
    }

    func removeRunner(scope: ForgeRunnerScope, runnerID: String) async throws {
        try await mapped { try await base.removeRunner(scope: scope, runnerID: runnerID) }
    }
}
