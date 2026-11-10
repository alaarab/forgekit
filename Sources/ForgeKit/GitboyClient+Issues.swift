import Foundation

// MARK: - Paths and links

/// gitboy issue links: the web page an older server leaves out of its answer.
enum GitboyIssueURLs {
    static func issue(host: ForgeHost, owner: String, name: String, number: Int) -> URL {
        URL(string: "https://\(host.domain)/\(segment(owner))/\(segment(name))/issues/\(number)") ?? host.webBase
    }

    private static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Issue rows

struct GitboyIssueLabelDTO: Decodable, Sendable {
    let name: String?
    let color: String?

    enum CodingKeys: String, CodingKey { case name, color }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenient(.name)
        color = c.lenient(.color)
    }

    /// gitboy stores colours as "#d73a4a"; the forge contract is bare hex.
    static func hex(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") { value.removeFirst() }
        return value.isEmpty ? nil : value
    }
}

struct GitboyAssigneeDTO: Decodable, Sendable {
    let username: String?

    enum CodingKeys: String, CodingKey { case username }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        username = c.lenient(.username)
    }
}

struct GitboyIssueCommentDTO: Decodable, Sendable {
    let id: String?
    let body: String?
    let authorUsername: String?
    let createdAt: String?
    let kind: String?

    enum CodingKeys: String, CodingKey {
        case id, body, kind
        case authorUsername = "author_username"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id)
        body = c.lenient(.body)
        authorUsername = c.lenient(.authorUsername)
        createdAt = c.lenient(.createdAt)
        kind = c.lenient(.kind)
    }

    /// gitboy writes open/close/edit trail entries as comments with a `kind`;
    /// only a null (or "comment") kind is something a person said.
    var isEvent: Bool {
        let value = (kind ?? "").lowercased()
        return !value.isEmpty && value != "comment"
    }

    /// nil for event rows and for rows with no id to key a list on.
    var forgeComment: ForgeComment? {
        guard !isEvent, let id, !id.isEmpty else { return nil }
        return ForgeComment(id: id,
                            author: authorUsername ?? "",
                            body: body ?? "",
                            createdAt: ISO8601Dates.parse(createdAt))
    }
}

/// One issue as gitboy describes it. The same shape serves the list, the
/// detail endpoint and the write answers; the detail simply carries more
/// non-null fields.
struct GitboyIssueDTO: Decodable, Sendable {
    let index: Int?
    let title: String?
    let body: String?
    let state: String?
    let authorUsername: String?
    let labels: [GitboyIssueLabelDTO]?
    let assignees: [GitboyAssigneeDTO]?
    let commentCount: Int?
    let updatedAt: String?
    let createdAt: String?
    let htmlURL: String?
    let comments: [GitboyIssueCommentDTO]?

    enum CodingKeys: String, CodingKey {
        case index, title, body, state, labels, assignees, comments
        case authorUsername = "author_username"
        case commentCount = "comment_count"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case htmlURL = "html_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = c.lenient(.index)
        title = c.lenient(.title)
        body = c.lenient(.body)
        state = c.lenient(.state)
        authorUsername = c.lenient(.authorUsername)
        labels = c.lenient(.labels)
        assignees = c.lenient(.assignees)
        commentCount = c.lenient(.commentCount)
        updatedAt = c.lenient(.updatedAt)
        createdAt = c.lenient(.createdAt)
        htmlURL = c.lenient(.htmlURL)
        comments = c.lenient(.comments)
    }
}

// MARK: - Mapping

extension GitboyIssueDTO {
    var issueState: ForgeIssueState {
        (state ?? "").lowercased() == "open" ? .open : .closed
    }

    /// nil only when the row carries no number at all: nothing can link to it.
    func forgeIssue(repo: ForgeRepo, fallbackComments: Int = 0) -> ForgeIssue? {
        guard let index else { return nil }
        let webURL = Self.webLink(htmlURL)
            ?? GitboyIssueURLs.issue(host: repo.host, owner: repo.owner, name: repo.name, number: index)
        return ForgeIssue(
            repo: repo,
            number: index,
            title: title ?? "",
            author: authorUsername ?? "",
            state: issueState,
            labels: (labels ?? []).compactMap { label -> ForgeLabel? in
                guard let name = label.name, !name.isEmpty else { return nil }
                return ForgeLabel(name: name, colorHex: GitboyIssueLabelDTO.hex(label.color))
            },
            assignees: (assignees ?? []).compactMap { assignee -> String? in
                guard let username = assignee.username, !username.isEmpty else { return nil }
                return username
            },
            comments: commentCount ?? fallbackComments,
            // A newer gitboy sends updated_at; an older one only created_at.
            updatedAt: ISO8601Dates.parse(updatedAt) ?? ISO8601Dates.parse(createdAt),
            webURL: webURL)
    }

