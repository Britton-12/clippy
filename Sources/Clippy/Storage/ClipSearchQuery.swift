import Foundation

/// A clip search query split into its parts: free text for full-text search,
/// `#` source-app filters, and a `#`-duration lower bound on the clip date.
///
/// Grammar (tokens are space separated, order independent):
///   - `#today`, `#yesterday`            -> since the start of that day
///   - `#2weeks`, `#2w`, `#3d`, `#1m`, `#1y`, `#week`, `#month`, `#year`
///                                        -> since now minus that span (count defaults to 1)
///   - any other `#token`                -> match the source app name or bundle id (substring)
///   - everything else                   -> free text, matched with FTS5
///
/// Example: `invoice #edge #2weeks` -> text "invoice", app "edge", since two weeks ago.
struct ParsedClipQuery: Equatable {
    var text: String
    var sourceApps: [String]
    var since: Date?

    var isEmpty: Bool { text.isEmpty && sourceApps.isEmpty && since == nil }
}

enum ClipQueryParser {
    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedClipQuery {
        var apps: [String] = []
        var since: Date?
        var textParts: [String] = []

        for token in raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            guard token.hasPrefix("#"), token.count > 1 else {
                textParts.append(String(token))
                continue
            }
            let body = String(token.dropFirst()).lowercased()
            if let date = relativeDate(body, now: now, calendar: calendar) {
                // Keep the widest window if several date tokens are given.
                since = Swift.min(since ?? date, date)
            } else {
                apps.append(body)
            }
        }

        return ParsedClipQuery(
            text: textParts.joined(separator: " "),
            sourceApps: apps,
            since: since
        )
    }

    /// Returns a lower-bound date for a duration token, or nil if the token is
    /// not a recognized duration (so the caller treats it as an app filter).
    private static func relativeDate(_ body: String, now: Date, calendar: Calendar) -> Date? {
        if body == "today" { return calendar.startOfDay(for: now) }
        if body == "yesterday" {
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        }

        // Split a leading count (default 1) from the unit, e.g. "2weeks" -> 2,"weeks".
        let digits = body.prefix { $0.isNumber }
        let count = digits.isEmpty ? 1 : (Int(digits) ?? 1)
        let unit = String(body.dropFirst(digits.count))

        let component: Calendar.Component
        switch unit {
        case "d", "day", "days":        component = .day
        case "w", "wk", "week", "weeks": component = .weekOfYear
        case "m", "mo", "month", "months": component = .month
        case "y", "yr", "year", "years": component = .year
        default: return nil
        }
        return calendar.date(byAdding: component, value: -count, to: now)
    }
}
