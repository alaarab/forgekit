import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why gitboy sign-in stopped before the person could approve it. These are
/// about the address, not the account, so they are a type of their own: an
/// app can tell them apart without matching text.
public enum GitboySignInError: Error, Equatable, Sendable, LocalizedError {
    /// The address answered, but not the way gitboy does.
    case notGitboyServer
    /// The server sent a sign-in page that is not on the instance itself.
    /// Carries the page it sent.
    case approvalPageElsewhere(URL)
    /// A sign-in answer was larger than any real one
    /// (`GitboyDeviceFlow.responseLimit`).
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .notGitboyServer:
            return "That address doesn't answer like a gitboy server. Check the host name."
        case .approvalPageElsewhere(let page):
            let place = page.host.map { " (\($0))" } ?? ""
            return "This server sent a sign-in page on another address\(place), so sign-in was stopped."
        case .responseTooLarge:
            return "The server's sign-in answer was too large to be a gitboy answer, so sign-in was stopped."
        }
    }
}

/// Step 1's response: what to show the user and how fast to poll.
public struct GitboyDeviceCode: Codable, Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let verificationURIComplete: URL?
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }

    public init(deviceCode: String, userCode: String, verificationURI: URL,
                verificationURIComplete: URL?, expiresIn: Int, interval: Int) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }

    /// RFC 8628 makes `interval` optional, with 5 seconds when it is left out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceCode = try c.decode(String.self, forKey: .deviceCode)
        userCode = try c.decode(String.self, forKey: .userCode)
        verificationURI = try c.decode(URL.self, forKey: .verificationURI)
        verificationURIComplete = try c.decodeIfPresent(URL.self, forKey: .verificationURIComplete)
        expiresIn = try c.decode(Int.self, forKey: .expiresIn)
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 5
    }
}

/// RFC 8628 device flow against a gitboy host. No client_id: the instance is
/// identified by its own host. The app says who it is (`clientName`, shown to
/// the person approving the sign-in) and what it needs (`scopes`).
public struct GitboyDeviceFlow: Sendable {
    /// The defaults, which are the ones Phren for iPhone shipped with. Another
    /// app passes its own name and scopes to `init`.
    public static let scopes = ["read:user", "read:repo", "write:repo", "read:issue", "write:issue"]
    public static let clientName = "Phren for iPhone"

    /// The name gitboy shows on its approval page.
    public let clientName: String
    /// The scopes the token is asked for. gitboy never grants `admin` this way.
    public let scopes: [String]

    private static let grantType = "urn:ietf:params:oauth:grant-type:device_code"
    private static let defaultSlowDownInterval = 5
    /// A sign-in answer is a few hundred bytes; anything past this is not one.
    public static let responseLimit = 64 * 1024

    private let transport: GitboyTransport

    public init(host: ForgeHost, session: URLSession = GitHubHTTPTransport.privateSession(),
                clientName: String = GitboyDeviceFlow.clientName,
                scopes: [String] = GitboyDeviceFlow.scopes) {
        self.transport = GitboyTransport(host: host, session: session)
        self.clientName = clientName
        self.scopes = scopes
    }

    public enum PollState: Equatable, Sendable {
        case authorized(ForgeCredential)
        case pending
        case slowDown(interval: Int)
        case expired
        case denied
    }

