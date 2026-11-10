import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Paths and links

/// gitboy run links: the pipeline page, the job console behind it, and the
/// fallback for an older server that leaves `html_url` out of its answer.
enum GitboyRunURLs {
    static func pipeline(host: ForgeHost, owner: String, name: String, iid: Int) -> URL {
        URL(string: "https://\(host.domain)/\(segment(owner))/\(segment(name))/pipelines/\(iid)")
            ?? host.webBase
    }

    static func job(on pipeline: URL, jobID: String) -> URL {
        guard !jobID.isEmpty,
              var components = URLComponents(url: pipeline, resolvingAgainstBaseURL: false) else {
            return pipeline
        }
        components.queryItems = [URLQueryItem(name: "job", value: jobID)]
        return components.url ?? pipeline
    }

    private static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Requests that are not JSON

extension GitboyTransport {
    /// One API request with an explicit Accept header. `send` is JSON-only;
    /// job logs ask for text and the log stream asks for an event stream.
    /// Same base, bearer and origin check as `send`.
    func makeRequest(_ path: String, method: String = "GET",
                     query: [URLQueryItem] = [],
                     accept: String, bearer: String?) throws -> URLRequest {
        // Not appendingPathComponent: query strings would be percent-encoded.
        guard let base = URL(string: path, relativeTo: host.apiBase)?.absoluteURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ForgeError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url, GitboyRedirectPolicy.allows(url, host: host) else {
            throw ForgeError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

// MARK: - Run rows

struct GitboyRunJobDTO: Decodable, Sendable {
    let id: String?
    let name: String?
    let stage: String?
    let status: String?
    let attempt: Int?
    let allowFailure: Bool?
    let failureReason: String?
    let startedAt: String?
    let finishedAt: String?
    let runnerName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, stage, status, attempt
        case allowFailure = "allow_failure"
        case failureReason = "failure_reason"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case runnerName = "runner_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id)
        name = c.lenient(.name)
        stage = c.lenient(.stage)
        status = c.lenient(.status)
        attempt = c.lenient(.attempt)
        allowFailure = c.lenient(.allowFailure)
        failureReason = c.lenient(.failureReason)
        startedAt = c.lenient(.startedAt)
        finishedAt = c.lenient(.finishedAt)
        runnerName = c.lenient(.runnerName)
    }
}

/// One pipeline. The list endpoint and the detail endpoint answer the same
/// fields; only the detail carries `jobs` and `stages`.
struct GitboyRunDTO: Decodable, Sendable {
    let iid: Int?
    let sha: String?
    let ref: String?
    let status: String?
    let source: String?
    let authorUsername: String?
    let workflowPath: String?
    let createdAt: String?
    let finishedAt: String?
    let updatedAt: String?
    let htmlURL: String?
    let jobs: [GitboyRunJobDTO]?
    let stages: [String]?

    enum CodingKeys: String, CodingKey {
        case iid, sha, ref, status, source, jobs, stages
        case authorUsername = "author_username"
        case workflowPath = "workflow_path"
        case createdAt = "created_at"
        case finishedAt = "finished_at"
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iid = c.lenient(.iid)
        sha = c.lenient(.sha)
        ref = c.lenient(.ref)
        status = c.lenient(.status)
        source = c.lenient(.source)
        authorUsername = c.lenient(.authorUsername)
        workflowPath = c.lenient(.workflowPath)
        createdAt = c.lenient(.createdAt)
        finishedAt = c.lenient(.finishedAt)
        updatedAt = c.lenient(.updatedAt)
        htmlURL = c.lenient(.htmlURL)
        jobs = c.lenient(.jobs)
        stages = c.lenient(.stages)
    }
}

// MARK: - Mapping

extension GitboyRunDTO {
    /// nil only when the row carries no iid at all: nothing can link to it.
    /// The detail endpoint is called with the iid in the path, so that number
    /// stands in for an older server that leaves it out of the body.
    func forgeRun(repo: ForgeRepo, fallbackIID: Int? = nil) -> ForgeRun? {
        guard let iid = iid ?? fallbackIID else { return nil }
        return ForgeRun(repo: repo,
                        runID: String(iid),
                        number: iid,
                        title: "Pipeline #\(iid)",
                        workflow: Self.trimmed(workflowPath, limit: 200),
                        branch: Self.branch(ref),
                        sha: sha ?? "",
                        event: Self.trimmed(source),
                        actor: Self.trimmed(authorUsername),
                        status: GitboyClient.runStatus(status),
                        createdAt: ISO8601Dates.parse(createdAt),
                        // A finished pipeline's finish is its last update; a
                        // running one only has updated_at.
                        updatedAt: ISO8601Dates.parse(finishedAt) ?? ISO8601Dates.parse(updatedAt),
                        webURL: Self.webLink(htmlURL)
                            ?? GitboyRunURLs.pipeline(host: repo.host, owner: repo.owner,
                                                      name: repo.name, iid: iid))
    }

    /// `refs/heads/main` is the branch `main`.
    static func branch(_ ref: String?) -> String? {
        guard let ref, !ref.isEmpty else { return nil }
        return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }

    private static func trimmed(_ raw: String?, limit: Int = 200) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return String(raw.prefix(limit))
    }

    /// Only http(s) links are taken from the server; anything else would put an
    /// unchecked scheme behind a tap.
    static func webLink(_ raw: String?) -> URL? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let lowered = value.lowercased()
        guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://"),
              let url = URL(string: value), url.host != nil else { return nil }
        return url
    }
}

extension GitboyRunJobDTO {
    func forgeJob(run: ForgeRun, pipelineURL: URL) -> ForgeJob {
        let jobID = (id?.isEmpty == false) ? (id ?? "") : ""
        return ForgeJob(run: run,
                        jobID: jobID,
                        name: Self.trimmed(name) ?? "Job",
                        stage: Self.trimmed(stage),
                        status: GitboyClient.runStatus(status),
                        attempt: attempt,
                        allowFailure: allowFailure == true,
                        failureReason: Self.trimmed(failureReason, limit: 300),
                        startedAt: ISO8601Dates.parse(startedAt),
                        finishedAt: ISO8601Dates.parse(finishedAt),
                        runnerName: Self.trimmed(runnerName),
                        webURL: GitboyRunURLs.job(on: pipelineURL, jobID: jobID))
    }

