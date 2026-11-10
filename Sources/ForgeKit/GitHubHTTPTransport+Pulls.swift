import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Requests

/// The pull-request half of ForgeKit's built-in GitHub transport.
extension GitHubHTTPTransport {
    public func listPulls(owner: String, repo: String, state: ForgeStateFilter,
                   page: Int, perPage: Int) async throws -> [GitHubPullDTO] {
        let path = try Self.repoPath(owner: owner, repo: repo)
            + "/pulls?state=\(state.rawValue)&per_page=\(perPage)&page=\(max(1, page))"
        return try await get(path, as: [GitHubPullDTO].self)
    }

    public func pull(owner: String, repo: String, number: Int) async throws -> GitHubPullDTO {
        let path = try Self.repoPath(owner: owner, repo: repo) + "/pulls/\(number)"
        return try await get(path, as: GitHubPullDTO.self)
    }

    /// Oldest first, as GitHub returns them; the order decides review verdicts.
    /// Every page is read: a pull request re-reviewed past 100 times carries
    /// verdicts on the pages behind the first.
    public func pullReviews(owner: String, repo: String, number: Int) async throws -> [GitHubPullReviewDTO] {
        let base = try Self.repoPath(owner: owner, repo: repo) + "/pulls/\(number)/reviews"
        var reviews: [GitHubPullReviewDTO] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let rows = try await get(page == 1 ? base + "?per_page=100"
                                              : base + "?per_page=100&page=\(page)",
                                     as: [GitHubPullReviewDTO].self)
            reviews += rows
            // A short page is the last one.
            if rows.count < 100 { return reviews }
            page += 1
        }
    }

    /// Check runs for one commit. A token without Checks access is refused
    /// here rather than anywhere else, so callers may treat failure as "none".
    public func checkRuns(owner: String, repo: String, sha: String) async throws -> [GitHubCheckRunDTO] {
        let path = try Self.repoPath(owner: owner, repo: repo)
            + "/commits/" + Self.encodePath(sha) + "/check-runs?per_page=100"
        return try await get(path, as: GitHubCheckRunsPage.self).checkRuns
    }

    /// Returns the raw answer: 409 means the head moved and 405 means a
    /// blocker, and both are outcomes the caller reports, not errors.
    public func mergePull(owner: String, repo: String, number: Int,
                   method: ForgeMergeMethod, expectedHeadSHA: String) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONSerialization.data(withJSONObject: [
            "merge_method": method.rawValue,
            "sha": expectedHeadSHA,
        ])
        let path = try Self.repoPath(owner: owner, repo: repo) + "/pulls/\(number)/merge"
        return try await request(path, method: "PUT", body: body)
    }

    /// `event` is APPROVE, REQUEST_CHANGES or COMMENT. `expectedHeadSHA` is
    /// sent as `commit_id`, so a head that moved is a 422 rather than a review
    /// on a commit nobody read.
    public func submitPullReview(owner: String, repo: String, number: Int,
                          event: String, body: String,
                          expectedHeadSHA: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "event": event,
            "body": body,
            "commit_id": expectedHeadSHA,
        ])
        let path = try Self.repoPath(owner: owner, repo: repo) + "/pulls/\(number)/reviews"
        let (data, http) = try await request(path, method: "POST", body: payload)
        try Self.ensureOK(http, data: data, method: "POST", path: path)
    }

    /// GitHub answers the pull request itself as a diff when asked for the
    /// diff media type. A diff past its size limit is refused with a 406.
    public func pullDiff(owner: String, repo: String, number: Int) async throws -> String {
        let path = try Self.repoPath(owner: owner, repo: repo) + "/pulls/\(number)"
        let (data, http) = try await request(path, accept: "application/vnd.github.diff")
        try Self.ensureOK(http, data: data, path: path)
        return String(decoding: data, as: UTF8.self)
    }
}
