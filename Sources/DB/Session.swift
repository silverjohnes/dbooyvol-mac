import Foundation

@MainActor
final class Session {
    let profile: ConnectionProfile
    private(set) var connId: String?
    private(set) var serverInfo: String = ""
    private(set) var isConnected = false
    private var tunnel: SSHTunnel?
    private var passwordOverride: String?
    /// Asked only for profiles that do not store a password. The app shows the
    /// prompt and caches the answer for the current run.
    private let passwordProvider: (() -> String?)?

    /// `password` is used by "Test connection" so the draft password can be checked
    /// before it is saved; normal sessions read the stored secret.
    init(profile: ConnectionProfile, password: String? = nil,
         passwordProvider: (() -> String?)? = nil) {
        self.profile = profile
        self.passwordOverride = password
        self.passwordProvider = passwordProvider
    }

    /// Coalesces concurrent connection attempts: two tabs may start their
    /// first query at the same time, and only one JDBC connection is created.
    private var connectingTask: Task<Void, Error>?

    func connect() async throws {
        if isConnected, connId != nil { return }
        if let connectingTask {
            try await connectingTask.value
            return
        }
        let task = Task { try await self.connectNow() }
        connectingTask = task
        do {
            try await task.value
            connectingTask = nil
        } catch {
            connectingTask = nil
            throw error
        }
    }

    private func connectNow() async throws {
        if isConnected, connId != nil { return }

        // One system prompt (Touch ID, or the login password on Macs without
        // biometrics) unlocks all stored passwords for this app run.
        if profile.storesPassword && !profile.kind.isFileBased && passwordOverride == nil {
            try await SecretStore.authenticate(
                reason: L10n.fmt("Открыть сохранённый пароль для «%@»", profile.displayName))
        }

        let password = try resolvePassword()

        var host = profile.host
        var port = profile.port
        // TNS/LDAP aliases expand to a real host, so a localhost tunnel would not be used.
        // SQLite is a local file: there is nothing to tunnel to.
        let aliasMode = (profile.kind == .oracle && profile.oracleMode != .easy)
            || profile.kind.isFileBased
        if profile.ssh.enabled && !aliasMode {
            let started = try await startTunnel(profile.ssh, host: host, port: port)
            tunnel = started.0
            host = "127.0.0.1"
            port = started.1
        }

        var params: [String: Any] = [
            "kind": profile.kind.rawValue,
            "host": host,
            "port": port,
            "database": profile.database,
            "user": profile.user,
            "password": password,
            "driverPath": profile.driverPath,
            "oracleSid": profile.oracleSid
        ]
        if profile.kind == .oracle {
            params["oracleMode"] = profile.oracleMode.rawValue
            params["oracleAlias"] = profile.oracleAlias
            params["tnsAdmin"] = profile.tnsAdmin
            params["ldapHost"] = profile.ldapHost
            params["ldapPort"] = profile.ldapPort
            params["ldapContext"] = profile.ldapContext
            params["ldapSsl"] = profile.ldapSSL
            params["oracleAuthServices"] = profile.oracleAuthServices
        }
        if params["driverPath"] as? String == "" { params.removeValue(forKey: "driverPath") }
        if !profile.jdbcUrl.isEmpty { params["url"] = profile.jdbcUrl }

        do {
            let res = try await SidecarClient.shared.call("connect", params)
            connId = res["connId"] as? String
            serverInfo = (res["serverVersion"] as? String) ?? ""
            isConnected = connId != nil
        } catch {
            tunnel?.stop()
            tunnel = nil
            throw error
        }
    }

    /// The plaintext password is used once for the JDBC connect and then
    /// dropped; only the encrypted map stays in memory.
    private func resolvePassword() throws -> String {
        defer { passwordOverride = nil }
        if profile.kind.isFileBased { return "" }
        if let passwordOverride { return passwordOverride }
        if profile.storesPassword {
            do {
                let stored = try SecretStore.load(profile.id.uuidString)
                if !stored.isEmpty { return stored }
            } catch SecretStoreError.wrongKey {
                // The master key changed. Fall through: the provider offers one
                // dialog to re-enter every affected password, instead of a
                // separate error for each connection.
            } catch SecretStoreError.keyMissing {
                // Same recovery path: no key, but ciphertext still exists.
            }
        }
        // Nothing stored: ask. This also covers a profile whose password was
        // deliberately not saved.
        guard let provided = passwordProvider?() else {
            throw SidecarError(message: L10n.tr("Пароль не введён"))
        }
        return provided
    }

