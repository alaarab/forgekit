import Foundation

// MARK: - Mapping

extension GitHubIssueLabelDTO {
    var forgeLabel: ForgeLabel? {
        guard let name, !name.isEmpty else { return nil }
        var color = (color ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if color.hasPrefix("#") { color.removeFirst() }
        return ForgeLabel(name: name, colorHex: color.isEmpty ? nil : color)
    }
}

extension GitHubIssueCommentDTO {
    var forgeComment: ForgeComment {
        ForgeComment(id: String(id),
                     author: user?.login ?? "",
                     body: body ?? "",
                     createdAt: date)
    }
}

extension GitHubIssueDTO {
    var issueState: ForgeIssueState {
        (state ?? "").lowercased() == "open" ? .open : .closed
    }

    func forgeIssue(repo: ForgeRepo) -> ForgeIssue {
        let webURL = htmlURL.flatMap(Self.webLink)
            ?? URL(string: "https://github.com/\(repo.owner)/\(repo.name)/issues/\(number)")
            ?? repo.webURL
        return ForgeIssue(repo: repo,
                          number: number,
                          title: title ?? "",
                          author: user?.login ?? "",
                          state: issueState,
                          labels: (labels ?? []).compactMap { $0.forgeLabel },
                          assignees: (assignees ?? []).compactMap { actor -> String? in
                              let login = actor.login
                              return login.isEmpty ? nil : login
                          },
                          comments: comments ?? 0,
                          updatedAt: ISO8601Dates.parse(updatedAt),
                          webURL: webURL)
    }

    /// Only http(s) links are taken from the server; anything else would put an
    /// unchecked scheme behind a tap.
    static func webLink(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value), url.host != nil else { return nil }
        return url
    }
}

// MARK: - Forge conformance

extension GitHubForge {
    private static let issuesPerPage = 50

    public func issues(in repo: ForgeRepo, state: ForgeStateFilter,
                       query: String?, cursor: String?) async throws -> ForgePage<ForgeIssue> {
        let page = max(1, Int(cursor ?? "") ?? 1)
        let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rows: [GitHubIssueDTO]
        if needle.isEmpty {
            rows = try await client.listIssues(owner: repo.owner, repo: repo.name,
                                               state: state, page: page,
                                               perPage: Self.issuesPerPage)
        } else {
            rows = try await client.searchIssues(owner: repo.owner, repo: repo.name,
                                                 state: state, query: needle, page: page,
                                                 perPage: Self.issuesPerPage)
        }
        // GitHub keeps issues and pull requests in one list; only issues here.
        let items = rows.filter { !$0.isPull }.map { $0.forgeIssue(repo: repo) }
        // A full page may have another behind it; a short page is the end. The
        // raw row count decides, since pull requests occupy slots of their own.
        let next = rows.count < Self.issuesPerPage ? nil : String(page + 1)
        return ForgePage(items: items, next: next)
    }

    public func issue(in repo: ForgeRepo, number: Int) async throws -> ForgeIssueDetail {
        let dto = try await client.issue(owner: repo.owner, repo: repo.name, number: number)
        let comments = try await client.issueComments(owner: repo.owner, repo: repo.name, number: number)
        return ForgeIssueDetail(issue: dto.forgeIssue(repo: repo),
                                body: dto.body ?? "",
                                comments: comments.map { $0.forgeComment })
    }

    public func createIssue(in repo: ForgeRepo, title: String,
                            body: String) async throws -> ForgeIssue {
        let dto = try await client.createIssue(owner: repo.owner, repo: repo.name,
                                               title: title, body: body)
        return dto.forgeIssue(repo: repo)
    }

    public func comment(on issue: ForgeIssue, body: String) async throws -> ForgeComment {
        let dto = try await client.createIssueComment(owner: issue.repo.owner,
                                                      repo: issue.repo.name,
                                                      number: issue.number,
                                                      body: body)
        return dto.forgeComment
    }

    public func setState(of issue: ForgeIssue,
                         to state: ForgeIssueState) async throws -> ForgeIssue {
        let dto = try await client.setIssueState(owner: issue.repo.owner,
                                                 repo: issue.repo.name,
                                                 number: issue.number,
                                                 state: state)
        return dto.forgeIssue(repo: issue.repo)
    }
}
