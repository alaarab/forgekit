import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Requests

/// The runner half of ForgeKit's built-in GitHub transport. A runner endpoint
/// is admin-only, and GitHub answers "you may not" with 403 or with its
/// ambiguous 404; the forge layer words that once instead of leaving GitHub's
/// terse message on screen.
extension GitHubHTTPTransport {
    static let runnersAdminMessage = "You need admin access to see this repository's runners."

    public func runners(scope: ForgeRunnerScope) async throws -> [GitHubRunnerDTO] {
        let base = try Self.runnersBase(scope)
        var runners: [GitHubRunnerDTO] = []
        var total = Int.max
        var page = 1
        while true {
            try Task.checkCancellation()
            let path = page == 1 ? base + "?per_page=100" : base + "?per_page=100&page=\(page)"
            let (data, http) = try await request(path)
            if http.statusCode == 403 || http.statusCode == 404 {
                throw ForgeError.unauthorized(Self.runnersAdminMessage)
            }
            try Self.ensureOK(http, data: data, path: path)
            let batch = try JSONDecoder().decode(GitHubRunnersPage.self, from: data)
            runners += batch.runners
            // `total_count` is the whole fleet; a short page is the end even
            // when the server leaves the count out.
            total = batch.totalCount ?? total
            if runners.count >= total || batch.runners.count < 100 { return runners }
            page += 1
        }
    }

    public func removeRunner(scope: ForgeRunnerScope, runnerID: String) async throws {
        let base = try Self.runnersBase(scope)
        let path = base + "/" + (try Self.encodePath(runnerID))
        let (data, http) = try await request(path, method: "DELETE")
        try Self.ensureOK(http, data: data, method: "DELETE", path: path)
    }

    /// `repos/<owner>/<name>/actions/runners` or `orgs/<org>/actions/runners`.
    /// `.mine` has no GitHub answer: the API only lists per repo or org.
    static func runnersBase(_ scope: ForgeRunnerScope) throws -> String {
        switch scope {
        case .repo(let owner, let name):
            return try repoPath(owner: owner, repo: name) + "/actions/runners"
        case .org(let org):
            let encoded = try encodePath(org)
            return "orgs/" + encoded + "/actions/runners"
        case .mine:
            throw ForgeError.server(status: 0,
                                    message: "GitHub lists runners per repository or organization.")
        }
    }
}
