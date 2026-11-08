import Foundation

// MARK: - Mapping

extension GitHubPullDTO {
    var pullState: ForgePullState {
        if let mergedAt, !mergedAt.isEmpty { return .merged }
        return (state ?? "").lowercased() == "open" ? .open : .closed
    }

    func forgePull(repo: ForgeRepo) -> ForgePullRequest {
        let webURL = htmlURL.flatMap(Self.webLink)
            ?? URL(string: "https://github.com/\(repo.owner)/\(repo.name)/pull/\(number)")
            ?? repo.webURL
        return ForgePullRequest(repo: repo,
                                number: number,
                                title: title,
                                author: user?.login ?? "",
                                state: pullState,
                                isDraft: draft == true,
                                headBranch: head?.ref ?? "",
                                baseBranch: base?.ref ?? "",
                                updatedAt: ISO8601Dates.parse(updatedAt),
                                webURL: webURL)
    }

    static func webLink(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value), url.host != nil else { return nil }
        return url
    }
}

extension GitHubPullReviewDTO {
    var forgeState: ForgeReview.State {
        switch (state ?? "").uppercased() {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "DISMISSED": return .dismissed
        default: return .commented
        }
    }
}

extension GitHubCheckRunDTO {
    /// `status != completed` is pending whatever the conclusion says; only a
    /// finished run's conclusion is read.
    var forgeState: ForgeCheckState {
        guard (status ?? "").lowercased() == "completed" else { return .pending }
        switch (conclusion ?? "").lowercased() {
        case "success":
            return .passing
        case "failure", "timed_out", "cancelled", "action_required", "startup_failure":
            return .failing
        case "skipped":
            return .skipped
        case "neutral", "stale":
            return .neutral
        default:
            return .neutral
        }
    }

    var seconds: Int? {
        guard let started = ISO8601Dates.parse(startedAt),
              let finished = ISO8601Dates.parse(completedAt) else { return nil }
        return Int(max(0, finished.timeIntervalSince(started).rounded()))
    }

    var forgeCheck: ForgeCheck {
        ForgeCheck(name: name ?? "Check",
                   group: nil,
                   state: forgeState,
                   webURL: htmlURL.flatMap(GitHubPullDTO.webLink),
                   seconds: seconds,
                   detail: nil)
    }
}

// MARK: - Forge conformance

extension GitHubForge {
    private static let pullsPerPage = 50

    public func pullRequests(in repo: ForgeRepo, state: ForgeStateFilter,
                             cursor: String?) async throws -> ForgePage<ForgePullRequest> {
        let page = max(1, Int(cursor ?? "") ?? 1)
        let rows = try await client.listPulls(owner: repo.owner, repo: repo.name,
                                              state: state, page: page,
                                              perPage: Self.pullsPerPage)
        // A full page may have another behind it; a short page is the end.
        let next = rows.count < Self.pullsPerPage ? nil : String(page + 1)
        return ForgePage(items: rows.map { $0.forgePull(repo: repo) }, next: next)
    }

    public func pullRequest(in repo: ForgeRepo, number: Int) async throws -> ForgePullRequestDetail {
        let dto = try await client.pull(owner: repo.owner, repo: repo.name, number: number)
        let reviews = try await client.pullReviews(owner: repo.owner, repo: repo.name, number: number)
        let headSHA = dto.head?.sha ?? ""
        var runs: [GitHubCheckRunDTO] = []
        if !headSHA.isEmpty {
            // Checks are decoration on a detail screen; a token without Checks
            // access must not hide the pull request itself.
            runs = (try? await client.checkRuns(owner: repo.owner, repo: repo.name, sha: headSHA)) ?? []
        }
        let checks: [ForgeCheck] = runs.map({ $0.forgeCheck }).sorted(by: { lhs, rhs in
            if lhs.state == rhs.state { return lhs.name < rhs.name }
            return lhs.state < rhs.state
        })
        let commentCount: Int?
        if dto.comments == nil && dto.reviewComments == nil {
            commentCount = nil
        } else {
            commentCount = (dto.comments ?? 0) + (dto.reviewComments ?? 0)
        }
        return ForgePullRequestDetail(
            pull: dto.forgePull(repo: repo),
            body: dto.body ?? "",
            headSHA: headSHA,
            reviews: Self.forgeReviews(reviews),
            reviewDecision: Self.reviewDecision(reviews),
            mergeability: Self.mergeability(dto),
            checks: Array(checks.prefix(100)),
            commits: dto.commits,
            additions: dto.additions,
            deletions: dto.deletions,
            changedFiles: dto.changedFiles,
            comments: commentCount)
    }

