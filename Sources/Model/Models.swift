import Foundation

enum DBKind: String, Codable, CaseIterable, Identifiable {
    case postgres
    case oracle
    case clickhouse
    case sqlite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .postgres: return "PostgreSQL"
        case .oracle: return "Oracle"
        case .clickhouse: return "ClickHouse"
        case .sqlite: return "SQLite"
        }
    }

    var defaultPort: Int {
        switch self {
        case .postgres: return 5432
        case .oracle: return 1521
        case .clickhouse: return 8123
        case .sqlite: return 0
        }
    }

    var defaultDriverHint: String {
        switch self {
        case .postgres: return L10n.tr("встроен postgresql 42.7 — путь можно не указывать")
        case .oracle: return L10n.tr("укажите ojdbc8.jar / ojdbc11.jar (thin-драйвер, dylib не нужны)")
        case .clickhouse: return L10n.tr("встроен clickhouse-jdbc — путь можно не указывать")
        case .sqlite: return L10n.tr("встроен sqlite-jdbc — путь можно не указывать")
        }
    }

    /// SQLite is a file, not a server: no host, port, user or password.
    var isFileBased: Bool { self == .sqlite }
}

/// How the Oracle JDBC thin driver finds the database.
enum OracleNetMode: String, Codable, CaseIterable, Identifiable {
    /// host:port/service or host:port:SID
    case easy
    /// alias from tnsnames.ora, found through TNS_ADMIN
    case tns
    /// alias resolved through Oracle Internet Directory / LDAP
    case ldap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .easy: return L10n.tr("EZ Connect (хост и сервис)")
        case .tns: return L10n.tr("TNS-алиас (tnsnames.ora)")
        case .ldap: return L10n.tr("LDAP / OID (ldap.ora)")
        }
    }
}

struct SSHProfile: Codable, Hashable {
    var enabled: Bool = false
    var host: String = ""
    var port: Int = 22
    var user: String = ""
    var keyPath: String = ""
}

struct ConnectionProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var kind: DBKind = .postgres
    var host: String = "localhost"
    var port: Int = 5432
    var database: String = ""
    var user: String = ""
    var driverPath: String = ""
    var jdbcUrl: String = ""
    var oracleSid: Bool = false
    var ssh: SSHProfile = SSHProfile()
    var readOnly: Bool = true

    // Oracle network settings (thin driver: no native libraries needed).
    var oracleMode: OracleNetMode = .easy
    var oracleAlias: String = ""
    var tnsAdmin: String = ""
    var ldapHost: String = ""
    var ldapPort: Int = 389
    var ldapContext: String = ""
    var ldapSSL: Bool = false
    /// e.g. "RADIUS"; empty = password authentication only.
    var oracleAuthServices: String = ""
    /// Convenience: a folder with ojdbc*.jar and network/admin.
    var instantClientDir: String = ""

    var displayName: String {
        if !name.isEmpty { return name }
        if kind == .sqlite {
            return database.isEmpty ? kind.title : "\(kind.title) \((database as NSString).lastPathComponent)"
        }
        if kind == .oracle, oracleMode != .easy, !oracleAlias.isEmpty {
            return "\(kind.title) \(oracleAlias)"
        }
        return host.isEmpty ? kind.title : "\(kind.title) \(host)"
    }

    /// JDBC URL shown in tooltips, mirroring what `Session` passes to the
    /// sidecar. Oracle network modes are abbreviated to their alias.
    var displayURL: String {
        if !jdbcUrl.isEmpty { return jdbcUrl }
        switch kind {
        case .postgres:
            return "jdbc:postgresql://\(host):\(port)/\(database)"
        case .clickhouse:
            return "jdbc:clickhouse://\(host):\(port)/\(database)"
        case .sqlite:
            return "jdbc:sqlite:\(database)"
        case .oracle:
            if oracleMode != .easy, !oracleAlias.isEmpty {
                return "jdbc:oracle:thin:@\(oracleAlias)"
            }
            let service = database.isEmpty ? "ORCL" : database
            return "jdbc:oracle:thin:@\(host):\(port):\(service)"
        }
    }

    /// Used when the user leaves the name empty.
    var suggestedName: String {
        if kind == .sqlite {
            return database.isEmpty ? kind.title : "\(kind.title) \((database as NSString).lastPathComponent)"
        }
        if kind == .oracle, oracleMode != .easy, !oracleAlias.isEmpty {
            return "\(kind.title) \(oracleAlias)"
        }
        return "\(kind.title) \(host)"
    }
}

