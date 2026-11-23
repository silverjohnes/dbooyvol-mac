import AppKit

enum SQLHighlighter {
    static let defaultFontSize: CGFloat = 14

    static func font(size: CGFloat) -> NSFont {
        NSFont(name: "SFMono-Regular", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static var currentFont: NSFont {
        font(size: AppSettings.editorFontSize)
    }

    private static func paragraphStyle(for size: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = max(2, (size * 0.21).rounded())
        style.defaultTabInterval = (size * 2).rounded()
        return style
    }
    static let maxLength = 500_000

    private static let keywords: [String] = [
        "select", "from", "where", "and", "or", "not", "in", "exists", "between", "like", "ilike",
        "is", "null", "as", "on", "join", "left", "right", "full", "inner", "outer", "cross", "natural",
        "group", "by", "order", "having", "limit", "offset", "fetch", "next", "rows", "only",
        "union", "all", "intersect", "except", "minus", "distinct", "into", "values", "set",
        "insert", "update", "delete", "merge", "create", "alter", "drop", "truncate", "table", "view",
        "index", "sequence", "schema", "database", "grant", "revoke", "commit", "rollback", "begin",
        "start", "transaction", "with", "recursive", "case", "when", "then", "else", "end", "cast",
        "asc", "desc", "nulls", "first", "last", "over", "partition", "window", "row", "range",
        "using", "lateral", "returning", "conflict", "do", "nothing", "default", "primary", "key",
        "foreign", "references", "constraint", "unique", "check", "cascade", "restrict",
        "explain", "analyze", "vacuum", "show", "describe", "declare", "cursor", "open", "close",
        "for", "loop", "while", "if", "elsif", "procedure", "function", "trigger", "package", "body",
        "type", "subtype", "record", "exception", "raise", "return", "execute", "immediate",
        "connect", "to", "identified", "password", "session", "set", "role", "tablespace",
        "timestamp", "date", "interval", "time", "zone", "local", "number", "numeric", "decimal",
        "varchar", "varchar2", "char", "nchar", "nvarchar2", "text", "clob", "blob", "raw", "bytea",
        "integer", "int", "smallint", "bigint", "serial", "bigserial", "boolean", "bool", "float",
        "double", "precision", "real", "uuid", "json", "jsonb", "array", "enum", "domain",
        "true", "false", "unknown", "nowait", "wait", "skip", "locked", "share", "mode",
        "parallel", "hint", "materialized", "refresh", "temporary", "temp", "unlogged", "if"
    ]

    private static let keywordRegex = try! NSRegularExpression(
        pattern: "\\b(?:" + keywords.joined(separator: "|") + ")\\b",
        options: [.caseInsensitive]
    )
    private static let stringRegex = try! NSRegularExpression(pattern: "'(?:''|[^'])*'", options: [])
    private static let quotedIdentRegex = try! NSRegularExpression(pattern: "\"(?:[^\"]|\"\")*\"", options: [])
    private static let numberRegex = try! NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b", options: [])
    private static let lineCommentRegex = try! NSRegularExpression(pattern: "--[^\\n]*", options: [])
    private static let blockCommentRegex = try! NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/", options: [])
    private static let functionRegex = try! NSRegularExpression(pattern: "\\b[A-Za-z_][A-Za-z0-9_$]*(?=\\s*\\()", options: [])

    private static let keywordColor = NSColor.systemPink
    private static let stringColor = NSColor.systemGreen
    private static let numberColor = NSColor.systemOrange
    private static let commentColor = NSColor.secondaryLabelColor
    private static let functionColor = NSColor.systemBlue

    static func apply(to storage: NSTextStorage) {
        guard storage.length <= maxLength else { return }
        let size = AppSettings.editorFontSize
        let full = NSRange(location: 0, length: storage.length)
        let base: [NSAttributedString.Key: Any] = [
            .font: font(size: size),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle(for: size)
        ]
        storage.beginEditing()
        storage.setAttributes(base, range: full)

        apply(functionRegex, color: functionColor, storage: storage, full: full)
        apply(keywordRegex, color: keywordColor, storage: storage, full: full)
        apply(numberRegex, color: numberColor, storage: storage, full: full)
        apply(quotedIdentRegex, color: stringColor, storage: storage, full: full)
        apply(stringRegex, color: stringColor, storage: storage, full: full)
        apply(blockCommentRegex, color: commentColor, storage: storage, full: full)
        apply(lineCommentRegex, color: commentColor, storage: storage, full: full)

        storage.endEditing()
    }

    private static func apply(_ regex: NSRegularExpression, color: NSColor, storage: NSTextStorage, full: NSRange) {
        regex.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
            guard let range = match?.range else { return }
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
    }
}