    private static func trimmed(_ raw: String?, limit: Int = 200) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return String(raw.prefix(limit))
    }
}

// MARK: - Client

extension GitboyClient {
    public func runs(in repo: ForgeRepo, branch: String?, cursor: String?) async throws -> ForgePage<ForgeRun> {
        var query = [
            // `paginated=true` asks for {items, next_cursor}; an older gitboy
            // ignores it and answers a bare array, which decodes the same.
            URLQueryItem(name: "paginated", value: "true"),
            URLQueryItem(name: "limit", value: "30"),
        ]
        if let branch, !branch.isEmpty {
            query.append(URLQueryItem(name: "branch", value: branch))
        }
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let bearer = try authorization()
        let (data, _) = try await transport.send(Self.repoPath(repo) + "/pipelines",
                                                 query: query, bearer: bearer)
        guard let page = try? JSONDecoder().decode(GitboyPage<GitboyRunDTO>.self, from: data) else {
            throw ForgeError.invalidResponse
        }
        // An empty cursor is "no more pages", the same as null.
        let next = (page.nextCursor?.isEmpty == false) ? page.nextCursor : nil
        return ForgePage(items: page.items.compactMap { $0.forgeRun(repo: repo) }, next: next)
    }

    public func run(in repo: ForgeRepo, id runID: String) async throws -> ForgeRunDetail {
        let bearer = try authorization()
        let (data, _) = try await transport.send(
            "\(Self.repoPath(repo))/pipelines/\(Self.runSegment(runID))", bearer: bearer)
        guard let dto = try? JSONDecoder().decode(GitboyRunDTO.self, from: data),
              let run = dto.forgeRun(repo: repo, fallbackIID: Int(runID)) else {
            throw ForgeError.invalidResponse
        }
        let jobs = Self.newestJobs(dto.jobs ?? [], stages: dto.stages ?? [])
            .map { $0.forgeJob(run: run, pipelineURL: run.webURL) }
        return ForgeRunDetail(run: run,
                              jobs: jobs,
                              // gitboy re-runs a pipeline by its jobs; there is
                              // no whole-run re-run to ask for.
                              canRerunAll: false,
                              canRetryFailed: jobs.contains { $0.status == .failed },
                              canCancel: !run.status.isTerminal)
    }

