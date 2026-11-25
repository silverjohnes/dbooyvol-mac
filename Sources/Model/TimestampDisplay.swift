import Foundation

/// Display formatting for timestamp columns. Values come from the sidecar as
/// ISO strings (`2024-05-01T12:34:56`, `2024-05-01T12:34:56.123+03:00`).
/// They are converted to the time zone chosen in Settings.
///
/// A value without an explicit offset or `Z` is treated as UTC: the drivers
/// report timestamps without a zone as a wall clock, and the database these
/// scripts are written for stores them in UTC.
enum TimestampDisplay {
    static func isTimestampColumn(_ type: String) -> Bool {
        let t = type.uppercased()
        return t.contains("TIMESTAMP") || t.contains("DATETIME")
    }

    /// The string to show in the grid. Non-timestamp columns and values that
    /// cannot be parsed are returned unchanged.
    static func formatted(_ value: String?, columnType: String) -> String? {
        guard let value else { return nil }
        guard isTimestampColumn(columnType) else { return value }
        return format(value) ?? value
    }

    static func format(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 19 else { return nil }

        // Only date-time values are converted. A pure date (`2024-05-01`) and
        // a pure time (`12:34:56`) have no zone to convert from.
        let separator = text[text.index(text.startIndex, offsetBy: 10)]
        guard separator == "T" || separator == " " else { return nil }

        let datePart = String(text.prefix(10))
        var rest = String(text.dropFirst(11))

        // Trailing `Z` or `+03:00` / `+0300` / `+03`.
        var offsetSeconds = 0
        if rest.hasSuffix("Z") || rest.hasSuffix("z") {
            rest.removeLast()
        } else if let signIndex = rest.lastIndex(where: { $0 == "+" || $0 == "-" }),
                  let parsed = parseOffsetSeconds(String(rest[signIndex...])) {
            offsetSeconds = parsed
            rest = String(rest[..<signIndex])
        }

        // Fractional seconds, if any. Only the first three digits matter for
        // display, but all of them are used for the instant.
        var fraction = 0.0
        if let dot = rest.firstIndex(of: ".") {
            let digits = rest[rest.index(after: dot)...]
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                fraction = Double("0." + digits) ?? 0
            }
            rest = String(rest[..<dot])
        }

        guard rest.count == 8, rest[rest.index(rest.startIndex, offsetBy: 2)] == ":",
              rest[rest.index(rest.startIndex, offsetBy: 5)] == ":" else {
            return nil
        }

        let base = "\(datePart) \(rest)"
        guard let parsed = baseFormatter.date(from: base) else { return nil }
        let instant = parsed.addingTimeInterval(fraction - Double(offsetSeconds))

        let zone = TimeZones.selected
        let formatter = outputFormatter(for: zone)
        var result = formatter.string(from: instant)

        // Show milliseconds only when the source had a non-zero fraction.
        if fraction > 0 {
            let milliseconds = Int((fraction * 1000).rounded())
            if milliseconds > 0 {
                result += String(format: ".%03d", milliseconds)
            }
        }
        return result
    }

    private static func parseOffsetSeconds(_ text: String) -> Int? {
        guard let first = text.first, first == "+" || first == "-" else { return nil }
        let sign = first == "-" ? -1 : 1
        let body = text.dropFirst()
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        var hours = 0
        var minutes = 0
        switch parts.count {
        case 1:
            let digits = parts[0]
            if digits.count == 2 {
                hours = Int(digits) ?? 0
            } else if digits.count == 4 {
                hours = Int(digits.prefix(2)) ?? 0
                minutes = Int(digits.suffix(2)) ?? 0
            } else {
                return nil
            }
        case 2:
            guard parts[0].count == 2, parts[1].count == 2 else { return nil }
            hours = Int(parts[0]) ?? 0
            minutes = Int(parts[1]) ?? 0
        default:
            return nil
        }
        guard hours <= 18, minutes < 60 else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    private static let baseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Formatters are expensive; keep one per display zone. Results are shown
    /// on the main thread, so a plain dictionary is enough.
    private static var outputFormatters: [String: DateFormatter] = [:]

    private static func outputFormatter(for zone: TimeZone) -> DateFormatter {
        if let cached = outputFormatters[zone.identifier] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        outputFormatters[zone.identifier] = formatter
        return formatter
    }
}
