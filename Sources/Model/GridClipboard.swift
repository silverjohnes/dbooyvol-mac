import Foundation

/// How a value is written to the clipboard. Mirrors DBeaver's copy setting.
enum GridValueFormat: String, Codable, CaseIterable {
    case display
    case editable
    case databaseNative

    var title: String {
        switch self {
        case .display: return L10n.tr("Display (по умолчанию)")
        case .editable: return L10n.tr("Редактируемое")
        case .databaseNative: return L10n.tr("Как в базе")
        }
    }
}

/// Settings of the "Копировать…" dialog. Stored in UserDefaults, so the next
/// copy uses the same delimiters and quoting.
struct GridCopySettings: Codable, Equatable {
    var copyHeader = false
    var copyRowNumbers = false
    var quoteValues = true
    var alwaysQuote = false
    var copyAsHTML = false
    var valueFormat: GridValueFormat = .display
    var columnDelimiter = "\t"
    var rowDelimiter = "\n"
    var quoteCharacter = "\""
    /// Last non-standard value typed by the user. Only one is remembered per
    /// field; it stays in the list even after a standard value is picked.
    var customColumnDelimiter = ""
    var customRowDelimiter = ""
    var customQuoteCharacter = ""

    static let standardColumnDelimiters = ["\t", ";", ","]
    static let standardRowDelimiters = ["\n", "|", "^"]
    static let standardQuoteCharacters = ["\"", "'"]

    private enum CodingKeys: String, CodingKey {
        case copyHeader, copyRowNumbers, quoteValues, alwaysQuote, copyAsHTML
        case valueFormat, columnDelimiter, rowDelimiter, quoteCharacter
        case customColumnDelimiter, customRowDelimiter, customQuoteCharacter
    }

    init() {}

    /// Settings saved by an older build have no `valueFormat`; decoding must
    /// not throw away the user's delimiters because of one new key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        copyHeader = try c.decodeIfPresent(Bool.self, forKey: .copyHeader) ?? false
        copyRowNumbers = try c.decodeIfPresent(Bool.self, forKey: .copyRowNumbers) ?? false
        quoteValues = try c.decodeIfPresent(Bool.self, forKey: .quoteValues) ?? true
        alwaysQuote = try c.decodeIfPresent(Bool.self, forKey: .alwaysQuote) ?? false
        copyAsHTML = try c.decodeIfPresent(Bool.self, forKey: .copyAsHTML) ?? false
        valueFormat = try c.decodeIfPresent(GridValueFormat.self, forKey: .valueFormat) ?? .display
        columnDelimiter = try c.decodeIfPresent(String.self, forKey: .columnDelimiter) ?? "\t"
        rowDelimiter = try c.decodeIfPresent(String.self, forKey: .rowDelimiter) ?? "\n"
        quoteCharacter = try c.decodeIfPresent(String.self, forKey: .quoteCharacter) ?? "\""
        customColumnDelimiter = try c.decodeIfPresent(String.self, forKey: .customColumnDelimiter) ?? ""
        customRowDelimiter = try c.decodeIfPresent(String.self, forKey: .customRowDelimiter) ?? ""
        customQuoteCharacter = try c.decodeIfPresent(String.self, forKey: .customQuoteCharacter) ?? ""
    }

    var columnDelimiterOptions: [String] {
        Self.options(standard: Self.standardColumnDelimiters,
                     custom: customColumnDelimiter,
                     current: columnDelimiter)
    }

    var rowDelimiterOptions: [String] {
        Self.options(standard: Self.standardRowDelimiters,
                     custom: customRowDelimiter,
                     current: rowDelimiter)
    }

    var quoteCharacterOptions: [String] {
        Self.options(standard: Self.standardQuoteCharacters,
                     custom: customQuoteCharacter,
                     current: quoteCharacter)
    }

    private static func options(standard: [String], custom: String, current: String) -> [String] {
        var list = standard
        if !custom.isEmpty, !list.contains(custom) { list.append(custom) }
        if !current.isEmpty, !list.contains(current) { list.append(current) }
        return list
    }

    /// Records a value chosen in a combo box: standard values are just selected,
    /// while a typed value also becomes the single remembered custom value.
    mutating func setColumnDelimiter(_ value: String) {
        columnDelimiter = value
        if !Self.standardColumnDelimiters.contains(value), !value.isEmpty {
            customColumnDelimiter = value
        }
    }

    mutating func setRowDelimiter(_ value: String) {
        rowDelimiter = value
        if !Self.standardRowDelimiters.contains(value), !value.isEmpty {
            customRowDelimiter = value
        }
    }

    mutating func setQuoteCharacter(_ value: String) {
        quoteCharacter = value
        if !Self.standardQuoteCharacters.contains(value), !value.isEmpty {
            customQuoteCharacter = value
        }
    }
}

