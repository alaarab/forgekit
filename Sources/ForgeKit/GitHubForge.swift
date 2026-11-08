import Foundation

/// GitHub through the same `Forge` protocol, reusing the existing client so
/// nothing about GitHub sign-in or memory-store sync changes.
public struct GitHubForge: Forge {
    public let host: ForgeHost
    public var capabilities: ForgeCapabilities { ForgeCapabilities.github }

    private static let pageSize = 100

    /// Internal so the extensions in other files can reach the client.
    let client: any GitHubTransport

    public init(client: any GitHubTransport) {
        self.client = client
        self.host = .github
    }

    public func currentUser() async throws -> ForgeUser {
        let user = try await client.currentUser()
        return ForgeUser(login: user.login, displayName: user.name,
                         avatarURL: user.avatarUrl.flatMap { URL(string: $0) })
    }

    /// The cursor is the page number as a string, so the same paginator works
    /// for both hosts. GitHub's link headers are not used: a full page of
    /// `perPage` items means there may be another, a short page is the end.
    public func repos(cursor: String?, query: String?) async throws -> ForgePage<ForgeRepo> {
        let page = max(1, Int(cursor ?? "") ?? 1)
        let batch = try await client.listRepos(page: page, perPage: Self.pageSize)
        var items = batch.map { repo in
            ForgeRepo(host: host,
                      owner: repo.owner.login,
                      name: repo.name,
                      description: nil,
                      isPrivate: repo.isPrivate,
                      defaultBranch: repo.defaultBranch,
                      isArchived: false,
                      updatedAt: ISO8601Dates.parse(repo.pushedAt),
                      webURL: URL(string: "https://github.com/\(repo.fullName)") ?? host.webBase)
        }
        let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            // GitHub has no name filter on this endpoint; client-side is fine
            // for the picker's search field.
            items = items.filter { $0.name.lowercased().contains(needle) }
        }
        return ForgePage(items: items, next: batch.count < Self.pageSize ? nil : String(page + 1))
    }
}
