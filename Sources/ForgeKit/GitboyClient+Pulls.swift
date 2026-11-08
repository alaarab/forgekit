import Foundation

// MARK: - Paths and links

/// gitboy links for pull requests: the web pages older servers leave out of
/// their answers, and the pipeline page a job belongs to.
enum GitboyPullURLs {
    static func pull(host: ForgeHost, owner: String, name: String, number: Int) -> URL {
        url(host: host, path: "\(segment(owner))/\(segment(name))/pulls/\(number)")
    }

    static func pipeline(host: ForgeHost, owner: String, name: String, iid: Int) -> URL {
        url(host: host, path: "\(segment(owner))/\(segment(name))/pipelines/\(iid)")
    }

    private static func url(host: ForgeHost, path: String) -> URL {
        URL(string: "https://\(host.domain)/\(path)") ?? host.webBase
    }

    private static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Decoding helpers

extension KeyedDecodingContainer {
    /// A value that is missing, null, or the wrong shape all read as nil.
    /// gitboy adds fields over time and an older server omits them; one odd
    /// field must never blank a whole page.
    func lenient<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// gitboy answers a list either as a bare array or as `{items, next_cursor}`
/// depending on the endpoint and its age. Both read the same here.
struct GitboyPage<Row: Decodable>: Decodable {
    let items: [Row]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           keyed.contains(.items) || keyed.contains(.nextCursor) {
            items = try keyed.decodeIfPresent([Row].self, forKey: .items) ?? []
            nextCursor = try keyed.decodeIfPresent(String.self, forKey: .nextCursor)
            return
        }
        items = try decoder.singleValueContainer().decode([Row].self)
        nextCursor = nil
    }
}

// MARK: - Pull request rows

struct GitboyReviewDTO: Decodable, Sendable {
    let reviewerUsername: String?
    let state: String?
    let body: String?
    let commitSHA: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case state, body
        case reviewerUsername = "reviewer_username"
        case commitSHA = "commit_sha"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviewerUsername = c.lenient(.reviewerUsername)
        state = c.lenient(.state)
        body = c.lenient(.body)
        commitSHA = c.lenient(.commitSHA)
        createdAt = c.lenient(.createdAt)
    }

    var date: Date? { ISO8601Dates.parse(createdAt) }

    var forgeState: ForgeReview.State {
        switch (state ?? "").lowercased() {
        case "approved": return .approved
        case "changes_requested": return .changesRequested
        case "dismissed": return .dismissed
        default: return .commented
        }
    }
}

struct GitboyCheckDTO: Decodable, Sendable {
    let context: String?
    let state: String?
    let targetURL: String?

    enum CodingKeys: String, CodingKey {
        case context, state
        case targetURL = "target_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        context = c.lenient(.context)
        state = c.lenient(.state)
        targetURL = c.lenient(.targetURL)
    }
}

struct GitboyJobDTO: Decodable, Sendable {
    let id: String?
    let name: String?
    let stage: String?
    let status: String?
    let attempt: Int?
    let allowFailure: Bool?
    let startedAt: String?
    let finishedAt: String?
    let failureReason: String?

    enum CodingKeys: String, CodingKey {
        case id, name, stage, status, attempt
        case allowFailure = "allow_failure"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case failureReason = "failure_reason"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id)
        name = c.lenient(.name)
        stage = c.lenient(.stage)
        status = c.lenient(.status)
        attempt = c.lenient(.attempt)
        allowFailure = c.lenient(.allowFailure)
        startedAt = c.lenient(.startedAt)
        finishedAt = c.lenient(.finishedAt)
        failureReason = c.lenient(.failureReason)
    }

    var seconds: Int? {
        guard let started = ISO8601Dates.parse(startedAt),
              let finished = ISO8601Dates.parse(finishedAt) else { return nil }
        return Int(max(0, finished.timeIntervalSince(started).rounded()))
    }
}

struct GitboyPipelineDTO: Decodable, Sendable {
    let iid: Int?
    let sha: String?
    let status: String?

    enum CodingKeys: String, CodingKey { case iid, sha, status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iid = c.lenient(.iid)
        sha = c.lenient(.sha)
        status = c.lenient(.status)
    }
}

struct GitboyPipelineDetailDTO: Decodable, Sendable {
    let status: String?
    let jobs: [GitboyJobDTO]?

