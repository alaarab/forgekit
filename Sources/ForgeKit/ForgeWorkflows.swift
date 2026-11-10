import Foundation

/// One input a workflow declares.
public struct ForgeWorkflowInput: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let description: String?
    public let isRequired: Bool
    public let defaultValue: String?
    /// The allowed values of a choice input; empty for free text.
    public let options: [String]

    public init(name: String, description: String?, isRequired: Bool,
                defaultValue: String?, options: [String]) {
        self.name = name
        self.description = description
        self.isRequired = isRequired
        self.defaultValue = defaultValue
        self.options = options
    }

    public var id: String { name }
}

/// Something a person can start in a repository: a GitHub Actions workflow,
/// or on gitboy either an Actions workflow or the repository's own pipeline.
public struct ForgeWorkflow: Codable, Hashable, Sendable, Identifiable {
    public let repo: ForgeRepo
    /// What `start` hands back to the host: GitHub's workflow id, gitboy's
    /// workflow path, or "" for a gitboy repository's own pipeline.
    public let workflowID: String
    public let name: String
    /// ".github/workflows/ci.yml"; nil for a gitboy repository's own pipeline.
    public let path: String?
    /// The inputs it declares, by name. GitHub's list does not carry them, so
    /// a GitHub workflow has none here; `start` still passes inputs along.
    public let inputs: [ForgeWorkflowInput]

    public init(repo: ForgeRepo, workflowID: String, name: String, path: String?,
                inputs: [ForgeWorkflowInput]) {
        self.repo = repo
        self.workflowID = workflowID
        self.name = name
        self.path = path
        self.inputs = inputs
    }

    public var id: String { "\(repo.id)/workflow/\(workflowID)" }
}