/// Settings of the "Вставить…" dialog.
struct GridPasteSettings: Codable, Equatable {
    var insertMultipleRows = true
    var ignoreQuotes = false
    var insertNulls = true
    var nullMark = "NULL"
    var customNullMark = ""

    static let standardNullMarks = ["NULL", ""]

    var nullMarkOptions: [String] {
        var list = Self.standardNullMarks
        if !customNullMark.isEmpty, !list.contains(customNullMark) { list.append(customNullMark) }
        if !nullMark.isEmpty, !list.contains(nullMark) { list.append(nullMark) }
        return list
    }

    mutating func setNullMark(_ value: String) {
        nullMark = value
        if !Self.standardNullMarks.contains(value), !value.isEmpty {
            customNullMark = value
        }
    }
}

/// Persists both dialogs' settings between launches.
enum GridClipboardStore {
    private static let copyKey = "gridCopySettings"
    private static let pasteKey = "gridPasteSettings"

    static var copy: GridCopySettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: copyKey),
                  let settings = try? JSONDecoder().decode(GridCopySettings.self, from: data)
            else { return GridCopySettings() }
            return settings
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: copyKey)
        }
    }

    static var paste: GridPasteSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: pasteKey),
                  let settings = try? JSONDecoder().decode(GridPasteSettings.self, from: data)
            else { return GridPasteSettings() }
            return settings
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: pasteKey)
        }
    }
}

/// "Копировать как …" variants from the context menu.
enum GridClipboardFormat: String, CaseIterable {
    case csv, dbunit, html, json, markdown, sql, source, txt, xml

    var title: String {
        switch self {
        case .csv: return "Копировать как CSV"
        case .dbunit: return "Копировать как DbUnit"
        case .html: return "Копировать как HTML"
        case .json: return "Копировать как JSON"
        case .markdown: return "Копировать как Markdown"
        case .sql: return "Копировать как SQL"
        case .source: return "Копировать как исходный код"
        case .txt: return "Копировать как TXT"
        case .xml: return "Копировать как XML"
        }
    }
}

/// What is copied: the selected cells, with their column names.
struct GridClipboardPayload {
    var columns: [String]
    var rows: [[String?]]
    /// 1-based numbers of the copied rows, used by "copy row numbers".
    var rowNumbers: [Int]
    /// Metadata of the selected columns, used by the value display formats.
    var columnInfo: [ColumnInfo] = []

    var isEmpty: Bool { rows.isEmpty || columns.isEmpty }
}

enum GridClipboard {
    // MARK: - text copy

    static func text(_ payload: GridClipboardPayload, settings: GridCopySettings) -> String {
        guard !payload.isEmpty else { return "" }
        let payload = applying(settings.valueFormat, to: payload)
        return renderText(payload, settings: settings)
    }

    private static func renderText(_ payload: GridClipboardPayload,
                                   settings: GridCopySettings) -> String {
        guard !payload.isEmpty else { return "" }
        if settings.copyAsHTML {
            return htmlTable(payload, settings: settings, includeHeader: settings.copyHeader)
        }
        var lines: [String] = []
        if settings.copyHeader {
            var cells = payload.columns.map { quote($0, settings: settings) }
            if settings.copyRowNumbers { cells.insert("", at: 0) }
            lines.append(cells.joined(separator: settings.columnDelimiter))
        }
        for (index, row) in payload.rows.enumerated() {
            var cells = row.map { value -> String in
                guard let value else { return "" }
                return quote(value, settings: settings)
            }
            if settings.copyRowNumbers {
                let number = index < payload.rowNumbers.count ? payload.rowNumbers[index] : index + 1
                cells.insert(String(number), at: 0)
            }
            lines.append(cells.joined(separator: settings.columnDelimiter))
        }
        return lines.joined(separator: settings.rowDelimiter)
    }

