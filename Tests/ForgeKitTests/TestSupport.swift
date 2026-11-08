import Foundation
import XCTest

/// Request recording and route stubbing for the forge tests. Copied from
/// the app's GitHubClientTests so the extracted tests stay self-contained.
final class StubURLProtocol: URLProtocol {
    struct Stubbed {
        let status: Int
        let headers: [String: String]
        let body: String
        var redirect: Bool = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [Stubbed]] = [:]
    nonisolated(unsafe) private static var log: [(method: String, url: String)] = []
    nonisolated(unsafe) private static var headerLog: [[String: String]] = []
    nonisolated(unsafe) private static var bodyLog: [String] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        routes = [:]
        log = []
        headerLog = []
        bodyLog = []
    }

    /// Request bodies in request order ("" for none), for form-encoded posts.
    static var bodies: [String] {
        lock.lock(); defer { lock.unlock() }
        return bodyLog
    }

    private static func record(body: String) {
        lock.lock(); defer { lock.unlock() }
        bodyLog.append(body)
    }

    /// URLProtocol sees a posted body as a stream, not `httpBody`.
    private static func bodyText(_ request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func stub(_ urlContains: String, status: Int,
                     headers: [String: String] = [:], body: String = "{}", redirect: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        routes[urlContains, default: []].append(Stubbed(status: status, headers: headers, body: body, redirect: redirect))
    }

    static var requests: [(method: String, url: String)] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    /// Request headers in request order, parallel to `requests`: enough to
    /// prove where the token did and did not go.
    static var headers: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return headerLog
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func take(url: String, method: String, headers: [String: String]) -> Stubbed {
        lock.lock(); defer { lock.unlock() }
        log.append((method, url))
        headerLog.append(headers)
        // Longest match wins ("contents/phren.root.yaml" beats "repos/"), with
        // alphabetical order breaking ties so routing never depends on the
        // dictionary's iteration order.
        let key = routes.keys
            .filter { url.contains($0) }
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
            .first
        guard let key, var queued = routes[key], !queued.isEmpty else {
            return Stubbed(status: 404, headers: [:], body: #"{"message":"Not Found"}"#)
        }
        let next = queued.removeFirst()
        routes[key] = queued.isEmpty ? [next] : queued
        return next
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(body: Self.bodyText(request))
        let stubbed = Self.take(url: request.url?.absoluteString ?? "",
                                method: request.httpMethod ?? "GET",
                                headers: request.allHTTPHeaderFields ?? [:])
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stubbed.status,
                                             httpVersion: "HTTP/1.1", headerFields: stubbed.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if stubbed.redirect, let location = stubbed.headers["Location"], let target = URL(string: location) {
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stubbed.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
