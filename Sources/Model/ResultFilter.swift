import Foundation

/// Local, DBeaver-style filter applied to the rows already loaded in the grid.
/// It never touches the SQL script or the stored result: only the visible rows
/// change. An empty condition means "no filter" for that column.
enum ResultFilter {
    /// True when the row passes every condition. Conditions are combined with
    /// AND, exactly like additional predicates in a WHERE clause.
    static func matches(row: [String?],
                        columns: [ColumnInfo],
                        filters: [Int: String]) -> Bool {
        for (column, raw) in filters {
            let condition = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !condition.isEmpty, column >= 0, column < columns.count else { continue }
            let value = column < row.count ? row[column] : nil
            if !matches(value: value, condition: condition,
                        numeric: columns[column].isNumeric) {
                return false
            }
        }
        return true
    }

    static func matches(value: String?, condition: String, numeric: Bool) -> Bool {
        let text = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }

        let upper = text.uppercased()
        if upper == "NULL" || upper == "IS NULL" { return value == nil }
        if upper == "IS NOT NULL" || upper == "NOT NULL" { return value != nil }

        // SQL-ish operators, longest first so ">=" is not read as ">".
        let operators = ["!=", "<>", ">=", "<=", "=", ">", "<", "!~", "~", "^", "$"]
        for op in operators where text.hasPrefix(op) {
            let operand = String(text.dropFirst(op.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return compare(value: value, operand: operand, operator: op, numeric: numeric)
        }

        if upper.hasPrefix("NOT LIKE ") || upper.hasPrefix("NOT ILIKE ") {
            let operand = String(text.dropFirst("NOT LIKE ".count))
            return !like(value: value, pattern: operand)
        }
        if upper.hasPrefix("LIKE ") || upper.hasPrefix("ILIKE ") {
            let operand = String(text.dropFirst("LIKE ".count))
            return like(value: value, pattern: operand)
        }
        if upper.hasPrefix("NOT IN ") || upper.hasPrefix("IN ") {
            let isNot = upper.hasPrefix("NOT ")
            let start = isNot ? "NOT IN ".count : "IN ".count
            let list = String(text.dropFirst(start))
            let items = splitList(list)
            let found = items.contains { compare(value: value, operand: $0, operator: "=", numeric: numeric) }
            return isNot ? !found : found
        }

        // Bare text behaves like DBeaver's default filter: a case-insensitive
        // substring match. `*`/`%` are accepted as wildcards.
        return like(value: value, pattern: text, defaultContains: true)
    }

    private static func compare(value: String?, operand: String,
                                operator op: String, numeric: Bool) -> Bool {
        let clean = unquote(operand)
        switch op {
        case "=", "!=", "<>":
            let equal: Bool
            if value == nil || clean.uppercased() == "NULL" {
                equal = (value == nil) == (clean.uppercased() == "NULL")
            } else if numeric, let text = value, let a = number(text), let b = number(clean) {
                equal = a == b
            } else {
                equal = value!.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            return op == "=" ? equal : !equal
        case "~", "!~":
            let found = like(value: value, pattern: clean, defaultContains: true)
            return op == "~" ? found : !found
        case "^":
            guard let value else { return false }
            return value.lowercased().hasPrefix(clean.lowercased())
        case "$":
            guard let value else { return false }
            return value.lowercased().hasSuffix(clean.lowercased())
        default:
            guard let value else { return false }
            let order: ComparisonResult
            if numeric, let a = number(value), let b = number(clean) {
                order = a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
            } else {
                order = value.compare(clean, options: [.caseInsensitive, .diacriticInsensitive])
            }
            switch op {
            case ">": return order == .orderedDescending
            case ">=": return order != .orderedAscending
            case "<": return order == .orderedAscending
            case "<=": return order != .orderedDescending
            default: return false
            }
        }
    }

    /// SQL LIKE with `%` (any run) and `_` (one character). A bare pattern is
    /// treated as a substring unless `defaultContains` is false.
    private static func like(value: String?, pattern: String,
                             defaultContains: Bool = true) -> Bool {
        guard let value else { return false }
        var body = unquote(pattern)
        let hasWildcards = body.contains("%") || body.contains("*") || body.contains("_")
        if !hasWildcards, defaultContains {
            return value.range(of: body, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        body = body.replacingOccurrences(of: "*", with: "%")
        var regex = ""
        for character in body {
            switch character {
            case "%": regex += ".*"
            case "_": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        if defaultContains && !hasWildcards {
            regex = ".*" + regex + ".*"
        }
        guard let expression = try? NSRegularExpression(pattern: "^" + regex + "$",
                                                       options: [.caseInsensitive]) else {
            return value.range(of: body, options: .caseInsensitive) != nil
        }
        let range = NSRange(location: 0, length: (value as NSString).length)
        return expression.firstMatch(in: value, options: [], range: range) != nil
    }

    private static func splitList(_ text: String) -> [String] {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("(") { body.removeFirst() }
        if body.hasSuffix(")") { body.removeLast() }
        return body.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.hasPrefix("'") && value.hasSuffix("'"))
            || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
            value.removeFirst()
            value.removeLast()
            value = value.replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    private static func number(_ text: String) -> Decimal? {
        Decimal(string: text.replacingOccurrences(of: ",", with: "."),
                locale: Locale(identifier: "en_US_POSIX"))
    }
}
