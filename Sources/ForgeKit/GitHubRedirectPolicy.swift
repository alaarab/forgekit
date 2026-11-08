import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Repository renames can redirect within GitHub's API. Credentials and
/// request bodies must stay on the authenticated HTTPS origin.
public final class GitHubRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    public static let shared = GitHubRedirectPolicy()

    public static func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "api.github.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allows) == true ? request : nil)
    }
}

/// Reading a job-log Location. A server-sent URL is data, not URL syntax:
/// only a plain https URL with no userinfo is ever followed, and nothing else
/// leaves this device.
public enum GitHubLogURL {
    public static func signed(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value) else { return nil }
        return isHTTPS(url) ? url : nil
    }

    public static func isHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }
}

/// The signed blob may hand off to a CDN; every hop must still be https, and
/// none of them ever carries the token — the URL is the whole grant.
public final class GitHubHTTPSOnlyRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    public static let shared = GitHubHTTPSOnlyRedirectPolicy()

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(GitHubLogURL.isHTTPS) == true ? request : nil)
    }
}
