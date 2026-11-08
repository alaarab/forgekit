import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Requests

/// The Actions half of ForgeKit's built-in GitHub transport: workflow runs,
/// their jobs, the re-run/cancel endpoints and job logs.
extension GitHubHTTPTransport {
    public func workflowRuns(owner: String, repo: String, branch: String?,
                      page: Int, perPage: Int) async throws -> [GitHubRunDTO] {
        var path = try Self.repoPath(owner: owner, repo: repo)
            + "/actions/runs?per_page=\(perPage)&page=\(max(1, page))"
        if let branch = Self.queryEncoded(branch) {
            path += "&branch=\(branch)"
        }
        return try await get(path, as: GitHubRunsPage.self).workflowRuns
    }

    public func workflowRun(owner: String, repo: String, runID: String) async throws -> GitHubRunDTO {
        let path = try Self.repoPath(owner: owner, repo: repo)
            + "/actions/runs/" + Self.encodePath(runID)
        return try await get(path, as: GitHubRunDTO.self)
    }

    /// `filter=latest` is the server's "newest attempt of each job name", so
    /// a re-run matrix does not arrive as two of everything. A run can still
    /// have more than 100 jobs, and only a short page ends the list.
    public func workflowRunJobs(owner: String, repo: String, runID: String) async throws -> [GitHubJobDTO] {
        let base = try Self.repoPath(owner: owner, repo: repo)
            + "/actions/runs/" + Self.encodePath(runID) + "/jobs"
        var jobs: [GitHubJobDTO] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let path = page == 1 ? base + "?per_page=100&filter=latest"
                                 : base + "?per_page=100&filter=latest&page=\(page)"
            let rows = try await get(path, as: GitHubJobsPage.self).jobs
            jobs += rows
            if rows.count < 100 { return jobs }
            page += 1
        }
    }

    public func rerunRun(owner: String, repo: String, runID: String) async throws {
        try await postAction(owner: owner, repo: repo,
                             suffix: "/actions/runs/" + Self.encodePath(runID) + "/rerun")
    }

    public func rerunFailedJobs(owner: String, repo: String, runID: String) async throws {
        try await postAction(owner: owner, repo: repo,
                             suffix: "/actions/runs/" + Self.encodePath(runID) + "/rerun-failed-jobs")
    }

    public func cancelRun(owner: String, repo: String, runID: String) async throws {
        try await postAction(owner: owner, repo: repo,
                             suffix: "/actions/runs/" + Self.encodePath(runID) + "/cancel")
    }

    /// GitHub re-runs a single job; it has no per-job cancel or play.
    public func rerunJob(owner: String, repo: String, jobID: String) async throws {
        try await postAction(owner: owner, repo: repo,
                             suffix: "/actions/jobs/" + Self.encodePath(jobID) + "/rerun")
    }

    private func postAction(owner: String, repo: String, suffix: String) async throws {
        let path = try Self.repoPath(owner: owner, repo: repo) + suffix
        let (data, http) = try await request(path, method: "POST")
        try Self.ensureOK(http, data: data, method: "POST", path: path)
    }

    /// A job's log. GitHub answers with a 302 to a signed blob on another
    /// host, so this is the one read that must not let the token travel:
    /// `GitHubRedirectPolicy` refuses any off-origin redirect, which leaves
    /// the 302 (and its `Location`) in hand, and the blob is then fetched with
    /// no credentials at all. Only https Locations are followed.
    public func jobLog(owner: String, repo: String, jobID: String) async throws -> String {
        let path = try Self.repoPath(owner: owner, repo: repo)
            + "/actions/jobs/" + Self.encodePath(jobID) + "/logs"
        let (data, http) = try await request(path)
        guard (300..<400).contains(http.statusCode) else {
            // Answered inline (a same-origin redirect was followed, or the
            // deployment serves logs directly): the body is the log.
            try Self.ensureOK(http, data: data, path: path)
            return String(decoding: data, as: UTF8.self)
        }
        guard let raw = http.value(forHTTPHeaderField: "Location"),
              let location = GitHubLogURL.signed(raw) else {
            throw GitHubError.invalidResponse
        }
        let (blob, blobResponse) = try await fetchWithoutCredentials(location)
        try Self.ensureOK(blobResponse, data: blob, path: path)
        return String(decoding: blob, as: UTF8.self)
    }

    /// The signed URL carries its own grant: no Authorization header, and no
    /// cache — the client's session is already ephemeral.
    private func fetchWithoutCredentials(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await networkSession.data(for: req,
                                                             delegate: GitHubHTTPSOnlyRedirectPolicy.shared)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        return (data, http)
    }

    /// Branch names carry `/` and `#`; neither may read as URL syntax inside a
    /// query value. The unreserved set matches `encodePath`'s.
    static func queryEncoded(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }
}