    public func merge(_ pull: ForgePullRequest, method: ForgeMergeMethod,
                      expectedHeadSHA: String) async throws -> ForgeMergeOutcome {
        let owner = pull.repo.owner
        let name = pull.repo.name
        let (data, http) = try await client.mergePull(owner: owner, repo: name,
                                                      number: pull.number, method: method,
                                                      expectedHeadSHA: expectedHeadSHA)
        let message = Self.message(from: data)
        switch http.statusCode {
        case 200..<300:
            let result = try? JSONDecoder().decode(GitHubMergeResultDTO.self, from: data)
            return .merged(sha: result?.sha)
        case 409:
            // The expected head SHA no longer matches: reload and retry.
            return .headMoved
        case 405, 422:
            return .refused([message ?? Self.mergeFallback])
        default:
            throw GitHubError.http(status: http.statusCode,
                                   message: message ?? "request failed",
                                   method: "PUT",
                                   path: "repos/\(owner)/\(name)/pulls/\(pull.number)/merge")
        }
    }

    public func review(_ pull: ForgePullRequest, verdict: ForgeReviewVerdict,
                       body: String, expectedHeadSHA: String) async throws {
        try await client.submitPullReview(owner: pull.repo.owner,
                                          repo: pull.repo.name,
                                          number: pull.number,
                                          event: Self.event(verdict),
                                          body: body,
                                          expectedHeadSHA: expectedHeadSHA)
    }
}

// MARK: - Review words and decisions

extension GitHubForge {
    static let mergeFallback = "GitHub says this pull request can't be merged yet."

    static func event(_ verdict: ForgeReviewVerdict) -> String {
        switch verdict {
        case .approve: return "APPROVE"
        case .requestChanges: return "REQUEST_CHANGES"
        case .comment: return "COMMENT"
        }
    }

    static func forgeReviews(_ reviews: [GitHubPullReviewDTO]) -> [ForgeReview] {
        reviews
            .filter { ($0.user?.login ?? "").isEmpty == false }
            .sorted(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
            .map { review in
                ForgeReview(reviewer: review.user?.login ?? "",
                            state: review.forgeState,
                            body: (review.body?.isEmpty == false) ? review.body : nil,
                            submittedAt: review.date)
            }
    }

    /// Each reviewer's latest standing verdict, comments and dismissals kept
    /// out of the count: any request for changes wins, else any approval.
    static func reviewDecision(_ reviews: [GitHubPullReviewDTO]) -> ForgeReviewDecision? {
        var latest: [String: String] = [:]
        for review in reviews {
            guard let who = review.user?.login, !who.isEmpty else { continue }
            let state = (review.state ?? "").uppercased()
            switch state {
            case "APPROVED", "CHANGES_REQUESTED":
                latest[who] = state
            case "DISMISSED":
                // A dismissal clears that reviewer's earlier verdict.
                latest[who] = state
            default:
                // COMMENTED and PENDING say nothing about the change itself.
                break
            }
        }
        let verdicts = Set(latest.values)
        if verdicts.contains("CHANGES_REQUESTED") { return .changesRequested }
        if verdicts.contains("APPROVED") { return .approved }
        return nil
    }

    /// `mergeable_state` in this layer's cases. GitHub's word is the whole
    /// answer; the sentences are for the screen, not a parse.
    static func mergeability(_ dto: GitHubPullDTO) -> ForgeMergeability {
        guard dto.pullState == .open else { return .notOpen }
        switch (dto.mergeableState ?? "").lowercased() {
        case "clean":
            return .clean
        case "dirty":
            return .conflicts
        case "blocked":
            return .blocked(["Merge is blocked by branch protection or required checks."])
        case "behind":
            return .blocked(["The branch is behind the base branch."])
        case "unstable", "has_hooks":
            // GitHub can still merge these: only checks that aren't required are
            // failing (or a hook ran), and those failures are already in `checks`.
            return .clean
        case "draft":
            return .blocked(["This pull request is a draft."])
        case "unknown", "":
            return .checking
        default:
            return .checking
        }
    }

    static func message(from data: Data) -> String? {
        let raw = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