    /// Only http(s) links are taken from the server; anything else would put an
    /// unchecked scheme behind a tap.
    private static func webLink(_ raw: String?) -> URL? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let lowered = value.lowercased()
        guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://"),
              let url = URL(string: value), url.host != nil else { return nil }
        return url
    }
}

// MARK: - Client

extension GitboyClient {
    public func issues(in repo: ForgeRepo, state: ForgeStateFilter,
                       query: String?, cursor: String?) async throws -> ForgePage<ForgeIssue> {
        var items = [
            // `paginated=true` asks for {items, next_cursor}; an older gitboy
            // ignores it and answers a bare array, which decodes the same.
            URLQueryItem(name: "paginated", value: "true"),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "limit", value: "50"),
        ]
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "q", value: query))
        }
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let bearer = try authorization()
        let (data, _) = try await transport.send(Self.repoPath(repo) + "/issues",
                                                 query: items, bearer: bearer)
        guard let page = try? JSONDecoder().decode(GitboyPage<GitboyIssueDTO>.self, from: data) else {
            throw ForgeError.invalidResponse
        }
        // An empty cursor is "no more pages", the same as null.
        let next = (page.nextCursor?.isEmpty == false) ? page.nextCursor : nil
        return ForgePage(items: page.items.compactMap { $0.forgeIssue(repo: repo) }, next: next)
    }

    public func issue(in repo: ForgeRepo, number: Int) async throws -> ForgeIssueDetail {
        let bearer = try authorization()
        let base = Self.repoPath(repo) + "/issues/\(number)"
        let (data, _) = try await transport.send(base, bearer: bearer)
        guard let dto = try? JSONDecoder().decode(GitboyIssueDTO.self, from: data) else {
            throw ForgeError.invalidResponse
        }
        let comments = await forgeComments(base: base, bearer: bearer)
        guard let issue = dto.forgeIssue(repo: repo, fallbackComments: comments.count) else {
            throw ForgeError.invalidResponse
        }
        return ForgeIssueDetail(issue: issue, body: dto.body ?? "", comments: comments)
    }

    public func createIssue(in repo: ForgeRepo, title: String,
                            body: String) async throws -> ForgeIssue {
        let bearer = try authorization()
        let payload = try JSONSerialization.data(withJSONObject: ["title": title, "body": body])
        let (data, _) = try await transport.send(Self.repoPath(repo) + "/issues",
                                                 method: "POST", body: payload, bearer: bearer)
        guard let dto = try? JSONDecoder().decode(GitboyIssueDTO.self, from: data),
              let issue = dto.forgeIssue(repo: repo) else {
            throw ForgeError.invalidResponse
        }
        return issue
    }

    public func comment(on issue: ForgeIssue, body: String) async throws -> ForgeComment {
        try await postComment(repo: issue.repo, number: issue.number, body: body)
    }

    /// gitboy keeps an issue's and a pull request's conversation behind the
    /// same route, keyed by the number they share.
    func postComment(repo: ForgeRepo, number: Int, body: String) async throws -> ForgeComment {
        let bearer = try authorization()
        let payload = try JSONSerialization.data(withJSONObject: ["body": body])
        let (data, _) = try await transport.send(
            "\(Self.repoPath(repo))/issues/\(number)/comments",
            method: "POST", body: payload, bearer: bearer)
        guard let dto = try? JSONDecoder().decode(GitboyIssueCommentDTO.self, from: data),
              let comment = dto.forgeComment else {
            throw ForgeError.invalidResponse
        }
        return comment
    }

    public func setState(of issue: ForgeIssue,
                         to state: ForgeIssueState) async throws -> ForgeIssue {
        let bearer = try authorization()
        let base = "\(Self.repoPath(issue.repo))/issues/\(issue.number)"
        let payload = try JSONSerialization.data(withJSONObject: ["state": state.rawValue])
        let (data, _) = try await transport.send(base, method: "PATCH", body: payload, bearer: bearer)
        if let dto = try? JSONDecoder().decode(GitboyIssueDTO.self, from: data),
           let updated = dto.forgeIssue(repo: issue.repo) {
            return updated
        }
        // An answer without the issue in it (an older server, or an empty
        // body) is re-read rather than guessed at.
        let (detail, _) = try await transport.send(base, bearer: bearer)
        guard let dto = try? JSONDecoder().decode(GitboyIssueDTO.self, from: detail),
              let updated = dto.forgeIssue(repo: issue.repo) else {
            throw ForgeError.invalidResponse
        }
        return updated
    }
}

// MARK: - Internals

extension GitboyClient {
    /// The oldest-first first page of comments. A server that refuses the
    /// comments endpoint must not hide the issue itself, so failure is "none".
    func forgeComments(base: String, bearer: String) async -> [ForgeComment] {
        guard let (data, _) = try? await transport.send(base + "/comments", bearer: bearer),
              let page = try? JSONDecoder().decode(GitboyPage<GitboyIssueCommentDTO>.self, from: data) else {
            return []
        }
        return page.items.compactMap { $0.forgeComment }
    }
}
