import Foundation

// MARK: - Workflows

extension GitHubForge {
    private func workflowTransport() throws -> any GitHubWorkflowTransport {
        guard let transport = base as? any GitHubWorkflowTransport else {
            throw ForgeError.server(status: 0, message: "This GitHub client can't start workflows.")
        }
        return transport
    }

    /// The workflows GitHub has not disabled, by name. Its list does not say
    /// which ones accept a manual start or what inputs they take, and `ref`
    /// does not narrow it: starting one that has no `workflow_dispatch`
    /// trigger is refused with GitHub's own sentence.
    public func workflows(in repo: ForgeRepo, ref: String?) async throws -> [ForgeWorkflow] {
        let transport = try workflowTransport()
        let rows = try await github { try await transport.workflows(owner: repo.owner, repo: repo.name) }
        return rows
            .filter { ($0.state ?? "active").lowercased() == "active" }
            .map { row in
                ForgeWorkflow(repo: repo,
                              workflowID: String(row.id),
                              name: row.name.flatMap { $0.isEmpty ? nil : $0 } ?? row.path ?? "Workflow",
                              path: row.path,
                              inputs: [])
            }
            .sorted { $0.name == $1.name ? $0.workflowID < $1.workflowID : $0.name < $1.name }
    }

    /// GitHub accepts the request and says nothing about the run, so there is
    /// none to answer with: it shows up in `runs(in:branch:cursor:)` shortly.
    public func start(_ workflow: ForgeWorkflow, ref: String,
                      inputs: [String: String]) async throws -> ForgeRun? {
        let transport = try workflowTransport()
        try await github {
            try await transport.dispatchWorkflow(owner: workflow.repo.owner, repo: workflow.repo.name,
                                                 workflowID: workflow.workflowID, ref: ref, inputs: inputs)
        }
        return nil
    }
}

// MARK: - Pull requests that move by themselves

extension GitHubForge {
    private func automationTransport() throws -> any GitHubPullAutomationTransport {
        guard let transport = base as? any GitHubPullAutomationTransport else {
            throw ForgeError.server(status: 0,
                                    message: "This GitHub client can't queue merges or update branches.")
        }
        return transport
    }

    /// GitHub's mutations take the pull request's GraphQL id, which only the
    /// pull request itself carries.
    private func nodeID(of pull: ForgePullRequest) async throws -> String {
        let dto = try await client.pull(owner: pull.repo.owner, repo: pull.repo.name, number: pull.number)
        guard let id = dto.nodeID, !id.isEmpty else { throw ForgeError.invalidResponse }
        return id
    }

    public func enableAutoMerge(_ pull: ForgePullRequest, method: ForgeMergeMethod,
                                expectedHeadSHA: String) async throws {
        let transport = try automationTransport()
        let id = try await nodeID(of: pull)
        try await github {
            try await transport.setPullAutoMerge(pullNodeID: id, method: method,
                                                 expectedHeadSHA: expectedHeadSHA)
        }
    }

    public func disableAutoMerge(_ pull: ForgePullRequest) async throws {
        let transport = try automationTransport()
        let id = try await nodeID(of: pull)
        try await github {
            try await transport.setPullAutoMerge(pullNodeID: id, method: nil, expectedHeadSHA: nil)
        }
    }

    public func updateBranch(of pull: ForgePullRequest, expectedHeadSHA: String) async throws {
        let transport = try automationTransport()
        try await github {
            try await transport.updatePullBranch(owner: pull.repo.owner, repo: pull.repo.name,
                                                 number: pull.number, expectedHeadSHA: expectedHeadSHA)
        }
    }

    public func markReady(_ pull: ForgePullRequest) async throws {
        let transport = try automationTransport()
        let id = try await nodeID(of: pull)
        try await github { try await transport.markPullReady(pullNodeID: id) }
    }
}