    enum CodingKeys: String, CodingKey { case status, jobs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lenient(.status)
        jobs = c.lenient(.jobs)
    }
}

struct GitboyCommentDTO: Decodable, Sendable {
    let id: String?

    enum CodingKeys: String, CodingKey { case id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id)
    }
}

/// One pull request as gitboy describes it. The same shape serves the list and
/// the detail endpoint; the detail simply carries more non-null fields.
struct GitboyPullDTO: Decodable, Sendable {
    let index: Int?
    let number: Int?
    let title: String?
    let authorUsername: String?
    let state: String?
    let mergedAt: String?
    let draft: Bool?
    let headBranch: String?
    let baseBranch: String?
    let updatedAt: String?
    let htmlURL: String?
    let body: String?
    let headSHA: String?
    let reviews: [GitboyReviewDTO]?
    let reviewDecision: String?
    let status: String?
    let mergeBlockers: [String]?
    let checks: [GitboyCheckDTO]?
    let commentCount: Int?
    let comments: [GitboyCommentDTO]?
    let commitsAhead: Int?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?

    enum CodingKeys: String, CodingKey {
        case index, number, title, state, draft, body, reviews, status
        case authorUsername = "author_username"
        case mergedAt = "merged_at"
        case headBranch = "head_branch"
        case baseBranch = "base_branch"
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
        case headSHA = "head_sha"
        case reviewDecision = "review_decision"
        case mergeBlockers = "merge_blockers"
        case checks
        case commentCount = "comment_count"
        case comments
        case commitsAhead = "commits_ahead"
        case additions, deletions
        case changedFiles = "changed_files"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = c.lenient(.index)
        number = c.lenient(.number)
        title = c.lenient(.title)
        authorUsername = c.lenient(.authorUsername)
        state = c.lenient(.state)
        mergedAt = c.lenient(.mergedAt)
        draft = c.lenient(.draft)
        headBranch = c.lenient(.headBranch)
        baseBranch = c.lenient(.baseBranch)
        updatedAt = c.lenient(.updatedAt)
        htmlURL = c.lenient(.htmlURL)
        body = c.lenient(.body)
        headSHA = c.lenient(.headSHA)
        reviews = c.lenient(.reviews)
        reviewDecision = c.lenient(.reviewDecision)
        status = c.lenient(.status)
        mergeBlockers = c.lenient(.mergeBlockers)
        checks = c.lenient(.checks)
        commentCount = c.lenient(.commentCount)
        comments = c.lenient(.comments)
        commitsAhead = c.lenient(.commitsAhead)
        additions = c.lenient(.additions)
        deletions = c.lenient(.deletions)
        changedFiles = c.lenient(.changedFiles)
    }
}

// MARK: - Mapping

extension GitboyPullDTO {
    var pullState: ForgePullState {
        if let mergedAt, !mergedAt.isEmpty { return .merged }
        return (state ?? "").lowercased() == "open" ? .open : .closed
    }

    var pullNumber: Int? { index ?? number }

    /// nil only when the row carries no number at all: nothing can link to it.
    func forgePull(repo: ForgeRepo) -> ForgePullRequest? {
        guard let number = pullNumber else { return nil }
        let webURL = GitboyPullDTO.webLink(htmlURL)
            ?? GitboyPullURLs.pull(host: repo.host, owner: repo.owner, name: repo.name, number: number)
        return ForgePullRequest(repo: repo,
                                number: number,
                                title: title ?? "",
                                author: authorUsername ?? "",
                                state: pullState,
                                isDraft: draft == true,
                                headBranch: headBranch ?? "",
                                baseBranch: baseBranch ?? "",
                                updatedAt: ISO8601Dates.parse(updatedAt),
                                webURL: webURL)
    }

