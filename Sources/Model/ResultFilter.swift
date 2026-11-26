import Foundation

/// Local, DBeaver-style filter applied to the rows already loaded in the grid.
/// The filter is a single line of text:
///
/// - free text keeps rows where any visible cell contains it;
/// - `column <condition>` filters one column (`age > 10`, `name LIKE 'a%'`);
/// - a leading operator applies to every column (`> 10`, `LIKE %text%`).
///
/// It never touches the SQL script or the stored result: only the visible rows
/// change.
enum ResultFilter {
    // MARK: - Row matching

    /// True when the row passes the one-line filter. An empty query means
    /// "no filter".
    static func matches(row: [String?], columns: [ColumnInfo], query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        let lower = text.lowercased()

        // Explicit NULL filters across all columns.
        if lower == "null" || lower == "is null" {
            return row.contains { $0 == nil }
        }
        if lower == "is not null" {
            return row.contains { $0 != nil }
        }

        // `column <condition>`.
        if let parsed = parseColumnCondition(text, columns: columns) {
            let value = parsed.column < row.count ? row[parsed.column] : nil
            return matches(value: value, condition: parsed.condition,
                           numeric: columns[parsed.column].isNumeric)
        }

        // A leading operator (`> 10`, `LIKE %x%`) applies to every column:
        // the row passes when at least one cell satisfies it.
        if startsWithOperator(text) {
            for (index, column) in columns.enumerated() {
                let value = index < row.count ? row[index] : nil
                if matches(value: value, condition: text, numeric: column.isNumeric) {
                    return true
                }
            }
            return false
        }

        // Free text: case-insensitive substring in any cell.
        for value in row {
            guard let value, !value.isEmpty else { continue }
            if value.range(of: text,
                           options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    /// Matches one cell against a condition that starts with an operator
    /// (`= 1`, `LIKE %x%`, `IS NULL`, …) or is bare text.
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

    // MARK: - Parsing the one-line query

    private static func parseColumnCondition(
        _ text: String,
        columns: [ColumnInfo]
    ) -> (column: Int, condition: String)? {
        let ordered = columns.enumerated()
            .sorted { $0.element.name.count > $1.element.name.count }
        for (index, column) in ordered {
            let name = column.name
            guard !name.isEmpty, text.count > name.count else { continue }
            guard text.prefix(name.count).caseInsensitiveCompare(name) == .orderedSame else {
                continue
            }
            let tail = String(text.dropFirst(name.count))
            guard let first = tail.first, first.isWhitespace else { continue }
            let rest = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rest.isEmpty else { continue }
            guard startsWithOperator(rest) else { continue }
            return (index, rest)
        }
        return nil
    }

    private static let operatorPrefixes = [
        "!=", "<>", ">=", "<=", "=", ">", "<", "~", "!~", "^", "$"
    ]

    private static func startsWithOperator(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if operatorPrefixes.contains(where: { trimmed.hasPrefix($0) }) { return true }
        let keywords = ["like ", "ilike ", "not like ", "not ilike ",
                        "in ", "not in ", "is null", "is not null"]
        return keywords.contains { lower.hasPrefix($0) }
    }

    // MARK: - Suggestions for the filter field

    struct SuggestionContext {
        enum Kind {
            case columns
            case operators
            case values(String)
        }
        var range: NSRange
        var prefix: String
        var kind: Kind
    }

    /// What the user is likely to type at the caret. Returns nil for free
    /// text in the middle of the field, so the popup does not get in the way.
    static func suggestionContext(
        in text: NSString,
        caret: Int,
        columns: [String]
    ) -> SuggestionContext? {
        guard caret >= 0, caret <= text.length, !columns.isEmpty else { return nil }
        var range = SQLCompletion.wordRange(in: text, at: caret)
        let prefix = text.substring(with: range)
        let before = text.substring(to: range.location)
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return SuggestionContext(range: range, prefix: prefix, kind: .columns)
        }

        if columns.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return SuggestionContext(range: range, prefix: prefix, kind: .operators)
        }

        guard let parsed = columnAndOperator(in: trimmed, columns: columns) else {
            return nil
        }
        guard !parsed.isNull else { return nil }
        if parsed.rest.isEmpty || !prefix.isEmpty {
            // Replace the whole quoted literal, not just the word before the
            // caret, so a value with spaces is inserted as one piece.
            if let quote = openQuote(in: text, before: range.location) {
                let start = quote + 1
                let inner = text.substring(with: NSRange(location: start,
                                                         length: max(0, caret - start)))
                return SuggestionContext(range: NSRange(location: quote,
                                                        length: caret - quote),
                                         prefix: inner,
                                         kind: .values(parsed.column))
            }
            return SuggestionContext(range: range, prefix: prefix, kind: .values(parsed.column))
        }
        return nil
    }

    /// Position of the quote that opens the literal the caret is inside, if
    /// any. Scans back on the current line only.
    private static func openQuote(in text: NSString, before index: Int) -> Int? {
        var cursor = index - 1
        while cursor >= 0 {
            let character = text.character(at: cursor)
            if character == 10 || character == 13 { return nil }
            if character == 39 || character == 34 {
                // A doubled quote is an escaped quote, not a delimiter.
                if cursor > 0, text.character(at: cursor - 1) == character {
                    cursor -= 2
                    continue
                }
                return cursor
            }
            cursor -= 1
        }
        return nil
    }

    private static func columnAndOperator(
        in text: String,
        columns: [String]
    ) -> (column: String, rest: String, isNull: Bool)? {
        let operators = ["!=", "<>", ">=", "<=", "=", ">", "<",
                         "not like", "not ilike", "like", "ilike",
                         "not in", "in", "is not null", "is null"]
        for column in columns.sorted(by: { $0.count > $1.count }) {
            guard text.count > column.count else { continue }
            guard text.prefix(column.count).caseInsensitiveCompare(column) == .orderedSame else {
                continue
            }
            let tail = String(text.dropFirst(column.count))
            guard let first = tail.first, first.isWhitespace else { continue }
            var rest = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = rest.lowercased()
            guard let op = operators.first(where: { lower.hasPrefix($0) }) else { continue }
            rest = String(rest.dropFirst(op.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.hasPrefix("'") || rest.hasPrefix("\"") {
                rest.removeFirst()
            }
            let isNull = op == "is null" || op == "is not null"
            return (column, rest, isNull)
        }
        return nil
    }

    /// Operators offered after a column name, with a trailing space so the
    /// next suggestion (a value) opens immediately.
    static let operatorSuggestions = [
        "= ", "!= ", "> ", "< ", ">= ", "<= ",
        "LIKE ", "IN ", "IS NULL"
    ]

    // MARK: - Comparison helpers

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
