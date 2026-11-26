import Foundation

/// DBeaver-style completion context for the SQL editor. It only looks at the
/// text around the caret, so it never needs the server: the candidates come
/// from the SELECT list of the current script and from the loaded result.
enum SQLCompletion {
    enum Kind {
        /// Column names are expected after WHERE / AND / ON / …
        case columns
        /// A comparison operator was typed, so values of one column are useful.
        case values(column: String)
    }

    struct Context {
        /// Range of the word being typed, replaced on commit.
        var range: NSRange
        /// Text before the caret that filters the candidates.
        var prefix: String
        var kind: Kind
    }

    /// Keywords after which a column name makes sense. Longer phrases are
    /// checked first so "ORDER BY" wins over "BY".
    private static let columnKeywords: [(String, String)] = [
        ("order by", "order by"), ("group by", "group by"),
        ("where", "where"), ("having", "having"), ("on", "on"),
        ("and", "and"), ("or", "or"), ("set", "set")
    ]

    /// Returns nil when the caret is not in a place where suggestions help:
    /// inside a string, inside a comment, or outside a WHERE-like clause.
    static func context(in text: NSString, caret: Int) -> Context? {
        guard caret >= 0, caret <= text.length else { return nil }
        guard !isInsideLiteralOrComment(text, at: caret) else { return nil }

        let range = wordRange(in: text, at: caret)
        let prefix = text.substring(with: range)
        let before = text.substring(to: range.location)

        // Start of the current statement keeps the scan cheap and prevents
        // suggestions leaking from a previous query.
        let nsBefore = before as NSString
        let semicolon = nsBefore.range(of: ";", options: .backwards)
        let statementStart = semicolon.location == NSNotFound ? 0 : semicolon.location + 1
        let statement = nsBefore.substring(from: statementStart)
        let lower = statement.lowercased()

        guard let keyword = lastColumnKeyword(in: lower) else { return nil }

        // Value mode: "column = " / "column LIKE " / "column IN (".
        let afterKeyword = (lower as NSString).substring(from: keyword.end)
        if let column = comparisonColumn(in: afterKeyword) {
            return Context(range: range, prefix: prefix, kind: .values(column: column))
        }
        // After a complete column name and a space, the next token is an
        // operator, not another column; do not reopen the list.
        let tail = afterKeyword as NSString
        let tailWithoutPrefix = tail.substring(to: max(0, tail.length - prefix.utf16.count))
        if prefix.isEmpty, !words(in: tailWithoutPrefix).isEmpty { return nil }
        return Context(range: range, prefix: prefix, kind: .columns)
    }

    /// True when the caret sits in a quoted string or after `--` on its line.
    private static func isInsideLiteralOrComment(_ text: NSString, at caret: Int) -> Bool {
        let lineStart = text.lineRange(for: NSRange(location: max(0, caret - 1), length: 0)).location
        let linePrefix = text.substring(with: NSRange(location: lineStart,
                                                      length: caret - lineStart))
        if let dash = linePrefix.range(of: "--", options: .backwards),
           !linePrefix[..<dash.lowerBound].contains("'") {
            return true
        }
        var insideString = false
        var index = max(0, caret - 20_000)
        while index < caret {
            let character = text.character(at: index)
            if character == 39 { // '
                if insideString, index + 1 < caret, text.character(at: index + 1) == 39 {
                    index += 1
                } else {
                    insideString.toggle()
                }
            } else if character == 10 || character == 13 {
                // A newline never resets an unterminated string on purpose:
                // PostgreSQL allows multi-line literals.
            }
            index += 1
        }
        return insideString
    }

    /// Word (identifier) range ending at the caret. Dots are included so a
    /// qualified name can be filtered as one token.
    static func wordRange(in text: NSString, at caret: Int) -> NSRange {
        var start = caret
        while start > 0 {
            let character = text.character(at: start - 1)
            if isWordCharacter(character) {
                start -= 1
            } else {
                break
            }
        }
        return NSRange(location: start, length: caret - start)
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
            || scalar == "_" || scalar == "." || scalar == "$" || scalar == "\""
    }

