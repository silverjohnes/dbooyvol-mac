import Foundation

/// Contents of an Oracle `network/admin` directory, reduced to what the
/// JDBC thin driver can actually use.
struct OracleNetConfig: Equatable {
    var ldapHost: String = ""
    var ldapPort: Int = 389
    var ldapContext: String = ""
    /// "RADIUS", "KERBEROS5", ... as written in sqlnet.ora.
    var authServices: String = ""
    /// NAMES.DIRECTORY_PATH, e.g. ["LDAP", "TNSNAMES", "EZCONNECT"].
    var directoryPath: [String] = []
    var sqlnetFound = false
    var ldapFound = false
    var tnsnamesFound = false

    var isEmpty: Bool {
        ldapHost.isEmpty && ldapContext.isEmpty && authServices.isEmpty && directoryPath.isEmpty
    }
}

enum OracleConfigReader {
    static func expand(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    static func read(directory: String) -> OracleNetConfig {
        var config = OracleNetConfig()
        let dir = expand(directory)
        guard !dir.isEmpty else { return config }

        let sqlnet = (dir as NSString).appendingPathComponent("sqlnet.ora")
        let ldap = (dir as NSString).appendingPathComponent("ldap.ora")
        let tnsnames = (dir as NSString).appendingPathComponent("tnsnames.ora")

        if let text = try? String(contentsOfFile: sqlnet, encoding: .utf8) {
            config.sqlnetFound = true
            applySQlnet(text, to: &config)
        }
        if let text = try? String(contentsOfFile: ldap, encoding: .utf8) {
            config.ldapFound = true
            applyLdap(text, to: &config)
        }
        config.tnsnamesFound = FileManager.default.fileExists(atPath: tnsnames)
        return config
    }

    /// First ojdbc*.jar in an Instant Client folder (thin driver is enough).
    static func jdbcJar(in directory: String) -> String? {
        let dir = expand(directory)
        guard !dir.isEmpty else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let jars = names
            .filter { $0.lowercased().hasPrefix("ojdbc") && $0.lowercased().hasSuffix(".jar") }
            .sorted()
        return jars.first.map { (dir as NSString).appendingPathComponent($0) }
    }

    static func networkAdmin(in directory: String) -> String? {
        let dir = expand(directory)
        guard !dir.isEmpty else { return nil }
        let candidate = (dir as NSString).appendingPathComponent("network/admin")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return candidate
    }

    // MARK: - parsers

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { raw in
            let noComment = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return String(noComment).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func applySQlnet(_ text: String, to config: inout OracleNetConfig) {
        for line in lines(text) where !line.isEmpty {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            if key == "NAMES.DIRECTORY_PATH" {
                config.directoryPath = listValues(value)
            } else if key == "SQLNET.AUTHENTICATION_SERVICES" {
                let values = listValues(value)
                config.authServices = values.joined(separator: ",")
            }
        }
    }

    private static func applyLdap(_ text: String, to config: inout OracleNetConfig) {
        for line in lines(text) where !line.isEmpty {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            if key == "DEFAULT_ADMIN_CONTEXT" {
                config.ldapContext = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            } else if key == "DIRECTORY_SERVERS" {
                var servers = value.trimmingCharacters(in: .whitespaces)
                if servers.hasPrefix("(") { servers.removeFirst() }
                if servers.hasSuffix(")") { servers.removeLast() }
                let first = servers.split(separator: ",").first.map(String.init) ?? servers
                let pair = first.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                }
                if let host = pair.first, !host.isEmpty {
                    config.ldapHost = host
                    if pair.count > 1, let port = Int(pair[1]) { config.ldapPort = port }
                }
            }
        }
    }

    /// `(LDAP,TNSNAMES, EZCONNECT)` -> ["LDAP", "TNSNAMES", "EZCONNECT"]
    private static func listValues(_ raw: String) -> [String] {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("(") { value.removeFirst() }
        if value.hasSuffix(")") { value.removeLast() }
        return value
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).uppercased() }
            .filter { !$0.isEmpty }
    }
}