    static func quote(_ value: String, settings: GridCopySettings) -> String {
        guard settings.quoteValues || settings.alwaysQuote else { return value }
        let q = settings.quoteCharacter
        let needsQuotes = settings.alwaysQuote
            || value.contains(settings.columnDelimiter)
            || value.contains(settings.rowDelimiter)
            || value.contains(q)
            || value.contains("\n") || value.contains("\r")
        guard needsQuotes else { return value }
        return q + value.replacingOccurrences(of: q, with: q + q) + q
    }

    // MARK: - "copy as" formats

    static func formatted(_ format: GridClipboardFormat,
                          payload: GridClipboardPayload,
                          tableName: String,
                          valueFormat: GridValueFormat = .display) -> String {
        let payload = applying(valueFormat, to: payload)
        switch format {
        case .csv:
            var settings = GridCopySettings()
            settings.copyHeader = true
            settings.columnDelimiter = ","
            settings.rowDelimiter = "\r\n"
            return renderText(payload, settings: settings) + "\r\n"
        case .txt:
            var settings = GridCopySettings()
            settings.quoteValues = false
            return renderText(payload, settings: settings)
        case .html:
            var settings = GridCopySettings()
            settings.copyHeader = true
            return htmlTable(payload, settings: settings, includeHeader: true)
        case .json:
            return json(payload)
        case .markdown:
            return markdown(payload)
        case .sql:
            return sql(payload, tableName: tableName)
        case .source:
            return source(payload)
        case .xml:
            return xml(payload)
        case .dbunit:
            return dbunit(payload, tableName: tableName)
        }
    }

    /// A complete HTML document for opening in a browser or Excel. The charset
    /// declaration is required for Cyrillic to survive a local file.
    static func htmlDocument(_ payload: GridClipboardPayload,
                             tableName: String,
                             valueFormat: GridValueFormat = .display) -> String {
        let payload = applying(valueFormat, to: payload)
        var settings = GridCopySettings()
        settings.copyHeader = true
        let title = escapeHTML(tableName)
        return "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n"
            + "<title>\(title)</title>\n"
            + "<style>body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:13px}"
            + "table{border-collapse:collapse}th,td{border:1px solid #ccc;padding:4px 8px;"
            + "text-align:left}th{background:#f2f2f2}</style>\n"
            + "</head>\n<body>\n"
            + htmlTable(payload, settings: settings, includeHeader: true)
            + "\n</body>\n</html>\n"
    }

    // MARK: - value display formats

    /// Rewrites every cell according to the chosen display format. Column
    /// metadata is needed to tell timestamps, booleans and binary values apart.
    private static func applying(_ format: GridValueFormat,
                                 to payload: GridClipboardPayload) -> GridClipboardPayload {
        guard format != .display, !payload.columnInfo.isEmpty else { return payload }
        var result = payload
        result.rows = payload.rows.enumerated().map { _, row in
            row.enumerated().map { index, value in
                guard index < payload.columnInfo.count else { return value }
                return formattedValue(value, column: payload.columnInfo[index], format: format)
            }
        }
        return result
    }

    private static func formattedValue(_ value: String?,
                                       column: ColumnInfo,
                                       format: GridValueFormat) -> String? {
        guard let value else { return nil }
        switch format {
        case .display:
            return value
        case .editable:
            return editableValue(value, column: column)
        case .databaseNative:
            return nativeValue(value, column: column)
        }
    }

    /// The grid already shows plain text; the only display-only decoration we
    /// add is the ISO "T" between date and time, which is awkward to edit.
    private static func editableValue(_ value: String, column: ColumnInfo) -> String {
        guard isTemporal(column), value.count > 10,
              let t = value.firstIndex(of: "T"),
              t > value.startIndex, t < value.index(before: value.endIndex) else { return value }
        var editable = value
        editable.replaceSubrange(t...t, with: " ")
        return editable
    }