    /// `GitHub's reviewDecision from gitboy's reviews: each reviewer's latest verdict
    /// on the head commit, the author's own left out.` (git-host-gitboy.ts)
    ///
    /// A newer gitboy sends `review_decision` outright; that is taken at its word
    /// and only falls back to the derivation for a word this client doesn't know.
    var forgeReviewDecision: ForgeReviewDecision? {
        if let raw = reviewDecision?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            switch raw.uppercased() {
            case "APPROVED": return .approved
            case "CHANGES_REQUESTED": return .changesRequested
            case "REVIEW_REQUIRED": return .reviewRequired
            default: break
            }
        }
        let head = headSHA ?? ""
        var latest: [String: String] = [:]
        for review in (reviews ?? []).sorted(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
            guard let who = review.reviewerUsername, !who.isEmpty, who != authorUsername else { continue }
            switch (review.state ?? "").lowercased() {
            case "changes_requested":
                latest[who] = "changes_requested"
            case "approved" where head.isEmpty || review.commitSHA == head:
                latest[who] = "approved"
            default:
                break
            }
        }
        let verdicts = Set(latest.values)
        if verdicts.contains("changes_requested") { return .changesRequested }
        // A protected branch waiting on approvals: gitboy says so in its blockers.
        if (mergeBlockers ?? []).contains(where: { $0.range(of: "approval", options: .caseInsensitive) != nil }) {
            return .reviewRequired
        }
        return verdicts.contains("approved") ? .approved : nil
    }

    /// `gitboyMergeState` from git-host-gitboy.ts, in this layer's cases.
    var forgeMergeability: ForgeMergeability {
        guard pullState == .open else { return .notOpen }
        let blockers = (mergeBlockers ?? []).prefix(20).map { String($0.prefix(300)) }
        switch status ?? "" {
        case "conflict":
            return .conflicts
        case "checking", "":
            return .checking
        case "empty", "ancestor":
            return .unknown("No changes to merge")
        case "error":
            return .unknown("gitboy could not check mergeability")
        default:
            return blockers.isEmpty ? .clean : .blocked(blockers)
        }
    }

    var forgeReviews: [ForgeReview] {
        (reviews ?? [])
            .filter { ($0.reviewerUsername ?? "").isEmpty == false }
            .sorted(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
            .map { review in
                ForgeReview(reviewer: review.reviewerUsername ?? "",
                            state: review.forgeState,
                            body: (review.body?.isEmpty == false) ? review.body : nil,
                            submittedAt: review.date)
            }
    }

    /// Only http(s) links are taken from the server; anything else would put an
    /// unchecked scheme behind a tap.
    static func webLink(_ raw: String?) -> URL? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let lowered = value.lowercased()
        guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://"),
              let url = URL(string: value), url.host != nil else { return nil }
        return url
    }
}

// MARK: - Client

