import Foundation

/// One server-sent event. Ported from gitboy's iOS client so the two readers
/// split fields the same way.
public struct ForgeSSEEvent: Equatable, Sendable {
    public let event: String
    public let id: String?
    public let data: String

    public init(event: String, id: String?, data: String) {
        self.event = event
        self.id = id
        self.data = data
    }
}

/// Incremental bounded parser; event IDs count server bytes, never Swift characters.
///
/// Bytes arrive one at a time from `URLSession.AsyncBytes`, so a blank line —
/// not a buffer size — is what ends an event. A comment line (": keepalive")
/// produces nothing.
public struct ForgeSSEParser {
    /// A log chunk can be large; anything past this is not a log stream any more.
    public static let eventLimit = 8 * 1024 * 1024

    private var line = [UInt8]()
    private var kind = "message"
    private var id: String?
    private var parts = [String]()
    private var eventBytes = 0
    private var firstLine = true

    public init() {}

    public mutating func feed(_ byte: UInt8) throws -> ForgeSSEEvent? {
        eventBytes += 1
        guard eventBytes <= Self.eventLimit else { throw ForgeError.invalidResponse }
        guard byte == 10 else {
            line.append(byte)
            return nil
        }
        if line.last == 13 { line.removeLast() }
        let value = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        return consume(value)
    }

    /// The byte stream ended. A server that closes right after its last event,
    /// without the blank line that would dispatch it, still gives that event
    /// here: the line left in the buffer counts as complete, and a pending
    /// event is handed back instead of being dropped.
    public mutating func finish() throws -> ForgeSSEEvent? {
        if !line.isEmpty {
            var value = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            if value.hasSuffix("\r") { value.removeLast() }
            if let event = consume(value) { return event }
        }
        eventBytes = 0
        return take()
    }

    /// One complete line: a field, a comment, or the blank line that dispatches
    /// the event collected so far.
    private mutating func consume(_ raw: String) -> ForgeSSEEvent? {
        var value = raw
        if firstLine {
            value = value.replacingOccurrences(of: "\u{feff}", with: "")
            firstLine = false
        }
        if value.isEmpty {
            eventBytes = 0
            return take()
        }
        if value.hasPrefix(":") { return nil }
        let split = value.firstIndex(of: ":")
        let field = split.map { String(value[..<$0]) } ?? value
        var content = split.map { String(value[value.index(after: $0)...]) } ?? ""
        if content.hasPrefix(" ") { content.removeFirst() }
        switch field {
        case "event": kind = content
        case "id": if !content.contains("\0") { id = content }
        case "data": parts.append(content)
        default: break
        }
        return nil
    }

    private mutating func take() -> ForgeSSEEvent? {
        let event = parts.isEmpty ? nil : ForgeSSEEvent(event: kind, id: id,
                                                        data: parts.joined(separator: "\n"))
        kind = "message"
        id = nil
        parts = []
        return event
    }
}

/// The payload of a gitboy job log stream: a text chunk whose `id` is the byte
/// offset after it, or the terminal status. Unknown events are not log events
/// and are skipped by the caller.
public enum ForgeLogStreamEvent: Equatable, Sendable {
    case chunk(offset: Int, next: Int, text: String)
    case done(status: String)

    public init?(_ event: ForgeSSEEvent) throws {
        let decoder = JSONDecoder()
        do {
            if event.event == "log" {
                struct Chunk: Decodable {
                    let offset: Int
                    let text: String
                }
                let chunk = try decoder.decode(Chunk.self, from: Data(event.data.utf8))
                guard let id = event.id, let next = Int(id),
                      chunk.offset >= 0, next > chunk.offset else {
                    throw ForgeError.invalidResponse
                }
                self = .chunk(offset: chunk.offset, next: next, text: chunk.text)
            } else if event.event == "done" {
                struct Done: Decodable {
                    let status: String
                }
                self = .done(status: try decoder.decode(Done.self, from: Data(event.data.utf8)).status)
            } else {
                return nil
            }
        } catch {
            throw ForgeError.invalidResponse
        }
    }
}

/// Keeps a log screen to the end of a long job log. Both hosts share it so a
/// 40 MB log reads, and looks, the same on either.
public enum ForgeLogTrim {
    /// Says, in the text itself, that the start of the log is missing.
    public static let trimmedPrefix = "… earlier output trimmed\n"

    /// The last `limit` bytes of `text`, prefixed with `trimmedPrefix` when
    /// anything was dropped. A split multi-byte character at the cut is
    /// dropped whole instead of becoming a replacement character.
    public static func lastBytes(_ text: String, limit: Int = 512 * 1024) -> String {
        let bound = max(0, limit)
        guard text.utf8.count > bound else { return text }
        let suffix = text.utf8.suffix(bound).drop { ($0 & 0xC0) == 0x80 }
        return trimmedPrefix + String(decoding: suffix, as: UTF8.self)
    }
}
