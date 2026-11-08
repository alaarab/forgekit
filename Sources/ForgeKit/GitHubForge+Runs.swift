import Foundation

// MARK: - Mapping

extension GitHubRunDTO {
    /// GitHub splits a run's outcome across two words: while it is unfinished
    /// only `status` is set, and once completed the meaning moves to
    /// `conclusion`. Only a completed run's conclusion is read.
    static func forgeStatus(status: String?, conclusion: String?) -> ForgeRunStatus {
        switch (status ?? "").lowercased() {
        case "queued", "requested", "pending":
            return .queued
        case "waiting":
            return .waiting
        case "in_progress":
            return .running
        case "completed":
            switch (conclusion ?? "").lowercased() {
            case "success":
                return .success
            case "failure", "timed_out", "startup_failure", "stale":
                return .failed
            case "cancelled", "canceled":
                return .canceled
            case "skipped", "neutral":
                return .skipped
            case "action_required":
                return .waiting
            default:
                return .failed
            }
        default:
            return .queued
        }
    }

    var forgeStatus: ForgeRunStatus { Self.forgeStatus(status: status, conclusion: conclusion) }

    func forgeRun(repo: ForgeRepo) -> ForgeRun {
        let workflow = name.flatMap(Self.text)
        let display = displayTitle.flatMap(Self.text)
        let fallbackNumber = runNumber.map { String($0) } ?? String(id)
        let webURL = htmlURL.flatMap(Self.webLink)
            ?? URL(string: "https://github.com/\(repo.owner)/\(repo.name)/actions/runs/\(id)")
            ?? repo.webURL
        return ForgeRun(repo: repo,
                        runID: String(id),
                        number: runNumber,
                        title: display ?? workflow ?? "Run \(fallbackNumber)",
                        workflow: workflow,
                        branch: headBranch.flatMap(Self.text),
                        sha: headSha ?? "",
                        event: event.flatMap(Self.text),
                        actor: actor?.login,
                        status: forgeStatus,
                        createdAt: ISO8601Dates.parse(createdAt),
                        updatedAt: ISO8601Dates.parse(updatedAt),
                        webURL: webURL)
    }

    /// Trimmed, or nil when the server sent nothing useful.
    static func text(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Only links with a host are taken from the server; the rest fall back to
    /// the run's canonical GitHub URL.
    static func webLink(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value), url.host != nil else { return nil }
        return url
    }
}

extension GitHubJobDTO {
    var forgeStatus: ForgeRunStatus {
        GitHubRunDTO.forgeStatus(status: status, conclusion: conclusion)
    }

    func forgeJob(run: ForgeRun) -> ForgeJob {
        ForgeJob(run: run,
                 jobID: String(id),
                 name: GitHubRunDTO.text(name ?? "") ?? "Job",
                 stage: nil,
                 status: forgeStatus,
                 attempt: runAttempt,
                 allowFailure: false,
                 failureReason: nil,
                 startedAt: ISO8601Dates.parse(startedAt),
                 finishedAt: ISO8601Dates.parse(completedAt),
                 runnerName: runnerName.flatMap(GitHubRunDTO.text),
                 webURL: htmlURL.flatMap(GitHubRunDTO.webLink) ?? run.webURL)
    }
}

// MARK: - Forge conformance

extension GitHubForge {
    /// Matches the API contract's `per_page=30`; a full page may have another
    /// behind it, a short page is the end.
    private static let runsPerPage = 30
    /// GitHub serves a job's log only once the job is finished.
    private static let liveLogPollNanos: UInt64 = 5_000_000_000

    public func runs(in repo: ForgeRepo, branch: String?,
                     cursor: String?) async throws -> ForgePage<ForgeRun> {
        let page = max(1, Int(cursor ?? "") ?? 1)
        let rows = try await client.workflowRuns(owner: repo.owner, repo: repo.name,
                                                 branch: branch, page: page,
                                                 perPage: Self.runsPerPage)
        let next = rows.count < Self.runsPerPage ? nil : String(page + 1)
        return ForgePage(items: rows.map { $0.forgeRun(repo: repo) }, next: next)
    }

    public func run(in repo: ForgeRepo, id runID: String) async throws -> ForgeRunDetail {
        let dto = try await client.workflowRun(owner: repo.owner, repo: repo.name, runID: runID)
        let run = dto.forgeRun(repo: repo)
        let rows = try await client.workflowRunJobs(owner: repo.owner, repo: repo.name, runID: runID)
        let jobs = Self.forgeJobs(rows, run: run)
        let failed = jobs.contains { $0.status == .failed }
        return ForgeRunDetail(run: run,
                              jobs: jobs,
                              canRerunAll: run.status.isTerminal,
                              canRetryFailed: run.status.isTerminal && failed,
                              canCancel: !run.status.isTerminal)
    }

    /// Every job GitHub returns, deduped by job id alone: `filter=latest` has
    /// already picked the newest attempt of each job, and a matrix runs several
    /// jobs under one display name, so a name is never a key. Sorted by name
    /// then job id, so the order never depends on the JSON order.
    static func forgeJobs(_ rows: [GitHubJobDTO], run: ForgeRun) -> [ForgeJob] {
        var byID: [String: ForgeJob] = [:]
        for row in rows {
            let job = row.forgeJob(run: run)
            byID[job.jobID] = job
        }
        return byID.values.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.jobID < rhs.jobID : lhs.name < rhs.name
        }
    }

    public func perform(_ action: ForgeRunAction, on run: ForgeRun) async throws {
        switch action {
        case .rerunAll:
            try await client.rerunRun(owner: run.repo.owner, repo: run.repo.name, runID: run.runID)
        case .retryFailed:
            try await client.rerunFailedJobs(owner: run.repo.owner, repo: run.repo.name, runID: run.runID)
        case .cancel:
            try await client.cancelRun(owner: run.repo.owner, repo: run.repo.name, runID: run.runID)
        }
    }

    public func perform(_ action: ForgeJobAction, on job: ForgeJob) async throws {
        switch action {
        case .retry:
            try await client.rerunJob(owner: job.run.repo.owner, repo: job.run.repo.name, jobID: job.jobID)
        case .cancel:
            // GitHub's Actions API has no per-job cancel; the run is the unit.
            throw ForgeError.server(status: 0, message: "GitHub can't cancel a single job.")
        case .play:
            throw ForgeError.server(status: 0, message: "GitHub can't start a job that's waiting.")
        }
    }

    public func log(of job: ForgeJob) async throws -> String {
        let text = try await client.jobLog(owner: job.run.repo.owner, repo: job.run.repo.name,
                                           jobID: job.jobID)
        return ForgeLogTrim.lastBytes(text)
    }

    /// GitHub has no streamed logs: while the job is unfinished this yields
    /// nothing and polls the run every 5 s, then yields the whole log once and
    /// `.finished`. The UI keeps the same two events either way.
    public func liveLog(of job: ForgeJob) -> AsyncThrowingStream<ForgeLogEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var status = job.status
                    while !status.isTerminal {
                        try await Task.sleep(nanoseconds: Self.liveLogPollNanos)
                        let detail = try await self.run(in: job.run.repo, id: job.run.runID)
                        status = detail.jobs.first { $0.jobID == job.jobID }?.status ?? detail.run.status
                    }
                    let text = try await self.log(of: job)
                    if !text.isEmpty { continuation.yield(.text(text)) }
                    continuation.yield(.finished(status))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