extension ConnectionProfile {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, host, port, database, user, driverPath, jdbcUrl
        case oracleSid, ssh, readOnly
        case oracleMode, oracleAlias, tnsAdmin, ldapHost, ldapPort, ldapContext
        case ldapSSL, oracleAuthServices, instantClientDir
    }

    /// Old profiles.json has no Oracle-network keys: every missing value falls back
    /// to its default instead of making the whole file unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(DBKind.self, forKey: .kind) ?? .postgres
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 5432
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        driverPath = try c.decodeIfPresent(String.self, forKey: .driverPath) ?? ""
        jdbcUrl = try c.decodeIfPresent(String.self, forKey: .jdbcUrl) ?? ""
        oracleSid = try c.decodeIfPresent(Bool.self, forKey: .oracleSid) ?? false
        ssh = try c.decodeIfPresent(SSHProfile.self, forKey: .ssh) ?? SSHProfile()
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? true
        oracleMode = try c.decodeIfPresent(OracleNetMode.self, forKey: .oracleMode) ?? .easy
        oracleAlias = try c.decodeIfPresent(String.self, forKey: .oracleAlias) ?? ""
        tnsAdmin = try c.decodeIfPresent(String.self, forKey: .tnsAdmin) ?? ""
        ldapHost = try c.decodeIfPresent(String.self, forKey: .ldapHost) ?? ""
        ldapPort = try c.decodeIfPresent(Int.self, forKey: .ldapPort) ?? 389
        ldapContext = try c.decodeIfPresent(String.self, forKey: .ldapContext) ?? ""
        ldapSSL = try c.decodeIfPresent(Bool.self, forKey: .ldapSSL) ?? false
        oracleAuthServices = try c.decodeIfPresent(String.self, forKey: .oracleAuthServices) ?? ""
        instantClientDir = try c.decodeIfPresent(String.self, forKey: .instantClientDir) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(database, forKey: .database)
        try c.encode(user, forKey: .user)
        try c.encode(driverPath, forKey: .driverPath)
        try c.encode(jdbcUrl, forKey: .jdbcUrl)
        try c.encode(oracleSid, forKey: .oracleSid)
        try c.encode(ssh, forKey: .ssh)
        try c.encode(readOnly, forKey: .readOnly)
        try c.encode(oracleMode, forKey: .oracleMode)
        try c.encode(oracleAlias, forKey: .oracleAlias)
        try c.encode(tnsAdmin, forKey: .tnsAdmin)
        try c.encode(ldapHost, forKey: .ldapHost)
        try c.encode(ldapPort, forKey: .ldapPort)
        try c.encode(ldapContext, forKey: .ldapContext)
        try c.encode(ldapSSL, forKey: .ldapSSL)
        try c.encode(oracleAuthServices, forKey: .oracleAuthServices)
        try c.encode(instantClientDir, forKey: .instantClientDir)
    }
}

struct ColumnInfo: Identifiable, Hashable {
    let index: Int
    let name: String
    let type: String
    let className: String
    /// Source table of the column, when the driver reports it. Used to write
    /// edited cells back with an UPDATE.
    var table: String = ""
    var schema: String = ""
    var catalog: String = ""
    var id: Int { index }

    var shortType: String {
        let t = type.uppercased()
        if t.hasPrefix("TIMESTAMP") { return "timestamp" }
        if t == "DATE" { return "date" }
        if t.hasPrefix("NUMERIC") || t == "NUMBER" || t == "DECIMAL" { return "numeric" }
        if t == "INT4" || t == "INTEGER" || t == "INT8" || t == "BIGINT" { return "int" }
        if t.contains("CHAR") || t == "TEXT" || t == "VARCHAR2" { return "text" }
        if t == "BOOL" || t == "BOOLEAN" { return "bool" }
        return type.lowercased()
    }

