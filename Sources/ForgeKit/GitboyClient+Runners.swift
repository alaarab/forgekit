import Foundation

// MARK: - Runner rows

struct GitboyRunnerJobDTO: Decodable, Sendable {
    let id: String?
    let name: String?
    let status: String?
    let startedAt: String?
    let pipelineIID: Int?
    let repository: String?
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, repository
        case startedAt = "started_at"
        case pipelineIID = "pipeline_iid"
        case htmlURL = "html_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id)
        name = c.lenient(.name)
        status = c.lenient(.status)
        startedAt = c.lenient(.startedAt)
        pipelineIID = c.lenient(.pipelineIID)
        repository = c.lenient(.repository)
        htmlURL = c.lenient(.htmlURL)
    }
}

/// One fleet row (listRunnerFleet). The PATCH answer is the same shape minus
/// `busy`/`current_jobs`, so every field has to be optional.
struct GitboyRunnerDTO: Decodable, Sendable {
    let id: String?
    let name: String?
    let labels: [String]?
    let status: String?
    let lastSeenAt: String?
    let version: String?
    let capacity: Int?
    let host: String?
    let ephemeral: Bool?
    let busy: Bool?
    let currentJobs: [GitboyRunnerJobDTO]?
    let agentHarnesses: [String]?
    let capabilities: GitboyRunnerCapabilitiesDTO?

    enum CodingKeys: String, CodingKey {
        case id, name, labels, status, version, capacity, host, ephemeral, busy, capabilities
        case lastSeenAt = "last_seen_at"
        case currentJobs = "current_jobs"
        case agentHarnesses = "agent_harnesses"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id)
        name = c.lenient(.name)
        labels = c.lenient(.labels)
        status = c.lenient(.status)
        lastSeenAt = c.lenient(.lastSeenAt)
        version = c.lenient(.version)
        capacity = c.lenient(.capacity)
        host = c.lenient(.host)
        ephemeral = c.lenient(.ephemeral)
        busy = c.lenient(.busy)
        currentJobs = c.lenient(.currentJobs)
        agentHarnesses = c.lenient(.agentHarnesses)
        capabilities = c.lenient(.capabilities)
    }

    /// The harnesses the runner offers, trimmed, without blanks or repeats,
    /// in the order it lists them.
    var harnesses: [String] {
        var seen = Set<String>()
        return (agentHarnesses ?? []).compactMap { raw -> String? in
            guard let value = GitboyRunnerMapping.nonEmpty(raw), seen.insert(value).inserted else {
                return nil
            }
            return value
        }
    }
}

/// What a runner says it can do. Only the agent flag is read; an older server
/// sends no flags at all, and then the harness list alone decides.
struct GitboyRunnerCapabilitiesDTO: Decodable, Sendable {
    let agentV1: Bool?

    enum CodingKeys: String, CodingKey { case agentV1 = "agent_v1" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentV1 = c.lenient(.agentV1)
    }
}

// MARK: - Mapping

/// gitboy's fleet row in the contract's shape. `now` is injected so the
/// 120 s freshness window can be checked without waiting on the clock.
struct GitboyRunnerMapping {
    let host: ForgeHost
    let scope: ForgeRunnerScope
    var now: () -> Date = Date.init

    /// A runner that stopped heartbeating is stale even if its last status
    /// still says online.
    static let onlineWindow: TimeInterval = 120

    /// `previous` fills in what a write's answer leaves out — the PATCH row
    /// carries no busy flag, no current jobs and no capacity.
    func runner(from dto: GitboyRunnerDTO, previous: ForgeRunner? = nil) -> ForgeRunner? {
        guard let runnerID = Self.nonEmpty(dto.id) else { return nil }
        let status = (dto.status ?? "").lowercased()
        let lastSeen = ISO8601Dates.parse(dto.lastSeenAt) ?? previous?.lastSeenAt
        let isOnline = status != "offline"
            && lastSeen.map { now().timeIntervalSince($0) <= Self.onlineWindow } == true
        let jobs = dto.currentJobs.map { rows in rows.compactMap { job(from: $0) } }
            ?? previous?.currentJobs ?? []
        return ForgeRunner(
            host: host,
            scope: scope,
            runnerID: runnerID,
            name: Self.nonEmpty(dto.name) ?? previous?.name ?? "",
            labels: dto.labels ?? previous?.labels ?? [],
            isOnline: isOnline,
            isPaused: status == "paused",
            isBusy: dto.busy ?? previous?.isBusy ?? !jobs.isEmpty,
            lastSeenAt: lastSeen,
            version: Self.nonEmpty(dto.version) ?? previous?.version,
            os: Self.nonEmpty(dto.host) ?? previous?.os,
            capacity: dto.capacity ?? previous?.capacity,
            isEphemeral: dto.ephemeral ?? previous?.isEphemeral ?? false,
            currentJobs: jobs)
    }