    /// Last keyword before the caret that introduces a column, if it is the
    /// closest clause keyword (so "WHERE x = 1 ORDER BY " suggests columns).
    private static func lastColumnKeyword(in lower: String) -> (keyword: String, end: Int)? {
        var best: (keyword: String, end: Int)?
        for (needle, _) in columnKeywords {
            var searchRange = lower.startIndex..<lower.endIndex
            while let found = lower.range(of: needle, options: .backwards, range: searchRange) {
                let beforeOK = found.lowerBound == lower.startIndex
                    || !isLetter(lower[lower.index(before: found.lowerBound)])
                let afterOK = found.upperBound == lower.endIndex
                    || !isLetter(lower[found.upperBound])
                if beforeOK && afterOK {
                    let end = lower.distance(from: lower.startIndex, to: found.upperBound)
                    if best == nil || end > best!.end {
                        best = (needle, end)
                    }
                    break
                }
                guard found.lowerBound > lower.startIndex else { break }
                searchRange = lower.startIndex..<lower.index(before: found.lowerBound)
            }
        }
        guard let best else { return nil }
        // A closer keyword from another clause cancels column mode.
        let tail = (lower as NSString).substring(from: best.end)
        let stopWords = ["select", "from", "join", "insert", "update", "delete",
                         "values", "returning", "union", "limit", "offset", "fetch"]
        let tailWords = words(in: tail)
        if let first = tailWords.first, stopWords.contains(first) { return nil }
        if tailWords.contains(where: { stopWords.contains($0) }) {
            // e.g. "where x in (select …" — the inner SELECT owns the caret.
            return nil
        }
        return best
    }

    private static func isLetter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
    }

    /// Detects `column <operator>` at the end of the tail and returns the column.
    private static func comparisonColumn(in tail: String) -> String? {
        let text = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let patterns = [
            #"([A-Za-z_][A-Za-z0-9_\.]*)\s*(?:=|!=|<>|>=|<=|>|<|like|ilike)\s*$"#,
            #"([A-Za-z_][A-Za-z0-9_\.]*)\s+(?:not\s+)?in\s*\(\s*$"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern,
                                                            options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(location: 0, length: (text as NSString).length)
            guard let match = expression.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges > 1 else { continue }
            let candidate = (text as NSString).substring(with: match.range(at: 1))
            let stop: Set<String> = ["and", "or", "where", "not", "is", "null", "on", "having"]
            if !stop.contains(candidate.lowercased()) {
                return candidate
            }
        }
        return nil
    }

    /// Columns named in the SELECT list of the script, plus aliases. Used when
    /// no result is loaded yet, so completion still works before the first run.
    static func selectListColumns(in sql: String) -> [String] {
        guard let selectRange = sql.range(of: "select", options: [.caseInsensitive]) else { return [] }
        let rest = sql[selectRange.upperBound...]
        let end = rest.range(of: "from", options: [.caseInsensitive])?.lowerBound ?? rest.endIndex
        let list = rest[..<end]
        var depth = 0
        var current = ""
        var items: [String] = []
        for character in list {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == "," && depth == 0 {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(current)
        }

        var names: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "*" || trimmed.hasSuffix(".*") { continue }
            let lower = trimmed.lowercased()
            if let asRange = lower.range(of: " as ", options: .backwards) {
                let alias = trimmed[asRange.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !alias.isEmpty { names.append(alias) }
                continue
            }
            // No AS: the last identifier is the alias, e.g. "sum(x) total".
            let parts = trimmed.split { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }
            if let last = parts.last {
                let name = last.split(separator: ".").last.map(String.init) ?? String(last)
                if !name.isEmpty { names.append(name) }
            }
        }
        return names
    }

    /// Filters candidates by the typed prefix, case-insensitively, keeping the
    /// original order (result columns first, then SELECT-list aliases).
    static func filter(_ candidates: [String], prefix: String) -> [String] {
        let needle = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .lowercased()
        var seen = Set<String>()
        var out: [String] = []
        for candidate in candidates {
            let key = candidate.lowercased()
            guard seen.insert(key).inserted else { continue }
            if needle.isEmpty || key.hasPrefix(needle) || key.contains(needle) {
                out.append(candidate)
            }
            if out.count >= 60 { break }
        }
        return out
    }
}
