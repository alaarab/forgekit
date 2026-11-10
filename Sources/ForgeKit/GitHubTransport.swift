import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The GitHub requests the forge layer makes. This is deliberately the whole
/// surface `GitHubForge` uses — no file contents, refs, or sign-in — so a host
/// app can conform its existing client with a set of forwards instead of
/// adopting ForgeKit's transport.
///
/// ForgeKit's own conformer is ``GitHubHTTPTransport``. A host app can
/// conform its existing client instead; see `PHRENKIT_ADAPTER.md`.
public protocol GitHubTransport: Sendable {
    // Identity + repos
    func currentUser() async throws -> GitHubUser
    func listRepos(page: Int, perPage: Int) async throws -> [GitHubRepo]

    // Issues
    func listIssues(owner: String, repo: String, state: ForgeStateFilter,
                    page: Int, perPage: Int) async throws -> [GitHubIssueDTO]
    func searchIssues(owner: String, repo: String, state: ForgeStateFilter,
                      query: String, page: Int, perPage: Int) async throws -> [GitHubIssueDTO]
    func issue(owner: String, repo: String, number: Int) async throws -> GitHubIssueDTO
    func issueComments(owner: String, repo: String, number: Int) async throws -> [GitHubIssueCommentDTO]
    func createIssue(owner: String, repo: String, title: String,
                     body: String) async throws -> GitHubIssueDTO
    func createIssueComment(owner: String, repo: String, number: Int,
                            body: String) async throws -> GitHubIssueCommentDTO
    func setIssueState(owner: String, repo: String, number: Int,
                       state: ForgeIssueState) async throws -> GitHubIssueDTO

    // Pull requests
    func listPulls(owner: String, repo: String, state: ForgeStateFilter,
                   page: Int, perPage: Int) async throws -> [GitHubPullDTO]
    func pull(owner: String, repo: String, number: Int) async throws -> GitHubPullDTO
    func pullReviews(owner: String, repo: String, number: Int) async throws -> [GitHubPullReviewDTO]
    func checkRuns(owner: String, repo: String, sha: String) async throws -> [GitHubCheckRunDTO]
    func mergePull(owner: String, repo: String, number: Int,
                   method: ForgeMergeMethod,
                   expectedHeadSHA: String) async throws -> (Data, HTTPURLResponse)
    func submitPullReview(owner: String, repo: String, number: Int,
                          event: String, body: String,
                          expectedHeadSHA: String) async throws
    /// The pull request's changes as one unified diff (added in 0.2.0).
    func pullDiff(owner: String, repo: String, number: Int) async throws -> String

    // Actions
    func workflowRuns(owner: String, repo: String, branch: String?,
                      page: Int, perPage: Int) async throws -> [GitHubRunDTO]
    func workflowRun(owner: String, repo: String, runID: String) async throws -> GitHubRunDTO
    func workflowRunJobs(owner: String, repo: String, runID: String) async throws -> [GitHubJobDTO]
    func rerunRun(owner: String, repo: String, runID: String) async throws
    func rerunFailedJobs(owner: String, repo: String, runID: String) async throws
    func cancelRun(owner: String, repo: String, runID: String) async throws
    func rerunJob(owner: String, repo: String, jobID: String) async throws
    func jobLog(owner: String, repo: String, jobID: String) async throws -> String

    // Runners
    func runners(scope: ForgeRunnerScope) async throws -> [GitHubRunnerDTO]
    func removeRunner(scope: ForgeRunnerScope, runnerID: String) async throws
}

// From 0.3.0 on, new GitHub requests arrive as protocols of their own. A
// transport that conforms gains the matching capabilities on `GitHubForge`;
// one that does not keeps compiling, and `GitHubForge` leaves those
// capabilities out. `GitHubHTTPTransport` conforms to all of them.

/// Listing and starting workflows.
public protocol GitHubWorkflowTransport: GitHubTransport {
    func workflows(owner: String, repo: String) async throws -> [GitHubWorkflowDTO]
    /// `workflowID` is the workflow's id or its file name.
    func dispatchWorkflow(owner: String, repo: String, workflowID: String,
                          ref: String, inputs: [String: String]) async throws
}

/// What moves a pull request along without a person watching it.
public protocol GitHubPullAutomationTransport: GitHubTransport {
    func updatePullBranch(owner: String, repo: String, number: Int,
                          expectedHeadSHA: String) async throws
    /// `method` nil turns auto-merge off. `pullNodeID` is the pull request's
    /// GraphQL id: GitHub has no REST call for either direction.
    func setPullAutoMerge(pullNodeID: String, method: ForgeMergeMethod?,
                          expectedHeadSHA: String?) async throws
    func markPullReady(pullNodeID: String) async throws
}