    /// The raw driver representation. Booleans and binary values are the two
    /// cases where JDBC's text form differs from what the grid displays.
    private static func nativeValue(_ value: String, column: ColumnInfo) -> String {
        let type = column.type.uppercased()
        if isBoolean(column) {
            let lower = value.lowercased()
            let isTrue = lower == "true" || lower == "t" || lower == "1"
            let isFalse = lower == "false" || lower == "f" || lower == "0"
            guard isTrue || isFalse else { return value }
            if type == "BOOL" { return isTrue ? "t" : "f" }
            if type == "BIT" || type.hasPrefix("TINYINT") { return isTrue ? "1" : "0" }
            return value
        }
        if isBinary(column), let data = Data(base64Encoded: value) {
            let hex = data.map { String(format: "%02X", $0) }.joined()
            return (type.contains("BYTEA") ? "\\x" : "0x") + hex
        }
        return value
    }

    private static func isTemporal(_ column: ColumnInfo) -> Bool {
        let type = column.type.uppercased()
        return type.contains("DATE") || type.contains("TIME")
    }

    private static func isBoolean(_ column: ColumnInfo) -> Bool {
        let type = column.type.uppercased()
        return type == "BOOL" || type.contains("BOOLEAN")
            || type == "BIT" || type.hasPrefix("TINYINT")
            || column.className == "java.lang.Boolean"
    }

    private static func isBinary(_ column: ColumnInfo) -> Bool {
        let type = column.type.uppercased()
        return column.className == "[B" || type.contains("BLOB") || type.contains("BINARY")
            || type.contains("BYTEA") || type.contains("IMAGE") || type == "RAW"
    }

    private static func htmlTable(_ payload: GridClipboardPayload,
                                  settings: GridCopySettings,
                                  includeHeader: Bool) -> String {
        var out = "<table>\n"
        if includeHeader {
            out += "  <thead>\n    <tr>"
            for column in payload.columns {
                out += "<th>" + escapeHTML(column) + "</th>"
            }
            out += "</tr>\n  </thead>\n"
        }
        out += "  <tbody>\n"
        for row in payload.rows {
            out += "    <tr>"
            for value in row {
                out += "<td>" + escapeHTML(value ?? "") + "</td>"
            }
            out += "</tr>\n"
        }
        out += "  </tbody>\n</table>"
        return out
    }

    private static func json(_ payload: GridClipboardPayload) -> String {
        var lines: [String] = ["["]
        for (index, row) in payload.rows.enumerated() {
            var fields: [String] = []
            for (c, column) in payload.columns.enumerated() {
                let value = c < row.count ? row[c] : nil
                let encoded = value.map { escapeJSON($0) } ?? "null"
                fields.append("    " + escapeJSON(column) + ": " + encoded)
            }
            lines.append("  {")
            lines.append(fields.joined(separator: ",\n"))
            lines.append(index == payload.rows.count - 1 ? "  }" : "  },")
        }
        lines.append("]")
        return lines.joined(separator: "\n")
    }

