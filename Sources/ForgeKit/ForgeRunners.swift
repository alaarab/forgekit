import Foundation

/// Where a runner fleet is registered. gitboy scopes a runner to one person,
/// an organization or a repository; GitHub only ever answers the last two.
public enum ForgeRunnerScope: Codable, Hashable, Sendable {
    /// gitboy: the signed-in user's own runners (/api/v1/user/runners).
    case mine
    case repo(owner: String, name: String)
    case org(String)
}

/// A job a runner is executing right now, in the host's own words. GitHub
/// doesn't say, so its runners always carry an empty list.
public struct ForgeRunnerJob: Codable, Hashable, Sendable, Identifiable {
    public let jobID: String
    public let name: String
    /// The host's status word: "running", "claimed", …
    public let status: String
    /// "owner/name"
    public let repository: String?
    /// gitboy's pipeline_iid; the `?job=` page a person can open.
    public let runNumber: Int?
    public let startedAt: Date?
    public let webURL: URL?

    public var id: String { jobID }

    public init(jobID: String, name: String, status: String, repository: String?,
                runNumber: Int?, startedAt: Date?, webURL: URL?) {
        self.jobID = jobID
        self.name = name
        self.status = status
        self.repository = repository
        self.runNumber = runNumber
        self.startedAt = startedAt
        self.webURL = webURL
    }
}

/// One CI runner, normalized so a fleet list renders either host.
public struct ForgeRunner: Codable, Hashable, Sendable, Identifiable {
    public let host: ForgeHost
    public let scope: ForgeRunnerScope
    public let runnerID: String
    public let name: String
    public let labels: [String]
    /// gitboy: `last_seen_at` within 120 s and status != "offline";
    /// GitHub: status == "online".
    public let isOnline: Bool
    /// gitboy: status == "paused"; GitHub: always false.
    public let isPaused: Bool
    public let isBusy: Bool
    public let lastSeenAt: Date?
    public let version: String?
    /// GitHub's `os`; gitboy's `host` (the machine name it reports).
    public let os: String?
    public let capacity: Int?
    public let isEphemeral: Bool
    /// GitHub: always empty — the API doesn't say.
    public let currentJobs: [ForgeRunnerJob]

    public var id: String { "\(host.id)/runner/\(runnerID)" }

    public init(host: ForgeHost, scope: ForgeRunnerScope, runnerID: String, name: String,
                labels: [String], isOnline: Bool, isPaused: Bool, isBusy: Bool,
                lastSeenAt: Date?, version: String?, os: String?, capacity: Int?,
                isEphemeral: Bool, currentJobs: [ForgeRunnerJob]) {
        self.host = host
        self.scope = scope
        self.runnerID = runnerID
        self.name = name
        self.labels = labels
        self.isOnline = isOnline
        self.isPaused = isPaused
        self.isBusy = isBusy
        self.lastSeenAt = lastSeenAt
        self.version = version
        self.os = os
        self.capacity = capacity
        self.isEphemeral = isEphemeral
        self.currentJobs = currentJobs
    }
}