    public func perform(_ action: ForgeRunAction, on run: ForgeRun) async throws {
        switch action {
        case .rerunAll:
            throw ForgeError.server(status: 0, message: "gitboy can't re-run a whole pipeline.")
        case .retryFailed:
            try await post("\(Self.repoPath(run.repo))/pipelines/\(Self.runSegment(run.runID))/retry-failed")
        case .cancel:
            try await post("\(Self.repoPath(run.repo))/pipelines/\(Self.runSegment(run.runID))/cancel")
        }
    }

    public func perform(_ action: ForgeJobAction, on job: ForgeJob) async throws {
        guard !job.jobID.isEmpty else { throw ForgeError.invalidResponse }
        let endpoint: String
        switch action {
        case .retry: endpoint = "retry"
        case .cancel: endpoint = "cancel"
        case .play: endpoint = "play"
        }
        try await post("\(Self.repoPath(job.run.repo))/jobs/\(Self.runSegment(job.jobID))/\(endpoint)")
    }

    public func log(of job: ForgeJob) async throws -> String {
        guard !job.jobID.isEmpty else { throw ForgeError.invalidResponse }
        let bearer = try authorization()
        // A job route is repo-scoped in gitboy, the same as the pipeline calls.
        let request = try transport.makeRequest(
            "\(Self.repoPath(job.run.repo))/jobs/\(Self.runSegment(job.jobID))/log",
            accept: "text/plain", bearer: bearer)
        // The same origin pinning as `send`: a log is never fetched from a host
        // the bearer token was not issued for.
        let (data, response) = try await transport.session.data(
            for: request, delegate: GitboyRedirectPolicy(host: host))
        guard let http = response as? HTTPURLResponse else { throw ForgeError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GitboyTransport.error(status: http.statusCode, headers: http, data: data)
        }
        return ForgeLogTrim.lastBytes(String(decoding: data, as: UTF8.self))
    }

    /// Live log over gitboy's SSE endpoint. The stream is re-opened once, from
    /// the last byte delivered, if the connection drops before `done`.
    public nonisolated func liveLog(of job: ForgeJob) -> AsyncThrowingStream<ForgeLogEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ForgeLogEvent, Error>.makeStream()
        let id = UUID()
        let worker = Task { await self.streamLog(id: id, of: job, into: continuation) }
        continuation.onTermination = { _ in worker.cancel() }
        return stream
    }
}

// MARK: - Internals

extension GitboyClient {
    /// gitboy job status words, in this layer's cases. An unknown word is
    /// queued: it is not a terminal state, so the UI keeps polling.
    static func runStatus(_ raw: String?) -> ForgeRunStatus {
        switch (raw ?? "").lowercased() {
        case "created", "queued", "pending", "claimed": return .queued
        case "running": return .running
        case "success": return .success
        case "failed", "error": return .failed
        case "canceled", "cancelled": return .canceled
        case "skipped": return .skipped
        case "blocked", "manual", "waiting": return .waiting
        default: return .queued
        }
    }

    /// The newest attempt of each job name, in stage order (a stage the
    /// pipeline does not list sorts last), then by name.
    static func newestJobs(_ jobs: [GitboyRunJobDTO],
                           stages: [String]) -> [GitboyRunJobDTO] {
        var newest: [String: GitboyRunJobDTO] = [:]
        for job in jobs {
            let name = Self.jobName(job.name)
            if let seen = newest[name], (job.attempt ?? 0) < (seen.attempt ?? 0) { continue }
            newest[name] = job
        }
        func rank(_ stage: String?) -> Int {
            guard let stage, let index = stages.firstIndex(of: stage) else { return stages.count }
            return index
        }
        return newest.values.sorted { lhs, rhs in
            let left = rank(lhs.stage)
            let right = rank(rhs.stage)
            if left != right { return left < right }
            return Self.jobName(lhs.name) < Self.jobName(rhs.name)
        }
    }