    func job(from dto: GitboyRunnerJobDTO) -> ForgeRunnerJob? {
        guard let jobID = Self.nonEmpty(dto.id) else { return nil }
        let webURL = Self.webLink(dto.htmlURL)
            ?? Self.pipelineLink(host: host, repository: dto.repository, runNumber: dto.pipelineIID)
        return ForgeRunnerJob(jobID: jobID,
                              name: Self.nonEmpty(dto.name) ?? "",
                              status: dto.status ?? "",
                              repository: Self.nonEmpty(dto.repository),
                              runNumber: dto.pipelineIID,
                              startedAt: ISO8601Dates.parse(dto.startedAt),
                              webURL: webURL)
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Only http(s) links are taken from the server; anything else would put an
    /// unchecked scheme behind a tap.
    private static func webLink(_ raw: String?) -> URL? {
        guard let value = nonEmpty(raw), let url = URL(string: value), url.host != nil else {
            return nil
        }
        let lowered = value.lowercased()
        guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://") else { return nil }
        return url
    }

    /// An older fleet row has no `html_url`; "owner/name" plus the pipeline
    /// number still points at the page a person can open.
    private static func pipelineLink(host: ForgeHost, repository: String?,
                                     runNumber: Int?) -> URL? {
        guard let runNumber, let repository else { return nil }
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return GitboyPullURLs.pipeline(host: host, owner: String(parts[0]),
                                       name: String(parts[1]), iid: runNumber)
    }
}

// MARK: - Client

extension GitboyClient {
    public func runners(_ scope: ForgeRunnerScope) async throws -> [ForgeRunner] {
        let bearer = try authorization()
        let (data, _) = try await transport.send(Self.runnersPath(scope), bearer: bearer)
        guard let page = try? JSONDecoder().decode(GitboyPage<GitboyRunnerDTO>.self, from: data) else {
            throw ForgeError.invalidResponse
        }
        let mapping = GitboyRunnerMapping(host: host, scope: scope)
        return page.items.compactMap { mapping.runner(from: $0) }
    }

    public func setPaused(_ paused: Bool,
                          runner: ForgeRunner) async throws -> ForgeRunner {
        let bearer = try authorization()
        let payload = try JSONSerialization.data(withJSONObject: ["status": paused ? "paused" : "online"])
        let path = Self.runnersPath(runner.scope) + "/" + Self.segment(runner.runnerID)
        let (data, _) = try await transport.send(path, method: "PATCH",
                                                 body: payload, bearer: bearer)
        let mapping = GitboyRunnerMapping(host: host, scope: runner.scope)
        guard let dto = try? JSONDecoder().decode(GitboyRunnerDTO.self, from: data),
              let updated = mapping.runner(from: dto, previous: runner) else {
            throw ForgeError.invalidResponse
        }
        return updated
    }

    public func remove(_ runner: ForgeRunner) async throws {
        let bearer = try authorization()
        let path = Self.runnersPath(runner.scope) + "/" + Self.segment(runner.runnerID)
        _ = try await transport.send(path, method: "DELETE", bearer: bearer)
    }

    /// `.mine` is the owner scope: the runners take jobs from every repository
    /// the account owns, and from no one else's.
    static func runnersPath(_ scope: ForgeRunnerScope) -> String {
        switch scope {
        case .mine:
            return "user/runners"
        case .org(let org):
            return "orgs/\(segment(org))/runners"
        case .repo(let owner, let name):
            return "repos/\(segment(owner))/\(segment(name))/runners"
        }
    }

    private static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
