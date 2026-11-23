import AppKit

/// Text selection rules shared by the SQL editor and the value inspector, so
/// double and triple click behave the same in both: a word keeps dots and
/// underscores but stops at `-`, and a triple click selects the contents of a
/// quoted literal or of the innermost parentheses.
enum TextSelectionRules {
    static func isWordChar(_ c: unichar) -> Bool {
        if c == 95 || c == 36 || c == 46 { return true } // _ $ .
        guard let scalar = UnicodeScalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// The word under the caret. Dots and underscores stay inside a word
    /// (`D.SERIAL_NUMBER`), dashes do not.
    static func wordRange(in s: NSString, at location: Int) -> NSRange? {
        guard s.length > 0 else { return nil }
        let pos = min(max(location, 0), s.length - 1)

        var a = pos
        var b = pos
        if !isWordChar(s.character(at: pos)) {
            if pos > 0, isWordChar(s.character(at: pos - 1)) {
                a = pos - 1
                b = pos - 1
            } else {
                return nil
            }
        }
        while a > 0, isWordChar(s.character(at: a - 1)) { a -= 1 }
        while b < s.length - 1, isWordChar(s.character(at: b + 1)) { b += 1 }
        guard b >= a else { return nil }
        return NSRange(location: a, length: b - a + 1)
    }

    /// Contents of the quoted literal on the caret's line (without quotes).
    static func quotedContentsRange(in s: NSString, at location: Int) -> NSRange? {
        guard s.length > 0 else { return nil }
        let pos = min(max(location, 0), s.length - 1)

        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        s.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                       for: NSRange(location: pos, length: 0))

        var quoteStart = -1
        var quoteChar: unichar = 0
        var i = lineStart
        while i < contentsEnd {
            let c = s.character(at: i)
            if c == 39 || c == 34 {
                if quoteStart < 0 {
                    quoteStart = i
                    quoteChar = c
                } else if c == quoteChar {
                    if i + 1 < contentsEnd, s.character(at: i + 1) == quoteChar {
                        i += 2
                        continue
                    }
                    if pos >= quoteStart, pos <= i {
                        return NSRange(location: quoteStart + 1, length: i - quoteStart - 1)
                    }
                    quoteStart = -1
                }
            }
            i += 1
        }
        return nil
    }

    /// Contents of the innermost parentheses that enclose the caret.
    /// Quotes, `--` comments and `/* */` comments are ignored while matching.
    static func parenContentsRange(in s: NSString, at location: Int) -> NSRange? {
        guard s.length > 0 else { return nil }
        let pos = min(max(location, 0), s.length - 1)

        var stack: [Int] = []
        var best: (open: Int, close: Int)?
        var quote: unichar = 0
        var lineComment = false
        var blockComment = false
        var i = 0

        while i < s.length {
            let c = s.character(at: i)
            let next: unichar? = i + 1 < s.length ? s.character(at: i + 1) : nil

            if lineComment {
                if c == 10 || c == 13 { lineComment = false }
                i += 1
                continue
            }
            if blockComment {
                if c == 42, next == 47 { blockComment = false; i += 2; continue }
                i += 1
                continue
            }
            if quote != 0 {
                if c == quote {
                    if next == quote { i += 2; continue }
                    quote = 0
                }
                i += 1
                continue
            }
            if c == 45, next == 45 { lineComment = true; i += 2; continue }
            if c == 47, next == 42 { blockComment = true; i += 2; continue }
            if c == 39 || c == 34 { quote = c; i += 1; continue }

            if c == 40 {
                stack.append(i)
            } else if c == 41, let open = stack.popLast() {
                if pos >= open, pos <= i, best == nil || open > best!.open {
                    best = (open, i)
                }
            }
            i += 1
        }

        guard let best else { return nil }
        return NSRange(location: best.open + 1, length: best.close - best.open - 1)
    }

    /// The range a triple click should select, if any.
    static func literalContentsRange(in s: NSString, at location: Int) -> NSRange? {
        quotedContentsRange(in: s, at: location) ?? parenContentsRange(in: s, at: location)
    }
}
