import Foundation
import Compression

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

    // MARK: - XLSX

    /// Builds a minimal Office Open XML workbook. Every cell is written as an
    /// inline string, so values keep their exact text form: a serial number
    /// with leading zeros or a 20-digit id does not turn into a number.
    static func xlsx(columns: [ColumnInfo], rows: [[String?]]) -> Data {
        var sheetName = L10n.tr("Результат")
        sheetName.removeAll { "[]:*?/\\".contains($0) }
        if sheetName.isEmpty { sheetName = "Sheet1" }
        sheetName = String(sheetName.prefix(31))
        sheetName = sheetName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let sheet = sheetXML(columns: columns, rows: rows)

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
        """

        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """

        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="\(sheetName)" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """

        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """

        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="2">
            <font><sz val="11"/><name val="Calibri"/></font>
            <font><b/><sz val="11"/><name val="Calibri"/></font>
          </fonts>
          <fills count="2">
            <fill><patternFill patternType="none"/></fill>
            <fill><patternFill patternType="gray125"/></fill>
          </fills>
          <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
          <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
          <cellXfs count="2">
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
            <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
          </cellXfs>
          <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>
        """

        return ZipArchive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ]).makeData()
    }

    private static func sheetXML(columns: [ColumnInfo], rows: [[String?]]) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        out.reserveCapacity(rows.count * max(columns.count, 1) * 48)
        out += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\n"
        out += "<sheetViews><sheetView workbookViewId=\"0\">"
        out += "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"
        out += "</sheetView></sheetViews>\n"

        // A modest width per column keeps the sheet readable without measuring
        // every value twice: the header and the first 200 rows are enough.
        var widths = columns.map { max(8, min(60, $0.name.count + 2)) }
        for row in rows.prefix(200) {
            for (i, value) in row.enumerated() where i < widths.count {
                guard let value else { continue }
                widths[i] = max(widths[i], min(60, value.count + 2))
            }
        }
        if !widths.isEmpty {
            out += "<cols>\n"
            for (i, width) in widths.enumerated() {
                out += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(width)\" customWidth=\"1\"/>\n"
            }
            out += "</cols>\n"
        }

        out += "<sheetData>\n"
        if !columns.isEmpty {
            out += "<row r=\"1\">"
            for (i, column) in columns.enumerated() {
                out += cellXML(ref: "\(columnName(i))1", value: column.name, style: 1)
            }
            out += "</row>\n"
        }
        for (r, row) in rows.enumerated() {
            out += "<row r=\"\(r + 2)\">"
            for (i, _) in columns.enumerated() {
                let value = i < row.count ? row[i] : nil
                out += cellXML(ref: "\(columnName(i))\(r + 2)", value: value, style: nil)
            }
            out += "</row>\n"
        }
        out += "</sheetData>\n</worksheet>\n"
        return out
    }

    /// Excel limits a cell to 32767 characters and rejects most control
    /// characters, so both are handled before escaping.
    private static func cellXML(ref: String, value: String?, style: Int?) -> String {
        guard let value else { return "<c r=\"\(ref)\"/>" }
        var text = String(value.prefix(32767))
        text.removeAll { ch in
            guard let scalar = ch.unicodeScalars.first else { return false }
            let v = scalar.value
            return (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D)
        }
        let styleAttr = style.map { " s=\"\($0)\"" } ?? ""
        return "<c r=\"\(ref)\"\(styleAttr) t=\"inlineStr\"><is><t xml:space=\"preserve\">"
            + escapeXML(text) + "</t></is></c>"
    }

    private static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let rem = (n - 1) % 26
            name = String(UnicodeScalar(65 + rem)!) + name
            n = (n - 1) / 26
        }
        return name
    }
}

/// A small ZIP writer for the XLSX package. Entries are deflated when that
/// makes them smaller and stored otherwise; the format is the plain one every
/// spreadsheet application accepts.
private struct ZipArchive {
    let entries: [(name: String, data: Data)]

    func makeData() -> Data {
        var out = Data()
        var central = Data()
        let (time, date) = Self.dosDateTime(Date())

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let deflated = Self.deflate(entry.data)
            let method: UInt16 = deflated == nil ? 0 : 8
            let payload = deflated ?? entry.data
            let offset = UInt32(out.count)

            out.appendLE(UInt32(0x04034b50))
            out.appendLE(UInt16(20))
            out.appendLE(UInt16(0x0800))
            out.appendLE(method)
            out.appendLE(time)
            out.appendLE(date)
            out.appendLE(crc)
            out.appendLE(UInt32(payload.count))
            out.appendLE(UInt32(entry.data.count))
            out.appendLE(UInt16(nameData.count))
            out.appendLE(UInt16(0))
            out.append(nameData)
            out.append(payload)

            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800))
            central.appendLE(method)
            central.appendLE(time)
            central.appendLE(date)
            central.appendLE(crc)
            central.appendLE(UInt32(payload.count))
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt16(nameData.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            central.appendLE(offset)
            central.append(nameData)
        }

        let centralOffset = UInt32(out.count)
        out.append(central)
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(central.count))
        out.appendLE(centralOffset)
        out.appendLE(UInt16(0))
        return out
    }

    /// Raw DEFLATE, the payload ZIP method 8 expects.
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let capacity = data.count + data.count / 2 + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < data.count else { return nil }
        output.removeSubrange(written..<output.count)
        return output
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let parts = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone.current, from: date)
        let year = max(1980, parts.year ?? 1980)
        let time = UInt16((parts.hour ?? 0) << 11
                          | (parts.minute ?? 0) << 5
                          | ((parts.second ?? 0) / 2))
        let day = UInt16((year - 1980) << 9
                         | (parts.month ?? 1) << 5
                         | (parts.day ?? 1))
        return (time, day)
    }
}

private enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
        }
        return c ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
