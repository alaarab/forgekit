import Foundation

// MARK: - Workflow rows

/// A string, a number or a boolean, read as text: a workflow input's default
/// is whichever its YAML wrote.
struct GitboyScalar: Decodable, Sendable {
    let text: String

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) {
            text = string
        } else if let bool = try? value.decode(Bool.self) {
            text = bool ? "true" : "false"
        } else if let int = try? value.decode(Int.self) {
            text = String(int)
        } else {
            text = String(try value.decode(Double.self))
        }
    }
}

struct GitboyWorkflowInputDTO: Decodable, Sendable {
    let description: String?
    let required: Bool?
    let defaultValue: GitboyScalar?
    let options: [String]?

    enum CodingKeys: String, CodingKey {
        case description, required, options
        case defaultValue = "default"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = c.lenient(.description)
        required = c.lenient(.required)
        defaultValue = c.lenient(.defaultValue)
        options = c.lenient(.options)
    }
}

/// One row of `GET ci/workflows`: an Actions workflow file in the repository.
struct GitboyWorkflowDTO: Decodable, Sendable {
    let path: String?
    let name: String?
    let dispatch: Bool?
    /// An input declared with no settings is a null here.
    let inputs: [String: GitboyWorkflowInputDTO?]?

    enum CodingKeys: String, CodingKey { case path, name, dispatch, inputs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.lenient(.path)
        name = c.lenient(.name)
        dispatch = c.lenient(.dispatch)
        inputs = c.lenient(.inputs)
    }

    /// nil for a workflow that cannot be started by hand, which is also how
    /// gitboy reports one it could not read.
    func forgeWorkflow(repo: ForgeRepo) -> ForgeWorkflow? {
        guard dispatch == true, let path = GitboyRunnerMapping.nonEmpty(path) else { return nil }
        let declared = (inputs ?? [:]).map { name, input in
            ForgeWorkflowInput(name: name,
                               description: GitboyRunnerMapping.nonEmpty(input?.description),
                               isRequired: input?.required == true,
                               defaultValue: input?.defaultValue?.text,
                               options: input?.options ?? [])
        }
        return ForgeWorkflow(repo: repo,
                             workflowID: path,
                             name: GitboyRunnerMapping.nonEmpty(name) ?? path,
                             path: path,
                             inputs: declared.sorted { $0.name < $1.name })
    }
}

// MARK: - Client

extension GitboyClient {
    /// The name a gitboy repository's own pipeline is listed under.
    static let ownPipelineName = "Pipeline"

    /// The repository's own pipeline first, then the Actions workflows that
    /// accept a manual start. gitboy starts its own pipeline when a request
    /// names no workflow, so that entry is always offered; a repository with
    /// nothing to run answers the start with the reason.
    public func workflows(in repo: ForgeRepo, ref: String?) async throws -> [ForgeWorkflow] {
        var query: [URLQueryItem] = []
        if let ref, !ref.isEmpty {
            query.append(URLQueryItem(name: "ref", value: ref))
        }
        let bearer = try authorization()
        let (data, _) = try await transport.send(Self.repoPath(repo) + "/ci/workflows",
                                                 query: query, bearer: bearer)
        guard let page = try? JSONDecoder().decode(GitboyPage<GitboyWorkflowDTO>.self, from: data) else {
            throw ForgeError.invalidResponse
        }
        let own = ForgeWorkflow(repo: repo, workflowID: "", name: Self.ownPipelineName,
                                path: nil, inputs: [])
        return [own] + page.items.compactMap { $0.forgeWorkflow(repo: repo) }
    }

    /// An Actions workflow takes `inputs`; the repository's own pipeline
    /// takes the same pairs as `variables`.
    public func start(_ workflow: ForgeWorkflow, ref: String,
                      inputs: [String: String]) async throws -> ForgeRun? {
        var payload: [String: Any] = ["ref": ref]
        if workflow.workflowID.isEmpty {
            if !inputs.isEmpty { payload["variables"] = inputs }
        } else {
            payload["workflow"] = workflow.workflowID
            if !inputs.isEmpty { payload["inputs"] = inputs }
        }
        let bearer = try authorization()
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await transport.send(Self.repoPath(workflow.repo) + "/pipelines",
                                                 method: "POST", body: body, bearer: bearer)
        guard let dto = try? JSONDecoder().decode(GitboyRunDTO.self, from: data) else {
            throw ForgeError.invalidResponse
        }
        return dto.forgeRun(repo: workflow.repo)
    }
}

// MARK: - Pull requests that move by themselves

extension GitboyClient {
    public func enableAutoMerge(_ pull: ForgePullRequest, method: ForgeMergeMethod,
                                expectedHeadSHA: String) async throws {
        // Refused here rather than as the server's "Validation failed".
        guard method != .rebase else {
            throw ForgeError.validation("gitboy can queue a merge or a squash, not a rebase.")
        }
        try await pullAction(pull, "auto-merge", method: "PUT", payload: [
            "method": method.rawValue,
            "expected_head_sha": expectedHeadSHA,
        ])
    }

    public func disableAutoMerge(_ pull: ForgePullRequest) async throws {
        try await pullAction(pull, "auto-merge", method: "DELETE", payload: nil)
    }

    public func updateBranch(of pull: ForgePullRequest, expectedHeadSHA: String) async throws {
        try await pullAction(pull, "update-branch", method: "POST",
                             payload: ["expected_head_sha": expectedHeadSHA])
    }

    public func markReady(_ pull: ForgePullRequest) async throws {
        try await pullAction(pull, "ready", method: "POST", payload: nil)
    }

    /// One write on a pull request. A head that moved since the screen read
    /// it comes back worded for the screen, as it does for a review.
    private func pullAction(_ pull: ForgePullRequest, _ action: String, method: String,
                            payload: [String: Any]?) async throws {
        let bearer = try authorization()
        let body = try payload.map { try JSONSerialization.data(withJSONObject: $0) }
        let (data, http) = try await transport.send(
            "\(Self.repoPath(pull.repo))/pulls/\(pull.number)/\(action)",
            method: method, body: body, bearer: bearer, validate: false)
        if (200..<300).contains(http.statusCode) { return }
        let error = GitboyTransport.error(status: http.statusCode, headers: http, data: data)
        if case .conflict(let message) = error,
           message.lowercased().hasPrefix("pull request head changed") {
            throw ForgeError.conflict("The branch moved. Reload and try again.")
        }
        throw error
    }
}
