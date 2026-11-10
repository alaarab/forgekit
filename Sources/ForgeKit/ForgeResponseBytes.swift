import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A response body read one byte at a time, for the live-log event stream.
//
// Apple platforms stream it as it arrives (`URLSession.AsyncBytes`).
// swift-corelibs-foundation has no `bytes(for:)`, so on Linux the body is read
// whole and then iterated: the same events in the same order, delivered when
// the response ends. Linux only builds and tests this package; no app ships
// from it, so nothing there waits on a live stream.

#if canImport(FoundationNetworking)
struct ForgeResponseBytes: AsyncSequence {
    typealias Element = UInt8

    let data: Data

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: Data.Iterator

        mutating func next() async throws -> UInt8? {
            iterator.next()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: data.makeIterator())
    }
}

extension URLSession {
    func forgeBytes(for request: URLRequest,
                    delegate: (any URLSessionTaskDelegate)?) async throws -> (ForgeResponseBytes, URLResponse) {
        let (data, response) = try await data(for: request, delegate: delegate)
        return (ForgeResponseBytes(data: data), response)
    }
}
#else
typealias ForgeResponseBytes = URLSession.AsyncBytes

extension URLSession {
    func forgeBytes(for request: URLRequest,
                    delegate: (any URLSessionTaskDelegate)?) async throws -> (ForgeResponseBytes, URLResponse) {
        try await bytes(for: request, delegate: delegate)
    }
}
#endif
