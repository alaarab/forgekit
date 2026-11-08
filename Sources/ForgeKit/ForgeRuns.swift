import Foundation

/// One CI run: a GitHub Actions workflow run or a gitboy pipeline.
public enum ForgeRunStatus: String, Codable, Sendable {
    case queued
    case running
    case success
    case failed
    case canceled
    case skipped
    /// Blocked, manual, or waiting on an approval: the run is not over, so it
    /// is not queued for a runner yet.
    case waiting

    /// success, failed, canceled, skipped
    public var isTerminal: Bool {
        switch self {
        case .success, .failed, .canceled, .skipped: return true
        case .queued, .running, .waiting: return false
        }
    }
}

/// A run as a list row shows it. Both hosts answer with their own vocabulary;
/// this is the one shape a screen reads.
public struct ForgeRun: Codable, Hashable, Sendable, Identifiable {
    public let repo: ForgeRepo
    /// GitHub run id / gitboy pipeline iid, as a string.
    public let runID: String
    /// GitHub run_number / gitboy iid.
    public let number: Int?
    /// GitHub display_title or workflow name / gitboy "Pipeline #<iid>".
    public let title: String
    /// GitHub workflow name / gitboy workflow_path.
    public let workflow: String?
    public let branch: String?
    public let sha: String
    /// push, pull_request, manual, schedule...
    public let event: String?
    public let actor: String?
    public let status: ForgeRunStatus
    public let createdAt: Date?
    public let updatedAt: Date?
    public let webURL: URL

    public var id: String { "\(repo.id)/run/\(runID)" }

    public init(repo: ForgeRepo, runID: String, number: Int?, title: String, workflow: String?,
                branch: String?, sha: String, event: String?, actor: String?,
                status: ForgeRunStatus, createdAt: Date?, updatedAt: Date?, webURL: URL) {
        self.repo = repo
        self.runID = runID
        self.number = number
        self.title = title
        self.workflow = workflow
        self.branch = branch
        self.sha = sha
        self.event = event
        self.actor = actor
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.webURL = webURL
    }
}

/// One job inside a run: a GitHub Actions job or a gitboy pipeline job.
public struct ForgeJob: Codable, Hashable, Sendable, Identifiable {
    public let run: ForgeRun
    public let jobID: String
    public let name: String
    /// gitboy stage; GitHub nil.
    public let stage: String?
    public let status: ForgeRunStatus
    public let attempt: Int?
    public let allowFailure: Bool
    public let failureReason: String?
    public let startedAt: Date?
    public let finishedAt: Date?
    public let runnerName: String?
    public let webURL: URL

    public var id: String { "\(run.id)/job/\(jobID)" }

    public init(run: ForgeRun, jobID: String, name: String, stage: String?,
                status: ForgeRunStatus, attempt: Int?, allowFailure: Bool,
                failureReason: String?, startedAt: Date?, finishedAt: Date?,
                runnerName: String?, webURL: URL) {
        self.run = run
        self.jobID = jobID
        self.name = name
        self.stage = stage
        self.status = status
        self.attempt = attempt
        self.allowFailure = allowFailure
        self.failureReason = failureReason
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.runnerName = runnerName
        self.webURL = webURL
    }
}

/// A run with the jobs a screen lists. gitboy keeps every attempt of a job and
/// both hosts answer in their own order; the lists here are already the order a
/// screen draws.
public struct ForgeRunDetail: Codable, Hashable, Sendable {
    public let run: ForgeRun
    /// Every job the host returned, one per job: stage order (gitboy `stages`),
    /// then name. A matrix's jobs can share a display name, so the name is not
    /// what makes a job unique.
    public let jobs: [ForgeJob]
    public let canRerunAll: Bool
    public let canRetryFailed: Bool
    /// The run is not terminal.
    public let canCancel: Bool

    public init(run: ForgeRun, jobs: [ForgeJob], canRerunAll: Bool,
                canRetryFailed: Bool, canCancel: Bool) {
        self.run = run
        self.jobs = jobs
        self.canRerunAll = canRerunAll
        self.canRetryFailed = canRetryFailed
        self.canCancel = canCancel
    }
}

/// A chunk of a job log. `offset` is the byte offset of the next chunk to ask for.
public enum ForgeLogEvent: Equatable, Sendable {
    case text(String)
    case finished(ForgeRunStatus)
}

/// What a whole run can be asked to do. A host without the action refuses it;
/// the UI hides it first.
public enum ForgeRunAction: String, Sendable {
    case rerunAll
    case retryFailed
    case cancel
}

/// What one job can be asked to do.
public enum ForgeJobAction: String, Sendable {
    case retry
    case cancel
    case play
}
