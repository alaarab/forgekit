import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Workflows

extension GitHubHTTPTransport: GitHubWorkflowTransport {
    /// The first hundred workflows; a repository with more is rare enough
    /// that the list is not paged.
    public func workflows(owner: String, repo: String) async throws -> [GitHubWorkflowDTO] {
        let path = try Self.repoPath(owner: owner, repo: repo) + "/actions/workflows?per_page=100"
        return try await get(path, as: GitHubWorkflowsPage.self).workflows
    }

    /// GitHub answers 204 and says nothing about the run it started.
    public func dispatchWorkflow(owner: String, repo: String, workflowID: String,
                                 ref: String, inputs: [String: String]) async throws {
        var payload: [String: Any] = ["ref": ref]
        if !inputs.isEmpty { payload["inputs"] = inputs }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let path = try Self.repoPath(owner: owner, repo: repo)
            + "/actions/workflows/" + Self.encodePath(workflowID) + "/dispatches"
        let (data, http) = try await request(path, method: "POST", body: body)
        try Self.ensureOK(http, data: data, method: "POST", path: path)
    }
}

// MARK: - Pull request automation

extension GitHubHTTPTransport: GitHubPullAutomationTransport {
    public func updatePullBranch(owner: String, repo: String, number: Int,
                                 expectedHeadSHA: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["expected_head_sha": expectedHeadSHA])
        let path = try Self.repoPath(owner: owner, repo: repo) + "/pulls/\(number)/update-branch"
        let (data, http) = try await request(path, method: "PUT", body: body)
        try Self.ensureOK(http, data: data, method: "PUT", path: path)
    }

    public func setPullAutoMerge(pullNodeID: String, method: ForgeMergeMethod?,
                                 expectedHeadSHA: String?) async throws {
        guard let method else {
            try await graphQL("""
            mutation($id: ID!) {
              disablePullRequestAutoMerge(input: {pullRequestId: $id}) { clientMutationId }
            }
            """, variables: ["id": pullNodeID])
            return
        }
        var variables = ["id": pullNodeID, "method": method.rawValue.uppercased()]
        if let expectedHeadSHA, !expectedHeadSHA.isEmpty {
            variables["oid"] = expectedHeadSHA
        }
        try await graphQL("""
        mutation($id: ID!, $method: PullRequestMergeMethod!, $oid: GitObjectID) {
          enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: $method, expectedHeadOid: $oid}) {
            clientMutationId
          }
        }
        """, variables: variables)
    }

    public func markPullReady(pullNodeID: String) async throws {
        try await graphQL("""
        mutation($id: ID!) {
          markPullRequestReadyForReview(input: {pullRequestId: $id}) { clientMutationId }
        }
        """, variables: ["id": pullNodeID])
    }

    /// One GraphQL mutation. GitHub answers a refused mutation with 200 and
    /// an `errors` list, so that list is read as the failure it is.
    func graphQL(_ query: String, variables: [String: String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, http) = try await request("graphql", method: "POST", body: body)
        try Self.ensureOK(http, data: data, method: "POST", path: "graphql")
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let errors = json?["errors"] as? [[String: Any]], let first = errors.first else { return }
        let message = (first["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw GitHubError.http(status: 422, message: message.isEmpty ? "request failed" : message,
                               method: "POST", path: "graphql")
    }
}
