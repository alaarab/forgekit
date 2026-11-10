import Foundation

/// What a gitboy host says about one personal access token.
public struct ForgeTokenInfo: Equatable, Sendable {
    public let name: String?
    public let scopes: [String]
    public let expiresAt: Date?

    public init(name: String?, scopes: [String], expiresAt: Date?) {
        self.name = name
        self.scopes = scopes
        self.expiresAt = expiresAt
    }
}

struct GitboyTokenDTO: Decodable, Sendable {
    let name: String?
    let lastEight: String?
    let scopes: [String]?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case name, scopes
        case lastEight = "last_eight"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenient(.name)
        lastEight = c.lenient(.lastEight)
        scopes = c.lenient(.scopes)
        expiresAt = c.lenient(.expiresAt)
    }
}

extension GitboyClient {
    /// The scopes and expiry of the token this client signs requests with. A
    /// pasted token carries neither, so this is how an app learns what the
    /// token may do and when it runs out.
    ///
    /// gitboy lists the account's tokens by their last eight characters. nil
    /// when that does not pick out exactly one: a guess could show the wrong
    /// token's scopes. The list itself needs `read:user`.
    public func tokenInfo() async throws -> ForgeTokenInfo? {
        let bearer = try authorization()
        let (data, _) = try await transport.send("user/tokens", bearer: bearer)
        guard let page = try? JSONDecoder().decode(GitboyPage<GitboyTokenDTO>.self, from: data) else {
            throw ForgeError.invalidResponse
        }
        let suffix = String(bearer.suffix(8))
        let matches = page.items.filter { $0.lastEight == suffix }
        guard matches.count == 1, let match = matches.first else { return nil }
        return ForgeTokenInfo(name: GitboyRunnerMapping.nonEmpty(match.name),
                              scopes: match.scopes ?? [],
                              expiresAt: ISO8601Dates.parse(match.expiresAt))
    }
}
