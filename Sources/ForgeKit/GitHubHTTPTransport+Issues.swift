import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Requests

/// The issue half of ForgeKit's built-in GitHub transport.
extension GitHubHTTPTransport {
    public func listIssues(owner: String, repo: String, state: ForgeStateFilter,
                    page: Int, perPage: Int) async throws -> [GitHubIssueDTO] {
        let path = try Self.repoPath(owner: owner, repo: repo)
            + "/issues?state=\(state.rawValue)&per_page=\(perPage)&page=\(max(1, page))"
        return try await get(path, as: [GitHubIssueDTO].self)
    }

    /// GitHub has no text filter on a repo's issue list, so a search query goes
    /// to `search/issues` scoped to this repo and to issues only.
    public func searchIssues(owner: String, repo: String, state: ForgeStateFilter,
                      query: String, page: Int, perPage: Int) async throws -> [GitHubIssueDTO] {
        let text = Self.issueSearchText(owner: owner, repo: repo, state: state, query: query)
        let path = "search/issues?q=\(Self.queryValue(text))"
            + "&per_page=\(perPage)&page=\(max(1, page))"
        return try await get(path, as: GitHubIssueSearchPage.self).items
    }

    public func issue(owner: String, repo: String, number: Int) async throws -> GitHubIssueDTO {
        let path = try Self.repoPath(owner: owner, repo: repo) + "/issues/\(number)"
        return try await get(path, as: GitHubIssueDTO.self)
    }

    /// Oldest first, as GitHub returns them: the order a thread is read in.
    public func issueComments(owner: String, repo: String, number: Int) async throws -> [GitHubIssueCommentDTO] {
        let path = try Self.repoPath(owner: owner, repo: repo) + "/issues/\(number)/comments?per_page=100"
        return try await get(path, as: [GitHubIssueCommentDTO].self)
    }

    public func createIssue(owner: String, repo: String, title: String,
                     body: String) async throws -> GitHubIssueDTO {
        let payload = try JSONSerialization.data(withJSONObject: ["title": title, "body": body])
        let path = try Self.repoPath(owner: owner, repo: repo) + "/issues"
        let (data, http) = try await request(path, method: "POST", body: payload)
        try Self.ensureOK(http, data: data, method: "POST", path: path)
        return try JSONDecoder().decode(GitHubIssueDTO.self, from: data)
    }

    public func createIssueComment(owner: String, repo: String, number: Int,
                            body: String) async throws -> GitHubIssueCommentDTO {
        let payload = try JSONSerialization.data(withJSONObject: ["body": body])
        let path = try Self.repoPath(owner: owner, repo: repo) + "/issues/\(number)/comments"
        let (data, http) = try await request(path, method: "POST", body: payload)
        try Self.ensureOK(http, data: data, method: "POST", path: path)
        return try JSONDecoder().decode(GitHubIssueCommentDTO.self, from: data)
    }

    public func setIssueState(owner: String, repo: String, number: Int,
                       state: ForgeIssueState) async throws -> GitHubIssueDTO {
        let payload = try JSONSerialization.data(withJSONObject: ["state": state.rawValue])
        let path = try Self.repoPath(owner: owner, repo: repo) + "/issues/\(number)"
        let (data, http) = try await request(path, method: "PATCH", body: payload)
        try Self.ensureOK(http, data: data, method: "PATCH", path: path)
        return try JSONDecoder().decode(GitHubIssueDTO.self, from: data)
    }

    /// `repo:<owner>/<name> is:issue [is:<state>] <query>` — GitHub's own
    /// qualifier words, so the search reads like the UI that documents it.
    static func issueSearchText(owner: String, repo: String, state: ForgeStateFilter,
                                query: String) -> String {
        var parts = ["repo:\(owner)/\(repo)", "is:issue"]
        if state != .all { parts.append("is:\(state.rawValue)") }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty { parts.append(needle) }
        return parts.joined(separator: " ")
    }

    static func queryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
