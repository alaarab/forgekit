import Foundation

/// The one ISO-8601 parser for timestamps the forge APIs emit.
///
/// Fractional seconds are tried first: `new Date().toISOString()` always
/// carries `.SSS`, so any other order throws once per value on the common
/// case. The styles are built once — a per-call `ISO8601DateFormatter()` is
/// the expensive part, not the parse.
///
/// Internal: this is a forge implementation detail, not part of ForgeKit's
/// public API, so a host app that already has its own parser can keep it.
enum ISO8601Dates {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()
    private static let dateOnly = Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!)
        .year().month().day().dateSeparator(.dash)

    /// `2026-09-10T12:00:00.123Z`, `2026-09-10T13:00:00+01:00`, or a bare
    /// `2026-09-10` (read as midnight UTC). nil for nil or anything else.
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = try? fractional.parse(text) { return date }
        if let date = try? whole.parse(text) { return date }
        return text.count == 10 ? try? dateOnly.parse(text) : nil
    }

    // ISO8601DateFormatter rounds a parsed .456 second where ISO8601FormatStyle
    // can truncate it to .455, so writing goes through the formatter, built once.
    // The formatter is not Sendable and is not safe to use concurrently, so a
    // small locked box owns it and serializes calls.
    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private let formatter: ISO8601DateFormatter

        init(fractionalSeconds: Bool) {
            let formatter = ISO8601DateFormatter()
            if fractionalSeconds {
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            }
            self.formatter = formatter
        }

        func string(from date: Date) -> String {
            lock.lock(); defer { lock.unlock() }
            return formatter.string(from: date)
        }
    }

    private static let writerFractional = Writer(fractionalSeconds: true)
    private static let writerWhole = Writer(fractionalSeconds: false)

    /// `2026-09-10T12:00:00.123Z` with `fractionalSeconds`, else
    /// `2026-09-10T12:00:00Z`. Always UTC.
    static func string(from date: Date, fractionalSeconds: Bool = false) -> String {
        (fractionalSeconds ? writerFractional : writerWhole).string(from: date)
    }
}
