import Foundation

/// GitHub through the same `Forge` protocol, reusing the existing client so
/// nothing about GitHub sign-in or memory-store sync changes.
public struct GitHubForge: Forge {
    public let host: ForgeHost
    /// `.github`, less what the transport this forge was given cannot do.
    public let capabilities: ForgeCapabilities

    private static let pageSize = 100
    /// How many pages one search call reads before it answers with what it has.
    private static let searchPageLimit = 5

    /// Internal so the extensions in other files can reach the client. Every
    /// call goes through `GitHubMappedTransport`, so what a screen catches is
    /// a `ForgeError` on either host.
    let client: any GitHubTransport
    /// The transport as it was given, to ask what else it can do.
    let base: any GitHubTransport

    public init(client: any GitHubTransport) {
        self.client = GitHubMappedTransport(base: client)
        self.base = client
        self.host = .github
        var capabilities = ForgeCapabilities.github
        if !(client is any GitHubWorkflowTransport) {
            capabilities.remove(.startRuns)
        }
        if !(client is any GitHubPullAutomationTransport) {
            capabilities.subtract([.autoMerge, .updateBranch, .markReady])
        }
        self.capabilities = capabilities
    }

    /// Runs requests made on `base` directly and rethrows what they fail with
    /// as `ForgeError`, as `client` does for the rest.
    func github<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            throw GitHubMappedTransport.forgeError(error)
        }
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
        var page = max(1, Int(cursor ?? "") ?? 1)
        let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var read = 0
        while true {
            let batch = try await client.listRepos(page: page, perPage: Self.pageSize)
            read += 1
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
            let next = batch.count < Self.pageSize ? nil : String(page + 1)
            guard !needle.isEmpty else { return ForgePage(items: items, next: next) }
            // GitHub has no name filter on this endpoint, so the filter is
            // applied here. A page with no match is read past, a few pages at
            // most: an empty answer that still offers more reads as the end
            // of the list to the person searching.
            items = items.filter { $0.name.lowercased().contains(needle) }
            if !items.isEmpty || next == nil || read >= Self.searchPageLimit {
                return ForgePage(items: items, next: next)
            }
            page += 1
        }
    }
}