extension GitboyClient {
    public func pullRequests(in repo: ForgeRepo, state: ForgeStateFilter,
                             cursor: String?) async throws -> ForgePage<ForgePullRequest> {
        var query = [
            // `paginated=true` asks for {items, next_cursor}; an older gitboy
            // ignores it and answers a bare array, which decodes the same.
            URLQueryItem(name: "paginated", value: "true"),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "limit", value: "50"),
        ]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let bearer = try authorization()
        let (data, _) = try await transport.send(Self.repoPath(repo) + "/pulls",
                                                 query: query, bearer: bearer)
        guard let page = try? JSONDecoder().decode(GitboyPage<GitboyPullDTO>.self, from: data) else {
            throw ForgeError.invalidResponse
        }
        // An empty cursor is "no more pages", the same as null.
        let next = (page.nextCursor?.isEmpty == false) ? page.nextCursor : nil
        return ForgePage(items: page.items.compactMap { $0.forgePull(repo: repo) }, next: next)
    }

    public func pullRequest(in repo: ForgeRepo, number: Int) async throws -> ForgePullRequestDetail {
        let bearer = try authorization()
        let base = Self.repoPath(repo)
        let (data, _) = try await transport.send("\(base)/pulls/\(number)", bearer: bearer)
        guard let dto = try? JSONDecoder().decode(GitboyPullDTO.self, from: data),
              let pull = dto.forgePull(repo: repo) else {
            throw ForgeError.invalidResponse
        }
        let checks = await forgeChecks(dto, repo: repo, bearer: bearer)
        return ForgePullRequestDetail(
            pull: pull,
            body: dto.body ?? "",
            headSHA: dto.headSHA ?? "",
            reviews: dto.forgeReviews,
            reviewDecision: dto.forgeReviewDecision,
            mergeability: dto.forgeMergeability,
            checks: checks,
            commits: dto.commitsAhead,
            additions: dto.additions,
            deletions: dto.deletions,
            changedFiles: dto.changedFiles,
            comments: dto.commentCount ?? dto.comments?.count)
    }

    public func merge(_ pull: ForgePullRequest, method: ForgeMergeMethod,
                      expectedHeadSHA: String) async throws -> ForgeMergeOutcome {
        let bearer = try authorization()
        let base = Self.repoPath(pull.repo)
        var payload: [String: Any] = [
            "method": method.rawValue,
            "expected_head_sha": expectedHeadSHA,
        ]
        if method == .rebase {
            // gitboy refuses a rebase that doesn't pin the target commit too.
            if let baseSHA = try? await targetSHA(pull, repoPath: base, bearer: bearer) {
                payload["expected_base_sha"] = baseSHA
            }
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = try await transport.send(
            "\(base)/pulls/\(pull.number)/merge",
            method: "POST", body: body, bearer: bearer, validate: false)

        if (200..<300).contains(http.statusCode) {
            let response = try? JSONDecoder().decode(GitboyMergeResponse.self, from: data)
            return .merged(sha: response?.mergeCommitSHA)
        }
        let error = GitboyTransport.error(status: http.statusCode, headers: http, data: data)
        guard case .conflict(let message) = error else { throw error }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let details = ((json?["details"] as? [Any]) ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // A branch that moved is named in gitboy's top-level message alone; a
        // blocked merge is a message plus `details`. The words inside a blocker
        // ("The head branch is behind main") say nothing about a moved branch.
        let movedPrefixes = ["pull request head changed", "pull request target changed"]
        let lowered = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if movedPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return .headMoved
        }
        if !details.isEmpty {
            return .refused(Array(details.prefix(10)))
        }
        return .refused([message.isEmpty ? "gitboy says it can't be merged yet." : message])
    }

    /// The pull request's target commit, read for a rebase merge that must pin
    /// it. nil when the detail can't be read or carries no `base_sha`.
    private func targetSHA(_ pull: ForgePullRequest, repoPath: String,
                           bearer: String) async throws -> String? {
        let (detail, _) = try await transport.send("\(repoPath)/pulls/\(pull.number)", bearer: bearer)
        let baseSHA = ((try? JSONSerialization.jsonObject(with: detail)) as? [String: Any])?["base_sha"] as? String
        guard let baseSHA, !baseSHA.isEmpty else { return nil }
        return baseSHA
    }

    public func review(_ pull: ForgePullRequest, verdict: ForgeReviewVerdict,
                       body: String, expectedHeadSHA: String) async throws {
        let bearer = try authorization()
        let base = Self.repoPath(pull.repo)
        // The head the review was written against, straight into the endpoint's
        // head pin: gitboy re-reads its own head and refuses the review with a
        // 409 when it has moved, so the review never lands on another commit.
        let payload: [String: Any] = [
            "state": Self.reviewState(verdict),
            "body": body,
            "expected_head_sha": expectedHeadSHA,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let (responseData, http) = try await transport.send("\(base)/pulls/\(pull.number)/reviews",
                                                           method: "POST", body: data, bearer: bearer,
                                                           validate: false)
        if (200..<300).contains(http.statusCode) { return }
        let error = GitboyTransport.error(status: http.statusCode, headers: http, data: responseData)
        guard case .conflict(let message) = error else { throw error }
        // The same 409 also covers a closed pull request; only a head that moved
        // is the "reload and review again" case, worded for the screen.
        let lowered = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.hasPrefix("pull request head changed") {
            throw ForgeError.conflict("The branch moved. Reload before reviewing.")
        }
        throw error
    }
}

// MARK: - Wire words and internals

extension GitboyClient {
    struct GitboyMergeResponse: Decodable {
        let mergeCommitSHA: String?
        let merged: Bool?

        enum CodingKeys: String, CodingKey {
            case merged
            case mergeCommitSHA = "merge_commit_sha"
        }
    }

    static func reviewState(_ verdict: ForgeReviewVerdict) -> String {
        switch verdict {
        case .approve: return "approved"
        case .requestChanges: return "changes_requested"
        case .comment: return "commented"
        }
    }

    /// A gitboy job or commit status as one state word (git-host-gitboy.ts
    /// `gitboyState`): an allowed failure is neutral, everything unfinished is
    /// pending.
    static func checkState(_ status: String?, allowFailure: Bool = false) -> ForgeCheckState {
        switch (status ?? "").lowercased() {
        case "success":
            return .passing
        case "failed", "failure", "error":
            return allowFailure ? .neutral : .failing
        case "canceled", "cancelled":
            return allowFailure ? .neutral : .failing
        case "skipped":
            return .skipped
        default:
            return .pending
        }
    }

    static func repoPath(_ repo: ForgeRepo) -> String {
        "repos/\(segment(repo.owner))/\(segment(repo.name))"
    }

    private static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

extension GitboyClient {
    /// The head commit's pipeline jobs, newest attempt of each, failing first;
    /// commit statuses when there is no pipeline to read jobs from.
    func forgeChecks(_ dto: GitboyPullDTO, repo: ForgeRepo, bearer: String) async -> [ForgeCheck] {
        let jobs = await pipelineChecks(dto, repo: repo, bearer: bearer)
        let checks: [ForgeCheck] = jobs.isEmpty ? statusChecks(dto) : jobs
        let sorted = checks.sorted(by: { lhs, rhs in
            if lhs.state == rhs.state { return lhs.name < rhs.name }
            return lhs.state < rhs.state
        })
        return Array(sorted.prefix(100))
    }

    private func pipelineChecks(_ dto: GitboyPullDTO, repo: ForgeRepo,
                                bearer: String) async -> [ForgeCheck] {
        let sha = dto.headSHA ?? ""
        let branch = dto.headBranch ?? ""
        guard !sha.isEmpty, !branch.isEmpty else { return [] }
        let base = Self.repoPath(repo)
        let query = [
            URLQueryItem(name: "branch", value: branch),
            URLQueryItem(name: "sha", value: sha),
            URLQueryItem(name: "limit", value: "20"),
        ]
        let pipelinePath = base + "/pipelines"
        // A repo without CI, or without read:ci, simply has no jobs to show:
        // that must not fail the pull request itself.
        guard let (listData, _) = try? await transport.send(pipelinePath, query: query, bearer: bearer),
              let page = try? JSONDecoder().decode(GitboyPage<GitboyPipelineDTO>.self, from: listData),
              // An older gitboy ignores the sha filter; pick this commit's newest run.
              let pipeline = page.items
                .filter({ $0.sha == sha })
                .sorted(by: { ($0.iid ?? 0) > ($1.iid ?? 0) })
                .first,
              let iid = pipeline.iid else { return [] }
        guard let (detailData, _) = try? await transport.send("\(pipelinePath)/\(iid)", bearer: bearer),
              let pipelineDetail = try? JSONDecoder().decode(GitboyPipelineDetailDTO.self, from: detailData) else {
            return []
        }
        let pipelineURL = GitboyPullURLs.pipeline(host: host, owner: repo.owner, name: repo.name, iid: iid)
        var newest: [String: GitboyJobDTO] = [:]
        for job in pipelineDetail.jobs ?? [] {
            let name = job.name ?? "Job"
            if let seen = newest[name], (job.attempt ?? 0) < (seen.attempt ?? 0) { continue }
            newest[name] = job
        }
        return newest.values.map { job -> ForgeCheck in
            let id = job.id.flatMap { $0.isEmpty ? nil : $0 }
            let url = id.flatMap { value -> URL? in
                guard var components = URLComponents(url: pipelineURL, resolvingAgainstBaseURL: false) else {
                    return pipelineURL
                }
                components.queryItems = [URLQueryItem(name: "job", value: value)]
                return components.url ?? pipelineURL
            }
            let stage = job.stage.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
            let failure = job.failureReason.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
            return ForgeCheck(name: String((job.name ?? "Job").prefix(200)),
                              group: stage,
                              state: Self.checkState(job.status, allowFailure: job.allowFailure == true),
                              webURL: url,
                              seconds: job.seconds,
                              detail: failure)
        }
    }

    private func statusChecks(_ dto: GitboyPullDTO) -> [ForgeCheck] {
        (dto.checks ?? []).filter { ($0.context ?? "") != "gitboy/pipeline" }.map { check in
            let context = check.context ?? "Check"
            let name = context.hasPrefix("gitboy/") ? String(context.dropFirst("gitboy/".count)) : context
            return ForgeCheck(name: String(name.prefix(200)),
                              group: nil,
                              state: Self.checkState(check.state),
                              webURL: GitboyPullDTO.webLink(check.targetURL),
                              seconds: nil,
                              detail: nil)
        }
    }
}