    private func startTunnel(_ ssh: SSHProfile, host: String, port: Int) async throws -> (SSHTunnel, Int) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let t = SSHTunnel()
                    let localPort = try t.start(ssh: ssh, remoteHost: host, remotePort: port)
                    continuation.resume(returning: (t, localPort))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func tree(path: [String]) async throws -> [TreeNode] {
        do {
            return try await treeOnce(path: path)
        } catch {
            guard (error as? SidecarError)?.isConnectionLost == true else { throw error }
            resetConnection()
            return try await treeOnce(path: path)
        }
    }

    private func treeOnce(path: [String]) async throws -> [TreeNode] {
        try await connect()
        guard let connId else { throw SidecarError(message: "Нет соединения") }
        let res = try await SidecarClient.shared.call("tree", [
            "connId": connId,
            "path": path,
            "kind": profile.kind.rawValue
        ])
        let raw = res["nodes"] as? [[String: Any]] ?? []
        return raw.map {
            TreeNode(
                id: $0["id"] as? String ?? UUID().uuidString,
                label: $0["label"] as? String ?? "?",
                kind: $0["kind"] as? String ?? "node",
                hasChildren: $0["hasChildren"] as? Bool ?? false,
                detail: $0["detail"] as? String,
                primary: $0["primary"] as? Bool ?? false
            )
        }
    }

    func execute(_ sql: String, pageSize: Int = 200,
                 params: [String: Any] = [:]) async throws -> QueryResult {
        do {
            return try await executeOnce(sql, pageSize: pageSize, params: params)
        } catch {
            // The server may have dropped an idle session (or the sidecar restarted).
            // Reconnect once and retry the same statement.
            guard (error as? SidecarError)?.isConnectionLost == true else { throw error }
            resetConnection()
            return try await executeOnce(sql, pageSize: pageSize, params: params)
        }
    }

    private func executeOnce(_ sql: String, pageSize: Int,
                             params: [String: Any]) async throws -> QueryResult {
        try await connect()
        guard let connId else { throw SidecarError(message: "Нет соединения") }
        let started = Date()
        let res = try await SidecarClient.shared.call("query", [
            "connId": connId,
            "sql": sql,
            "kind": profile.kind.rawValue,
            "count": pageSize,
            "params": params
        ])

        var result = QueryResult()
        result.sql = sql
        result.columns = Self.columns(from: res)
        result.rows = Self.rows(from: res["rows"])
        result.truncated = res["truncated"] as? Bool ?? false
        result.done = res["done"] as? Bool ?? true
        result.queryId = res["queryId"] as? String
        result.durationMs = (res["durationMs"] as? NSNumber)?.intValue ?? Int(Date().timeIntervalSince(started) * 1000)
        result.updateCount = (res["updateCount"] as? NSNumber)?.intValue
        return result
    }

    /// Drops a dead connection without asking the sidecar about it: the JVM
    /// may be gone, and the next connect() will create a fresh session.
    private func resetConnection() {
        tunnel?.stop()
        tunnel = nil
        connId = nil
        isConnected = false
    }

    func fetch(_ queryId: String, count: Int = 500) async throws -> (rows: [[String?]], done: Bool) {
        let res = try await SidecarClient.shared.call("fetch", ["queryId": queryId, "count": count])
        return (Self.rows(from: res["rows"]), res["done"] as? Bool ?? true)
    }

    /// Total row count for a result, computed on a separate connection so the
    /// paging cursor of the main query can stay open.
    func countRows(_ sql: String, params: [String: Any] = [:]) async throws -> Int {
        try await connect()
        guard let connId else { throw SidecarError(message: "Нет соединения") }
        let res = try await SidecarClient.shared.call("count", [
            "connId": connId,
            "sql": sql,
            "kind": profile.kind.rawValue,
            "params": params
        ])
        return (res["count"] as? NSNumber)?.intValue ?? 0
    }