    private static func jobName(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "Job"
        }
        return raw
    }

    private static func runSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func post(_ path: String) async throws {
        let bearer = try authorization()
        _ = try await transport.send(path, method: "POST", bearer: bearer)
    }

    /// Pumps one connection into `continuation`. Returns true when the server
    /// said `done`; false when the connection ended without one.
    private func pumpLog(of job: ForgeJob, bearer: String, from offset: Int,
                         into continuation: AsyncThrowingStream<ForgeLogEvent, Error>.Continuation,
                         lastNext: inout Int) async throws -> Bool {
        var query: [URLQueryItem] = []
        if offset > 0 {
            query.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        let request = try transport.makeRequest(
            "\(Self.repoPath(job.run.repo))/jobs/\(Self.runSegment(job.jobID))/log/stream",
            query: query,
            accept: "text/event-stream", bearer: bearer)
        let (bytes, response) = try await transport.session.forgeBytes(
            for: request, delegate: GitboyRedirectPolicy(host: host))
        guard let http = response as? HTTPURLResponse else { throw ForgeError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // A refusal is a small JSON body; read it so the screen can say why.
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 65_536 { break }
            }
            throw GitboyTransport.error(status: http.statusCode, headers: http, data: body)
        }

        var parser = ForgeSSEParser()
        for try await byte in bytes {
            guard let event = try parser.feed(byte) else { continue }
            if try forward(event, into: continuation, lastNext: &lastNext) { return true }
        }
        // A server that closes right after `done` without the dispatching blank
        // line still ends this stream as finished, not as a dropped socket.
        if let event = try parser.finish(),
           try forward(event, into: continuation, lastNext: &lastNext) {
            return true
        }
        return false
    }

    /// One parsed event into the stream. Returns true when the server said
    /// `done` and the stream is finished.
    private func forward(_ event: ForgeSSEEvent,
                         into continuation: AsyncThrowingStream<ForgeLogEvent, Error>.Continuation,
                         lastNext: inout Int) throws -> Bool {
        guard let decoded = try ForgeLogStreamEvent(event) else { return false }
        switch decoded {
        case .chunk(_, let next, let text):
            // After a reconnect an exact replay is harmless; a chunk whose
            // end this client already has is dropped.
            guard next > lastNext else { return false }
            lastNext = next
            continuation.yield(.text(text))
            return false
        case .done(let status):
            // Two of gitboy's closing words are not job statuses: the token
            // lost its access while the log was being read, or the job is gone.
            switch status.lowercased() {
            case "timeout":
                // The server closes a long stream on a time limit. The job is
                // not over: pick the log up again from the last byte read.
                throw GitboyStreamTimeout()
            case "access_revoked":
                throw ForgeError.unauthorized("Access to this job's log was revoked.")
            case "deleted":
                // The job was removed while its log was being read.
                throw ForgeError.notFound
            default:
                break
            }
            continuation.yield(.finished(Self.runStatus(status)))
            continuation.finish()
            return true
        }
    }

    private func streamLog(id: UUID, of job: ForgeJob,
                           into continuation: AsyncThrowingStream<ForgeLogEvent, Error>.Continuation) async {
        guard !job.jobID.isEmpty else {
            continuation.finish(throwing: ForgeError.invalidResponse)
            return
        }
        // Held so `invalidate()` can end this stream and its task: finishing the
        // continuation runs `onTermination`, which cancels the worker.
        guard !invalidated else {
            continuation.finish(throwing: ForgeError.notSignedIn)
            return
        }
        logStreams[id] = continuation
        defer { logStreams[id] = nil }
        do {
            var next = 0
            // A dropped connection is retried once. A stream the server closed
            // on its time limit is not a failure and is always picked up again.
            var failures = 0
            while true {
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                // A reconnect after `invalidate()` is signed out, not retried
                // with the token this stream started with.
                guard !invalidated else { throw ForgeError.notSignedIn }
                // Read at reconnect time, never a copy taken when the stream
                // began.
                let bearer = try authorization()
                do {
                    if try await pumpLog(of: job, bearer: bearer, from: next,
                                         into: continuation, lastNext: &next) {
                        return
                    }
                    // Ended without `done`.
                    if failures >= 1 { throw ForgeError.invalidResponse }
                } catch is GitboyStreamTimeout {
                    continue
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    // The server's own refusal is its answer, not a dropped
                    // socket: only a transport failure is worth one retry.
                    if error is ForgeError || failures >= 1 { throw error }
                }
                failures += 1
            }
        } catch {
            if let forge = error as? ForgeError {
                continuation.finish(throwing: forge)
            } else {
                continuation.finish(throwing: ForgeError.invalidResponse)
            }
        }
    }
}

/// gitboy closed a log stream on its time limit; the job is still running.
struct GitboyStreamTimeout: Error {}