    private static func markdown(_ payload: GridClipboardPayload) -> String {
        var lines: [String] = []
        lines.append("| " + payload.columns.map(escapeMarkdown).joined(separator: " | ") + " |")
        lines.append("| " + payload.columns.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in payload.rows {
            let cells = row.map { escapeMarkdown($0 ?? "") }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static func sql(_ payload: GridClipboardPayload, tableName: String) -> String {
        let table = sqlIdentifier(tableName)
        let columns = payload.columns.map(sqlIdentifier).joined(separator: ", ")
        var lines: [String] = []
        for row in payload.rows {
            let values = row.map { value -> String in
                guard let value else { return "NULL" }
                return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
            }
            lines.append("INSERT INTO \(table) (\(columns)) VALUES (\(values.joined(separator: ", ")));")
        }
        return lines.joined(separator: "\n")
    }

    private static func source(_ payload: GridClipboardPayload) -> String {
        var lines: [String] = ["String[][] data = {"]
        for row in payload.rows {
            let cells = row.map { value -> String in
                guard let value else { return "null" }
                return "\"" + escapeCode(value) + "\""
            }
            lines.append("    { " + cells.joined(separator: ", ") + " },")
        }
        lines.append("};")
        return lines.joined(separator: "\n")
    }

    private static func xml(_ payload: GridClipboardPayload) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<result>\n"
        for row in payload.rows {
            out += "  <row>\n"
            for (c, column) in payload.columns.enumerated() {
                let value = c < row.count ? row[c] : nil
                let tag = xmlTag(column)
                if let value {
                    out += "    <\(tag)>" + escapeXML(value) + "</\(tag)>\n"
                } else {
                    out += "    <\(tag) null=\"true\" />\n"
                }
            }
            out += "  </row>\n"
        }
        out += "</result>"
        return out
    }

    private static func dbunit(_ payload: GridClipboardPayload, tableName: String) -> String {
        let table = xmlTag(tableName)
        var out = "<?xml version='1.0' encoding='UTF-8'?>\n<dataset>\n"
        for row in payload.rows {
            var attributes: [String] = []
            for (c, column) in payload.columns.enumerated() {
                let value = c < row.count ? row[c] : nil
                let name = xmlAttributeName(column)
                attributes.append(name + "=\"" + escapeXML(value ?? "") + "\"")
            }
            out += "  <\(table) " + attributes.joined(separator: " ") + " />\n"
        }
        out += "</dataset>"
        return out
    }

    // MARK: - paste

    /// Splits pasted text into cells. Quoted values keep their delimiters;
    /// with "ignore quotes" the quote character is just an ordinary character.
    static func parse(_ text: String, settings: GridPasteSettings,
                      copy: GridCopySettings) -> [[String?]] {
        guard !text.isEmpty else { return [] }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rowSeparator: Character = copy.rowDelimiter.count == 1
            ? copy.rowDelimiter.first!
            : "\n"
        let columnSeparator: Character = copy.columnDelimiter.count == 1
            ? copy.columnDelimiter.first!
            : "\t"
        let quote: Character? = copy.quoteCharacter.count == 1 && !settings.ignoreQuotes
            ? copy.quoteCharacter.first
            : nil

        var rows: [[String?]] = []
        var current: [String] = []
        var field = ""
        var inQuotes = false
        let characters = Array(normalized)
        var index = 0

        func finishField() {
            let value = field
            if settings.insertNulls, value == settings.nullMark {
                current.append("__DBOOYVOL_NULL__")
            } else {
                current.append(value)
            }
            field = ""
        }

        func finishRow() {
            finishField()
            rows.append(current.map { $0 == "__DBOOYVOL_NULL__" ? nil : $0 })
            current = []
        }

        while index < characters.count {
            let c = characters[index]
            if let quote, c == quote {
                if inQuotes {
                    if index + 1 < characters.count, characters[index + 1] == quote {
                        field.append(quote)
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                if field.isEmpty {
                    inQuotes = true
                    index += 1
                    continue
                }
            }
            if !inQuotes, c == columnSeparator {
                finishField()
                index += 1
                continue
            }
            if !inQuotes, c == rowSeparator {
                finishRow()
                index += 1
                continue
            }
            field.append(c)
            index += 1
        }
        // A trailing row separator does not create an extra empty row.
        if !field.isEmpty || !current.isEmpty {
            finishRow()
        }
        return rows
    }

    // MARK: - display helpers for the delimiter fields

    static func display(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    static func value(fromDisplay text: String) -> String {
        var out = ""
        var iterator = Array(text).makeIterator()
        while let c = iterator.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let next = iterator.next() else { out.append("\\"); break }
            switch next {
            case "t": out.append("\t")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "\\": out.append("\\")
            default: out.append(next)
            }
        }
        return out
    }

    // MARK: - escaping

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeJSON(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func escapeMarkdown(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func escapeCode(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    static func escapeXML(_ s: String) -> String {
        Exporter.escapeXML(s)
    }

    private static func sqlIdentifier(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "table" }
        return trimmed
    }

    /// XML element name from a column name: invalid characters become "_".
    private static func xmlTag(_ name: String) -> String {
        var out = ""
        for (index, c) in name.enumerated() {
            let allowed = c.isLetter || c == "_" || (index > 0 && (c.isNumber || c == "-" || c == "."))
            out.append(allowed ? c : "_")
        }
        if out.isEmpty { return "column" }
        if let first = out.first, first.isNumber { out = "_" + out }
        return out
    }

    private static func xmlAttributeName(_ name: String) -> String {
        let tag = xmlTag(name)
        return tag
    }
}