    /// Ordered primary-key column names for a table. Used to build WHERE
    /// clauses when edited cells are written back.
    func primaryKeys(catalog: String, schema: String, table: String) async throws -> [String] {
        try await connect()
        guard let connId else { throw SidecarError(message: "Нет соединения") }
        let res = try await SidecarClient.shared.call("primaryKeys", [
            "connId": connId,
            "catalog": catalog,
            "schema": schema,
            "table": table
        ])
        return (res["columns"] as? [String]) ?? []
    }

    /// Column metadata for tooltips: types, sizes, nullability and primary key.
    func tableMeta(catalog: String, schema: String, table: String) async throws -> TableMeta {
        try await connect()
        guard let connId else { throw SidecarError(message: "Нет соединения") }
        let res = try await SidecarClient.shared.call("tableMeta", [
            "connId": connId,
            "catalog": catalog,
            "schema": schema,
            "table": table
        ])
        let rawColumns = res["columns"] as? [[String: Any]] ?? []
        let columns = rawColumns.map { raw -> TableMetaColumn in
            let size = (raw["size"] as? NSNumber)?.intValue
            return TableMetaColumn(
                name: raw["name"] as? String ?? "",
                type: raw["type"] as? String ?? "",
                size: size,
                nullable: raw["nullable"] as? Bool ?? true,
                primary: raw["primary"] as? Bool ?? false
            )
        }
        return TableMeta(
            columns: columns,
            primaryKey: res["primaryKey"] as? [String] ?? [],
            primaryKeyName: res["primaryKeyName"] as? String
        )
    }

    /// Applies edited rows as UPDATE/INSERT statements and returns the
    /// affected counts.
    func updateRows(catalog: String, schema: String, table: String,
                    updates: [[String: Any]], inserts: [[String: Any]]) async throws -> (updated: Int, inserted: Int) {
        try await connect()
        guard let connId else { throw SidecarError(message: "Нет соединения") }
        let res = try await SidecarClient.shared.call("updateRows", [
            "connId": connId,
            "catalog": catalog,
            "schema": schema,
            "table": table,
            "updates": updates,
            "inserts": inserts
        ])
        return ((res["updated"] as? NSNumber)?.intValue ?? 0,
                (res["inserted"] as? NSNumber)?.intValue ?? 0)
    }

    /// Cancels whatever statement is currently executing on this connection.
    /// Used when the stop button is pressed before the first page has arrived.
    func cancelConnection() {
        guard let connId else { return }
        Task {
            _ = try? await SidecarClient.shared.call("cancelConn", ["connId": connId])
        }
    }

    func cancel(_ queryId: String) {
        Task { _ = try? await SidecarClient.shared.call("cancel", ["queryId": queryId]) }
    }

    func closeCursor(_ queryId: String) {
        Task { _ = try? await SidecarClient.shared.call("closeCursor", ["queryId": queryId]) }
    }

    func disconnect() {
        if let connId {
            Task { _ = try? await SidecarClient.shared.call("disconnect", ["connId": connId]) }
        }
        tunnel?.stop()
        tunnel = nil
        connId = nil
        isConnected = false
    }

    static func columns(from res: [String: Any]) -> [ColumnInfo] {
        let raw = res["columns"] as? [[String: Any]] ?? []
        return raw.enumerated().map { idx, c in
            ColumnInfo(
                index: idx,
                name: c["name"] as? String ?? "col\(idx + 1)",
                type: c["type"] as? String ?? "",
                className: c["className"] as? String ?? "",
                table: c["table"] as? String ?? "",
                schema: c["schema"] as? String ?? "",
                catalog: c["catalog"] as? String ?? ""
            )
        }
    }

    static func rows(from any: Any?) -> [[String?]] {
        guard let raw = any as? [[Any]] else { return [] }
        return raw.map { row in
            row.map { value in
                if value is NSNull { return nil }
                if let s = value as? String { return s }
                if let n = value as? NSNumber { return n.stringValue }
                return String(describing: value)
            }
        }
    }
}