    /// Numeric columns are right-aligned and sorted by value instead of text.
    var isNumeric: Bool {
        let t = (className + " " + type).lowercased()
        return t.contains("int") || t.contains("numeric") || t.contains("number")
            || t.contains("decimal") || t.contains("float") || t.contains("double") || t.contains("money")
    }
}

struct DBError: Identifiable, Hashable, Error, LocalizedError {
    let id = UUID()
    var message: String
    var sqlState: String?
    var code: Int?

    var errorDescription: String? { message }

    var summary: String {
        var parts: [String] = []
        if let s = sqlState, !s.isEmpty { parts.append("SQLState \(s)") }
        if let c = code, c != 0 { parts.append("code \(c)") }
        return parts.isEmpty ? message : "\(message)\n(\(parts.joined(separator: ", ")))"
    }
}

/// One cell changed in the result grid. The row is identified by a stable UUID
/// because sorting reorders the visible rows.
struct ResultCellKey: Hashable {
    let rowID: UUID
    let column: Int
}

struct ResultCellEdit {
    let rowID: UUID
    let column: Int
    let original: String?
    var new: String?
}

struct QueryResult {
    var sql: String = ""
    /// Name of the script that produced this result; column widths are stored by it.
    var queryName: String = ""
    /// Identifies one execution; used to invalidate the grid filter cache.
    var runID: UUID = UUID()
    /// Connection that produced the result, so edits can be written back.
    var profileID: UUID? = nil
    var columns: [ColumnInfo] = []
    /// Visual order of the columns as data indices. Empty means the natural
    /// order. The user's drag order survives sorting and lives until the
    /// script is executed again.
    var columnOrder: [Int] = []
    var rows: [[String?]] = []
    /// Stable identity per row, kept in sync with `rows` when sorting/paging.
    var rowIDs: [UUID] = []
    /// Rows that were pasted below the existing data and are not in the DB yet.
    var insertedRowIDs: Set<UUID> = []
    /// Original values of edited rows, used by WHERE primary_key = ... and Cancel.
    var originalRows: [UUID: [String?]] = [:]
    /// Unsaved cell edits, keyed by row identity and column index.
    var editedCells: [ResultCellKey: ResultCellEdit] = [:]
    var truncated: Bool = false
    var done: Bool = true
    /// Total rows in the response, counted in the background after the first
    /// page is shown. Nil while unknown or when the whole result already fits.
    var totalRows: Int?
    var durationMs: Int = 0
    var updateCount: Int? = nil
    var queryId: String? = nil
    var error: DBError? = nil

    var isEmpty: Bool { columns.isEmpty && rows.isEmpty && updateCount == nil }

    /// Data indices in visual order. Falls back to the natural order when the
    /// user has not dragged anything or the stored order no longer matches.
    var visualColumnOrder: [Int] {
        guard columnOrder.count == columns.count,
              Set(columnOrder) == Set(columns.indices) else {
            return Array(columns.indices)
        }
        return columnOrder
    }
}

/// Selection in the result grid. A cell range is a rectangle, while row and
/// column selections may be non-contiguous (Shift extends, Ctrl/Cmd toggles).
struct GridSelection: Equatable {
    enum Kind: Equatable {
        case cells
        case rows
        case columns
    }

    var kind: Kind = .cells
    var rows: Set<Int> = []
    var cols: Set<Int> = []

    var rowCount: Int { rows.count }
    var colCount: Int { cols.count }

    func contains(row: Int, col: Int) -> Bool {
        switch kind {
        case .rows: return rows.contains(row)
        case .columns: return cols.contains(col)
        case .cells: return rows.contains(row) && cols.contains(col)
        }
    }

    /// Rows that take part in copy/export for the given result size.
    func effectiveRows(total: Int) -> [Int] {
        switch kind {
        case .rows, .cells: return rows.sorted()
        case .columns: return total > 0 ? Array(0..<total) : []
        }
    }

