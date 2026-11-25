import Foundation
import AppKit

enum SQLText {
    /// Splits a script into statements, respecting strings, dollar-quotes and comments.
    static func statements(in sql: String) -> [(range: NSRange, text: String)] {
        let ns = sql as NSString
        var result: [(NSRange, String)] = []
        var start = 0
        var i = 0
        let n = ns.length

        func flush(_ end: Int) {
            let r = NSRange(location: start, length: end - start)
            let t = ns.substring(with: r)
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append((r, t))
            }
        }

        while i < n {
            let c = ns.character(at: i)
            // line comment
            if c == 45, i + 1 < n, ns.character(at: i + 1) == 45 {
                while i < n, ns.character(at: i) != 10 { i += 1 }
                continue
            }
            // block comment
            if c == 47, i + 1 < n, ns.character(at: i + 1) == 42 {
                i += 2
                while i + 1 < n, !(ns.character(at: i) == 42 && ns.character(at: i + 1) == 47) { i += 1 }
                i = min(i + 2, n)
                continue
            }
            // dollar quote (Postgres)
            if c == 36, let tag = dollarTag(ns, at: i) {
                let close = "$\(tag)$"
                let searchRange = NSRange(location: i + close.count, length: max(0, n - i - close.count))
                let found = ns.range(of: close, options: [], range: searchRange)
                i = found.location == NSNotFound ? n : found.location + found.length
                continue
            }
            if c == 39 || c == 34 {
                let quote = c
                i += 1
                while i < n {
                    let d = ns.character(at: i)
                    if d == quote {
                        if i + 1 < n, ns.character(at: i + 1) == quote { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                continue
            }
            if c == 59 { // ;
                flush(i)
                i += 1
                start = i
                continue
            }
            i += 1
        }
        flush(n)
        return result
    }

    private static func dollarTag(_ ns: NSString, at index: Int) -> String? {
        var j = index + 1
        var tag = ""
        while j < ns.length {
            let c = ns.character(at: j)
            if c == 36 { return tag }
            let isWord = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
            if isWord {
                tag.append(Character(UnicodeScalar(c)!))
                j += 1
            } else {
                return nil
            }
        }
        return nil
    }

    static func statement(at location: Int, in sql: String) -> String? {
        let list = statements(in: sql)
        for item in list where NSLocationInRange(min(location, max(0, sql.utf16.count - 1)), item.range) {
            return item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return list.last?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Named bind parameters (`:name`) outside strings and comments, in order of
    /// first appearance. PostgreSQL casts (`::type`) and assignments (`:=`) are
    /// not parameters.
    static func parameters(in sql: String) -> [String] {
        let ns = sql as NSString
        var names: [String] = []
        var seen = Set<String>()
        var i = 0
        let n = ns.length

        func isWordStart(_ c: unichar) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }
        func isWord(_ c: unichar) -> Bool {
            isWordStart(c) || (c >= 48 && c <= 57) || c == 36 || c == 35
        }

        while i < n {
            let c = ns.character(at: i)
            if c == 45, i + 1 < n, ns.character(at: i + 1) == 45 {
                while i < n, ns.character(at: i) != 10 { i += 1 }
                continue
            }
            if c == 47, i + 1 < n, ns.character(at: i + 1) == 42 {
                i += 2
                while i + 1 < n, !(ns.character(at: i) == 42 && ns.character(at: i + 1) == 47) { i += 1 }
                i = min(i + 2, n)
                continue
            }
            if c == 36, let tag = dollarTag(ns, at: i) {
                let close = "$\(tag)$"
                let searchRange = NSRange(location: i + close.count, length: max(0, n - i - close.count))
                let found = ns.range(of: close, options: [], range: searchRange)
                i = found.location == NSNotFound ? n : found.location + found.length
                continue
            }
            if c == 39 || c == 34 {
                let quote = c
                i += 1
                while i < n {
                    let d = ns.character(at: i)
                    if d == quote {
                        if i + 1 < n, ns.character(at: i + 1) == quote { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                continue
            }
            if c == 58 { // :
                if i + 1 < n {
                    let next = ns.character(at: i + 1)
                    if next == 58 || next == 61 { i += 2; continue } // :: cast, := assignment
                    if isWordStart(next) {
                        var j = i + 2
                        while j < n, isWord(ns.character(at: j)) { j += 1 }
                        let name = ns.substring(with: NSRange(location: i + 1, length: j - i - 1))
                        if seen.insert(name.lowercased()).inserted { names.append(name) }
                        i = j
                        continue
                    }
                }
            }
            i += 1
        }
        return names
    }

    /// Words that end a WHERE clause. A quoted value after one of them belongs
    /// to another clause (grouping, sorting, another statement) and must not be
    /// picked by smart selection.
    private static let clauseEndKeywords: Set<String> = [
        "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "FETCH", "UNION",
        "EXCEPT", "INTERSECT", "RETURNING", "WINDOW", "CONNECT", "START", "MODEL"
    ]

    /// Content of the first quoted value inside a WHERE clause that is not
    /// commented out. Conditions introduced by AND/OR are part of the same
    /// clause, so scanning from WHERE covers them without treating the AND of
    /// a `BETWEEN … AND …` pair as a new condition.
    static func firstQuotedFilterValue(in sql: String) -> NSRange? {
        let ns = sql as NSString
        let n = ns.length
        var i = 0

        while i < n {
            let c = ns.character(at: i)
            if c == 45, i + 1 < n, ns.character(at: i + 1) == 45 {
                while i < n, ns.character(at: i) != 10 { i += 1 }
                continue
            }
            if c == 47, i + 1 < n, ns.character(at: i + 1) == 42 {
                i += 2
                while i + 1 < n, !(ns.character(at: i) == 42 && ns.character(at: i + 1) == 47) { i += 1 }
                i = min(i + 2, n)
                continue
            }
            if c == 36, let tag = dollarTag(ns, at: i) {
                let close = "$\(tag)$"
                let searchRange = NSRange(location: i + close.count, length: max(0, n - i - close.count))
                let found = ns.range(of: close, options: [], range: searchRange)
                i = found.location == NSNotFound ? n : found.location + found.length
                continue
            }
            if c == 39 || c == 34 {
                skipQuoted(ns, from: i, quote: c, limit: n, index: &i)
                continue
            }
            if isWordStart(c) {
                let start = i
                var j = i + 1
                while j < n, isWord(ns.character(at: j)) { j += 1 }
                let word = ns.substring(with: NSRange(location: start, length: j - start)).uppercased()
                if word == "WHERE", let value = quotedValueInClause(ns, from: j) {
                    return value
                }
                i = j
                continue
            }
            i += 1
        }
        return nil
    }

    /// Advances `index` past a quoted string or quoted identifier.
    private static func skipQuoted(_ ns: NSString, from index: Int, quote: unichar,
                                   limit: Int, index out: inout Int) {
        var i = index + 1
        while i < limit {
            let d = ns.character(at: i)
            if d == quote {
                if i + 1 < limit, ns.character(at: i + 1) == quote { i += 2; continue }
                i += 1
                break
            }
            i += 1
        }
        out = min(i, limit)
    }

    /// First non-empty single-quoted literal after a WHERE keyword, stopping at
    /// the end of the statement or at the next clause. For LIKE/ILIKE the
    /// leading and trailing mask characters (`%`, `_`) are left out, so
    /// `LIKE '%name%'` selects `name`.
    private static func quotedValueInClause(_ ns: NSString, from index: Int) -> NSRange? {
        let n = ns.length
        var i = index
        var depth = 0
        /// Whether the operator right before the current position is LIKE or
        /// ILIKE. Function names and their parentheses (`upper('%x%')`) do not
        /// reset it, so a wrapped pattern is still recognised as a mask.
        var isLike = false

        while i < n {
            let c = ns.character(at: i)
            if c == 45, i + 1 < n, ns.character(at: i + 1) == 45 {
                while i < n, ns.character(at: i) != 10 { i += 1 }
                continue
            }
            if c == 47, i + 1 < n, ns.character(at: i + 1) == 42 {
                i += 2
                while i + 1 < n, !(ns.character(at: i) == 42 && ns.character(at: i + 1) == 47) { i += 1 }
                i = min(i + 2, n)
                continue
            }
            if c == 36, let tag = dollarTag(ns, at: i) {
                let close = "$\(tag)$"
                let searchRange = NSRange(location: i + close.count, length: max(0, n - i - close.count))
                let found = ns.range(of: close, options: [], range: searchRange)
                i = found.location == NSNotFound ? n : found.location + found.length
                continue
            }
            if c == 39 { // '
                var j = i + 1
                while j < n {
                    let d = ns.character(at: j)
                    if d == 39 {
                        if j + 1 < n, ns.character(at: j + 1) == 39 { j += 2; continue }
                        break
                    }
                    j += 1
                }
                let end = min(j, n)
                if end > i + 1 {
                    var range = NSRange(location: i + 1, length: end - i - 1)
                    if isLike { range = trimmingMask(ns, range) }
                    if range.length > 0 { return range }
                }
                // `''` is a valid value but selecting it shows nothing; keep
                // looking for the next one. The same goes for a LIKE pattern
                // that consists only of mask characters (`'%'`).
                i = min(end + 1, n)
                continue
            }
            if c == 34 {
                skipQuoted(ns, from: i, quote: c, limit: n, index: &i)
                continue
            }
            if c == 40 { depth += 1; i += 1; continue }
            if c == 41 {
                if depth == 0 { return nil }
                depth -= 1
                i += 1
                continue
            }
            if c == 59, depth == 0 { return nil } // ;
            if isWordStart(c) {
                let start = i
                var j = i + 1
                while j < n, isWord(ns.character(at: j)) { j += 1 }
                let word = ns.substring(with: NSRange(location: start, length: j - start)).uppercased()
                if depth == 0, clauseEndKeywords.contains(word) { return nil }
                if word == "LIKE" || word == "ILIKE" {
                    isLike = true
                } else if operatorResetsMaskKeywords.contains(word) {
                    isLike = false
                }
                i = j
                continue
            }
            // A comparison symbol means the next literal is a plain value, not
            // a mask (`x = '%name%'` keeps its percent signs).
            if c == 61 || c == 60 || c == 62 || c == 33 || c == 126 {
                isLike = false
            }
            i += 1
        }
        return nil
    }

    /// Keywords that end a LIKE pattern context: the literal that follows them
    /// belongs to another operator, so mask characters must not be stripped.
    private static let operatorResetsMaskKeywords: Set<String> = [
        "IN", "BETWEEN", "IS", "AND", "OR", "NOT",
        "SIMILAR", "REGEXP", "RLIKE"
    ]

    /// Cuts leading and trailing LIKE wildcards (`%`, `_`) from a quoted value.
    private static func trimmingMask(_ ns: NSString, _ range: NSRange) -> NSRange {
        var start = range.location
        var end = range.location + range.length
        func isMask(_ index: Int) -> Bool {
            let c = ns.character(at: index)
            return c == 37 || c == 95 // % or _
        }
        while start < end, isMask(start) { start += 1 }
        while end > start, isMask(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Removes LIKE mask characters from the contents of a quoted literal when
    /// that literal is a LIKE/ILIKE pattern. Used by triple click, which
    /// selects the whole quoted value regardless of the operator.
    static func maskTrimmedRange(_ range: NSRange, in sql: String) -> NSRange {
        let ns = sql as NSString
        guard range.length > 0, range.location > 0,
              ns.character(at: range.location - 1) == 39,
              isLikeOperator(before: range.location - 1, in: ns) else {
            return range
        }
        let trimmed = trimmingMask(ns, range)
        // A pattern made only of masks (`'%'`) has nothing else to show.
        return trimmed.length > 0 ? trimmed : range
    }

    /// Whether the operator immediately before `index` is LIKE/ILIKE. Scans
    /// from the start of the text so comments, strings and nested calls are
    /// handled the same way as in `quotedValueInClause`.
    private static func isLikeOperator(before index: Int, in ns: NSString) -> Bool {
        var i = 0
        var isLike = false
        while i < index {
            let c = ns.character(at: i)
            if c == 45, i + 1 < index, ns.character(at: i + 1) == 45 {
                while i < index, ns.character(at: i) != 10 { i += 1 }
                continue
            }
            if c == 47, i + 1 < index, ns.character(at: i + 1) == 42 {
                i += 2
                while i + 1 < index, !(ns.character(at: i) == 42 && ns.character(at: i + 1) == 47) { i += 1 }
                i = min(i + 2, index)
                continue
            }
            if c == 36, let tag = dollarTag(ns, at: i) {
                let close = "$\(tag)$"
                let searchRange = NSRange(location: i + close.count, length: max(0, index - i - close.count))
                let found = ns.range(of: close, options: [], range: searchRange)
                i = found.location == NSNotFound ? index : found.location + found.length
                continue
            }
            if c == 39 || c == 34 {
                skipQuoted(ns, from: i, quote: c, limit: index, index: &i)
                continue
            }
            if isWordStart(c) {
                let start = i
                var j = i + 1
                while j < index, isWord(ns.character(at: j)) { j += 1 }
                let word = ns.substring(with: NSRange(location: start, length: j - start)).uppercased()
                if word == "LIKE" || word == "ILIKE" {
                    isLike = true
                } else if operatorResetsMaskKeywords.contains(word) {
                    isLike = false
                }
                i = j
                continue
            }
            if c == 61 || c == 60 || c == 62 || c == 33 || c == 126 {
                isLike = false
            }
            i += 1
        }
        return isLike
    }

    private static func isWordStart(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    }

    private static func isWord(_ c: unichar) -> Bool {
        isWordStart(c) || (c >= 48 && c <= 57) || c == 36 || c == 35
    }
}

@MainActor
final class EditorController: ObservableObject {
    weak var textView: NSTextView?
    @Published var text: String = ""
    @Published var hasSelection: Bool = false
    /// Tab whose text is currently loaded into the text view. Used to avoid
    /// pulling stale editor content into a tab that has just been created.
    var displayedTabID: UUID?

    func allText() -> String {
        textView?.string ?? text
    }

    func selectedText() -> String? {
        guard let tv = textView else { return nil }
        let range = tv.selectedRange()
        guard range.length > 0 else { return nil }
        return (tv.string as NSString).substring(with: range)
    }

    func setText(_ value: String) {
        textView?.string = value
        text = value
        if let tv = textView {
            tv.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    /// Re-applies highlighting with the current size, keeping the caret and scroll position.
    func applyFontSize(_ size: CGFloat) {
        guard let tv = textView else { return }
        let selection = tv.selectedRange()
        if let storage = tv.textStorage {
            SQLHighlighter.apply(to: storage)
        }
        tv.font = SQLHighlighter.font(size: size)
        tv.setSelectedRange(selection)
        tv.scrollRangeToVisible(selection)
    }

    func statementAtCursor() -> String? {
        guard let tv = textView else { return nil }
        let loc = tv.selectedRange().location
        return SQLText.statement(at: loc, in: tv.string)
    }

    /// Cmd+/: prefixes every affected line with `--`, or removes the prefix
    /// when all non-blank lines in the selection are already commented.
    /// The caret/selection is kept in place instead of selecting the line.
    func toggleComment() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = tv.string as NSString
        var range = tv.selectedRange()
        let before = range

        // A selection ending exactly at the start of a line must not comment
        // the following line.
        if range.length > 0 {
            let end = range.location + range.length
            if end > range.location, end <= ns.length,
               end == 0 || ns.character(at: end - 1) == 10 {
                range.length -= 1
            }
        }

        let lineRange = ns.lineRange(for: range)
        let block = ns.substring(with: lineRange)
        guard !block.isEmpty else { return }

        let hasTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }

        let meaningful = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !meaningful.isEmpty else { return }
        let allCommented = meaningful.allSatisfy(Self.isLineCommented)

        let updated = lines.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            return allCommented ? Self.uncomment(line) : Self.comment(line)
        }

        var replacement = updated.joined(separator: "\n")
        if hasTrailingNewline { replacement += "\n" }
        guard replacement != block else { return }

        // Offsets of every line before and after the edit, used to move the
        // caret by exactly the number of inserted/removed `--` characters.
        var oldStarts: [Int] = []
        var newStarts: [Int] = []
        var newLens: [Int] = []
        var prefixLens: [Int] = []
        var deltas: [Int] = []
        var oldOffset = 0
        var newOffset = 0
        for (old, new) in zip(lines, updated) {
            oldStarts.append(oldOffset)
            newStarts.append(newOffset)
            newLens.append((new as NSString).length)
            prefixLens.append(Self.indentPrefix(old).count)
            deltas.append((new as NSString).length - (old as NSString).length)
            oldOffset += (old as NSString).length + 1
            newOffset += (new as NSString).length + 1
        }

        func map(_ location: Int) -> Int {
            let rel = location - lineRange.location
            guard rel > 0, !oldStarts.isEmpty else { return lineRange.location }
            var index = oldStarts.count - 1
            while index > 0, rel < oldStarts[index] { index -= 1 }
            let inLine = rel - oldStarts[index]
            // newStarts are relative to the edited block, so the block's own
            // offset has to be added back or the caret lands on the first line.
            if inLine <= prefixLens[index] {
                return lineRange.location + newStarts[index] + inLine
            }
            let shifted = inLine + deltas[index]
            return lineRange.location
                + newStarts[index]
                + min(max(prefixLens[index], shifted), newLens[index])
        }

        guard tv.shouldChangeText(in: lineRange, replacementString: replacement) else { return }
        storage.replaceCharacters(in: lineRange, with: replacement)
        tv.didChangeText()

        let caret = map(before.location)
        if before.length == 0 {
            tv.setSelectedRange(NSRange(location: caret, length: 0))
        } else {
            let end = map(before.location + before.length)
            tv.setSelectedRange(NSRange(location: caret, length: max(0, end - caret)))
        }
        tv.scrollRangeToVisible(tv.selectedRange())
    }

    private static func indentPrefix(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private static func isLineCommented(_ line: String) -> Bool {
        line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("--")
    }

    private static func comment(_ line: String) -> String {
        let indent = indentPrefix(line)
        let rest = line.dropFirst(indent.count)
        if rest.hasPrefix("--") { return line }
        return indent + "--" + rest
    }

    private static func uncomment(_ line: String) -> String {
        let indent = indentPrefix(line)
        var rest = String(line.dropFirst(indent.count))
        guard rest.hasPrefix("--") else { return line }
        rest.removeFirst(2)
        if rest.hasPrefix(" ") { rest.removeFirst() }
        return indent + rest
    }

    // MARK: - search

    private var searchRanges: [NSRange] = []
    private var searchIndex = -1

    /// Highlights every match of the query (and its layout twin) in the active
    /// script and selects the first one. Returns the number of matches.
    @discardableResult
    func highlightSearch(_ query: String) -> Int {
        clearSearchHighlight()
        guard let tv = textView, let lm = tv.layoutManager else { return 0 }
        searchRanges = SearchMatcher.allRanges(in: tv.string, query: query)
        let color = NSColor.systemYellow.withAlphaComponent(0.32)
        for range in searchRanges {
            lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
        }
        if let first = searchRanges.first {
            searchIndex = 0
            tv.setSelectedRange(first)
            tv.scrollRangeToVisible(first)
        }
        return searchRanges.count
    }

    func selectSearchMatch(forward: Bool) {
        guard let tv = textView, !searchRanges.isEmpty else { return }
        if forward {
            searchIndex = (searchIndex + 1) % searchRanges.count
        } else {
            searchIndex = (searchIndex - 1 + searchRanges.count) % searchRanges.count
        }
        let range = searchRanges[searchIndex]
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
    }

    func clearSearchHighlight() {
        if let tv = textView, let lm = tv.layoutManager, !searchRanges.isEmpty {
            lm.removeTemporaryAttribute(.backgroundColor,
                                        forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
        }
        searchRanges = []
        searchIndex = -1
    }
}
