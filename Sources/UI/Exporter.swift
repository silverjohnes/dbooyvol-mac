import Foundation

enum Exporter {
    // MARK: - CSV (RFC 4180)

    static func csv(columns: [ColumnInfo], rows: [[String?]], delimiter: String = ",", nullValue: String = "") -> String {
        var out = ""
        out += columns.map { escapeCSV($0.name, delimiter: delimiter) }.joined(separator: delimiter)
        out += "\r\n"
        for row in rows {
            let cells = row.map { value -> String in
                guard let v = value else { return nullValue }
                return escapeCSV(v, delimiter: delimiter)
            }
            out += cells.joined(separator: delimiter)
            out += "\r\n"
        }
        return out
    }

    private static func escapeCSV(_ s: String, delimiter: String) -> String {
        let needsQuotes = s.contains(delimiter) || s.contains("\"") || s.contains("\n") || s.contains("\r")
        if !needsQuotes { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - XML

    static func xml(columns: [ColumnInfo], rows: [[String?]]) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<result rows=\"\(rows.count)\">\n"
        out += "  <columns>\n"
        for c in columns {
            out += "    <column name=\"\(escapeXML(c.name))\" type=\"\(escapeXML(c.type))\" />\n"
        }
        out += "  </columns>\n"
        out += "  <rows>\n"
        for row in rows {
            out += "    <row>\n"
            for (i, c) in columns.enumerated() {
                let value = i < row.count ? row[i] : nil
                if let v = value {
                    out += "      <col name=\"\(escapeXML(c.name))\" type=\"\(escapeXML(c.type))\">\(escapeXML(v))</col>\n"
                } else {
                    out += "      <col name=\"\(escapeXML(c.name))\" type=\"\(escapeXML(c.type))\" null=\"true\" />\n"
                }
            }
            out += "    </row>\n"
        }
        out += "  </rows>\n"
        out += "</result>\n"
        return out
    }

    static func escapeXML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                let scalar = ch.unicodeScalars.first!.value
                if scalar < 0x20 && scalar != 0x09 && scalar != 0x0A && scalar != 0x0D {
                    out += String(format: "&#x%X;", scalar)
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }
}