    /// Columns that take part in copy/export for the given result size.
    func effectiveColumns(total: Int) -> [Int] {
        switch kind {
        case .columns, .cells: return cols.sorted()
        case .rows: return total > 0 ? Array(0..<total) : []
        }
    }
}

/// Local sort applied to the rows already fetched for the grid.
struct ResultSort: Equatable {
    var column: Int
    /// false = descending (first click), true = ascending.
    var ascending: Bool
}

struct QueryTab: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String = "Запрос"
    var text: String = ""
    var filePath: String? = nil
    var customTitle: Bool = false
    var isDirty: Bool = false
    var selectionLocation: Int = 0
    var selectionLength: Int = 0
    /// Connection this script is bound to. nil = follow the currently selected connection.
    var profileID: UUID? = nil

    var fileName: String? {
        filePath.map { ($0 as NSString).lastPathComponent }
    }
}

struct HistoryEntry: Codable, Identifiable {    var id: UUID = UUID()
    var date: Date = Date()
    var profile: String = ""
    var sql: String = ""
    var durationMs: Int = 0
    var rowCount: Int = 0
    var error: String? = nil
    var columns: [String] = []
    var rows: [[String?]] = []
}

struct TreeNode: Identifiable, Hashable {
    let id: String
    let label: String
    let kind: String
    let hasChildren: Bool
    let detail: String?
    let primary: Bool

    init(id: String, label: String, kind: String, hasChildren: Bool, detail: String? = nil, primary: Bool = false) {
        self.id = id
        self.label = label
        self.kind = kind
        self.hasChildren = hasChildren
        self.detail = detail
        self.primary = primary
    }
}

// MARK: - Value panel

/// How the value panel renders a cell. `.auto` picks by content.
enum ValueViewKind: String, CaseIterable, Identifiable {
    case auto
    case binary
    case json
    case text
    case xml

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return L10n.tr("Авто")
        case .binary: return L10n.tr("Двоичные данные")
        case .json: return "JSON"
        case .text: return L10n.tr("Текст")
        case .xml: return "XML"
        }
    }

    /// The concrete type shown in the menu when `.auto` is active.
    static func detect(_ value: String?) -> ValueViewKind {
        guard let value, !value.isEmpty else { return .text }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return .json
            }
        }
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">") {
            return .xml
        }
        // Control characters (except tab/newline) mean binary data. The
        // sidecar sends binary values as Base64, so also accept long Base64.
        let control = value.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (v < 32 && v != 9 && v != 10 && v != 13) || v == 0
        }
        if control { return .binary }
        if trimmed.count >= 16, trimmed.count % 4 == 0,
           trimmed.range(of: "^[A-Za-z0-9+/]+={0,2}$", options: .regularExpression) != nil,
           let data = Data(base64Encoded: trimmed),
           data.contains(where: { $0 == 0 || ($0 < 9) || ($0 > 13 && $0 < 32) }) {
            return .binary
        }
        return .text
    }
}

/// One cell shown in the value panel. `row` and `column` are data indices.
struct ValuePanelItem: Equatable {
    var row: Int
    var column: Int
    var columnName: String
    var columnType: String
    var value: String?
    /// Visible row number (1-based), for the panel header.
    var rowNumber: Int
}

// MARK: - Table metadata for tooltips

struct TableMetaColumn: Equatable {
    var name: String
    var type: String
    var size: Int?
    var nullable: Bool
    var primary: Bool

    /// `VARCHAR2(200)` style, matching DBeaver.
    var displayType: String {
        guard let size, size > 0 else { return type }
        let t = type.uppercased()
        if t.contains("CHAR") || t == "VARCHAR" || t == "VARCHAR2" || t == "NVARCHAR2"
            || t == "DECIMAL" || t == "NUMERIC" || t == "NUMBER" {
            return "\(type)(\(size))"
        }
        return type
    }
}

struct TableMeta: Equatable {
    var columns: [TableMetaColumn]
    var primaryKey: [String]
    var primaryKeyName: String?

    func column(_ name: String) -> TableMetaColumn? {
        columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
