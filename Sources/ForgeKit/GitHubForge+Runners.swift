import Foundation

// MARK: - Mapping

extension GitHubRunnerDTO {
    func forgeRunner(host: ForgeHost, scope: ForgeRunnerScope) -> ForgeRunner {
        ForgeRunner(host: host,
                    scope: scope,
                    runnerID: String(id),
                    name: name ?? "",
                    labels: (labels ?? []).compactMap { label -> String? in
                        guard let name = label.name, !name.isEmpty else { return nil }
                        return name
                    },
                    isOnline: (status ?? "").lowercased() == "online",
                    // GitHub has no paused state: a runner is online and takes
                    // work, or it is offline.
                    isPaused: false,
                    isBusy: busy ?? false,
                    // The REST answer carries none of these.
                    lastSeenAt: nil,
                    version: nil,
                    os: os,
                    capacity: nil,
                    isEphemeral: false,
                    currentJobs: [])
    }
}

// MARK: - Forge conformance

extension GitHubForge {
    public func runners(_ scope: ForgeRunnerScope) async throws -> [ForgeRunner] {
        let rows = try await client.runners(scope: scope)
        return rows.map { $0.forgeRunner(host: host, scope: scope) }
    }

    public func setPaused(_ paused: Bool, runner: ForgeRunner) async throws -> ForgeRunner {
        throw ForgeError.server(status: 0, message: "GitHub runners can't be paused.")
    }

    public func remove(_ runner: ForgeRunner) async throws {
        try await client.removeRunner(scope: runner.scope, runnerID: runner.runnerID)
    }
}
