import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
}

/// RFC 8628 device flow against a gitboy host. No client_id: the instance is
/// identified by its own host, and scopes are fixed by `Self.scopes`.
public struct GitboyDeviceFlow: Sendable {
    public static let scopes = ["read:user", "read:repo", "write:repo", "read:issue", "write:issue"]
    public static let clientName = "Phren for iPhone"

    private static let grantType = "urn:ietf:params:oauth:grant-type:device_code"
    private static let defaultSlowDownInterval = 5

    private let transport: GitboyTransport

    public init(host: ForgeHost, session: URLSession = GitHubHTTPTransport.privateSession()) {
        self.transport = GitboyTransport(host: host, session: session)
    }

    public enum PollState: Equatable, Sendable {
        case authorized(ForgeCredential)
        case pending
        case slowDown(interval: Int)
        case expired
        case denied
    }

    /// Step 1: ask for the code pair to display.
    public func requestCode() async throws -> GitboyDeviceCode {
        let body = try JSONSerialization.data(withJSONObject: [
            "client_name": Self.clientName,
            "scopes": Self.scopes,
        ])
        let (data, _) = try await transport.send("auth/device/code", method: "POST",
                                                 body: body, bearer: nil)
        guard let code = try? JSONDecoder().decode(GitboyDeviceCode.self, from: data) else {
            throw ForgeError.invalidResponse
        }
        return code
    }

    /// Step 2: one poll. The 400 body is the protocol's state machine, not a
    /// transport failure, so it is decoded rather than thrown.
    public func poll(deviceCode: String) async throws -> PollState {
        let body = try JSONSerialization.data(withJSONObject: [
            "device_code": deviceCode,
            "grant_type": Self.grantType,
        ])
        let (data, http) = try await transport.send("auth/device/token", method: "POST",
                                                    body: body, bearer: nil, validate: false)
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
            case "slow_down": return .slowDown(interval: failure.interval ?? Self.defaultSlowDownInterval)
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
            switch try await poll(deviceCode: code.deviceCode) {
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