    /// Step 1: ask for the code pair to display.
    ///
    /// This is the first request to an address a person typed, so it is also
    /// where a wrong address shows: an answer that is not gitboy's is reported
    /// as that, and the approval page must be on the instance itself (https,
    /// same host and port, no credentials in the link). A page anywhere else
    /// would have the person approve a code on a site they did not choose.
    public func requestCode() async throws -> GitboyDeviceCode {
        let body = try JSONSerialization.data(withJSONObject: [
            "client_name": clientName,
            "scopes": scopes,
        ])
        let (data, http) = try await transport.send("auth/device/code", method: "POST",
                                                    body: body, bearer: nil, validate: false,
                                                    limit: Self.responseLimit)
        switch http.statusCode {
        case 200..<300:
            break
        case 404, 405:
            throw GitboySignInError.notGitboyServer
        default:
            throw GitboyTransport.error(status: http.statusCode, headers: http, data: data)
        }
        guard let code = try? JSONDecoder().decode(GitboyDeviceCode.self, from: data) else {
            throw GitboySignInError.notGitboyServer
        }
        let host = transport.host
        for page in [code.verificationURI] + [code.verificationURIComplete].compactMap({ $0 })
        where !GitboyRedirectPolicy.allows(page, host: host) {
            throw GitboySignInError.approvalPageElsewhere(page)
        }
        return code
    }

    /// Step 2: one poll. The 400 body is the protocol's state machine, not a
    /// transport failure, so it is decoded rather than thrown.
    public func poll(deviceCode: String) async throws -> PollState {
        try await poll(deviceCode: deviceCode, currentInterval: nil)
    }

    /// `slow_down` without an interval adds 5 seconds to the one in use, as
    /// RFC 8628 says; with no interval in use either, it is 5 seconds.
    func poll(deviceCode: String, currentInterval: Int?) async throws -> PollState {
        let body = try JSONSerialization.data(withJSONObject: [
            "device_code": deviceCode,
            "grant_type": Self.grantType,
        ])
        let (data, http) = try await transport.send("auth/device/token", method: "POST",
                                                    body: body, bearer: nil, validate: false,
                                                    limit: Self.responseLimit)
        switch http.statusCode {
        case 200..<300:
            guard let response = try? JSONDecoder().decode(GitboyTokenResponse.self, from: data),
                  !response.accessToken.isEmpty else {
                throw ForgeError.invalidResponse
            }
            return .authorized(credential(from: response))
        case 400:
            guard let failure = try? JSONDecoder().decode(GitboyDeviceFailure.self, from: data) else {
                throw ForgeError.invalidResponse
            }
            switch failure.error {
            case "authorization_pending": return .pending
            case "slow_down":
                return .slowDown(interval: failure.interval
                                 ?? (currentInterval.map { $0 + 5 } ?? Self.defaultSlowDownInterval))
            case "access_denied": return .denied
            case "expired_token", "invalid_grant": return .expired
            default: throw ForgeError.invalidResponse
            }
        default:
            throw GitboyTransport.error(status: http.statusCode, headers: http, data: data)
        }
    }

    /// Runs the poll loop on the server's interval until a terminal state or
    /// expiry; `slow_down` replaces the interval, per RFC 8628. Cancelling the
    /// task cancels the sleep and this call.
    public func waitForAuthorization(_ code: GitboyDeviceCode) async throws -> PollState {
        var interval = TimeInterval(max(1, code.interval))
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, code.expiresIn)))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            switch try await poll(deviceCode: code.deviceCode, currentInterval: Int(interval)) {
            case .authorized(let credential): return .authorized(credential)
            case .pending: continue
            case .slowDown(let newInterval): interval = TimeInterval(max(1, newInterval))
            case .expired: return .expired
            case .denied: return .denied
            }
        }
        return .expired
    }

    private func credential(from response: GitboyTokenResponse) -> ForgeCredential {
        ForgeCredential(host: transport.host,
                        token: response.accessToken,
                        user: response.user?.forgeUser(host: transport.host),
                        scopes: (response.scope ?? "").split(separator: " ").map(String.init),
                        expiresAt: ISO8601Dates.parse(response.expiresAt),
                        source: .deviceFlow)
    }
}

private struct GitboyTokenResponse: Decodable {
    let accessToken: String
    let scope: String?
    let expiresAt: String?
    let user: GitboyUserDTO?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case scope
        case expiresAt = "expires_at"
        case user
    }
}

private struct GitboyDeviceFailure: Decodable {
    let error: String
    let interval: Int?
}
