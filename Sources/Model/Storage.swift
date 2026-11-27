import Foundation
import Security
import LocalAuthentication
import CryptoKit
import AppKit

enum AppPaths {
    /// Created once. On the first launch after a rename, the previous data
    /// folder is moved so profiles, tabs, history and secrets survive.
    static let support: URL = {
        let fm = FileManager.default
        // Isolated profile for UI/DB tests; never used by a normal launch.
        if let override = ProcessInfo.processInfo.environment["DBOOYVOL_SUPPORT_DIR"],
           !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("DBooyvol", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            for legacyName in ["DBuiwol", "SQLDesk"] {
                let legacy = base.appendingPathComponent(legacyName, isDirectory: true)
                if fm.fileExists(atPath: legacy.path) {
                    try? fm.moveItem(at: legacy, to: dir)
                    break
                }
            }
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }()

    static var profiles: URL { support.appendingPathComponent("profiles.json") }
    static var tabs: URL { support.appendingPathComponent("tabs.json") }
    static var columnWidths: URL { support.appendingPathComponent("columnWidths.json") }
    static var history: URL { support.appendingPathComponent("history.jsonl") }
    static var exports: URL { support.appendingPathComponent("exports", isDirectory: true) }
    /// Encrypted passwords (id → enc2:<keyid>:…), nothing readable.
    static var secrets: URL { support.appendingPathComponent("secrets.json") }
    /// Old master-key file from the machine-UUID scheme. Deleted on launch;
    /// the master key now lives in the macOS Keychain.
    static var masterKey: URL { support.appendingPathComponent(".master.key") }

    /// Files written by older builds used the default 0644. Fix them once at
    /// launch, before any of them is rewritten.
    static func tightenPermissions() {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        let files = [
            profiles, tabs, columnWidths, history, secrets, masterKey,
            support.appendingPathComponent("profiles.bak.json")
        ]
        for url in files where fm.fileExists(atPath: url.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

/// Writes app data with owner-only permissions from the first byte. Foundation's
/// atomic write creates a 0644 temporary file and only chmods after the rename,
/// so a crash in between could leave secrets readable by other users.
enum PrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil,
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: tmp)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    static func write(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try write(data, to: url)
    }

    static func append(_ data: Data, to url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try write(data, to: url)
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }
}

enum AppSettings {
    /// Bundle identifier used before the move to `silver.dbooyvol`. Kept only
    /// to import the old UserDefaults domain once.
    static let previousDefaultsDomain = "ru.evotor.sqldesk"
    private static let defaultsMigrationKey = "defaultsMigrated"
    private static let legacyMigrationKey = "defaultsMigratedFrom"

    /// macOS keys UserDefaults by bundle identifier. Without this, changing the
    /// identifier would reset the language, fonts, tree state, window frames
    /// and every other preference. Runs before the language is applied.
    static func migrateDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: defaultsMigrationKey) { return }
        // Older builds recorded the old domain name in the new preferences.
        // Drop it so the old identifier is not left behind anywhere.
        if defaults.string(forKey: legacyMigrationKey) != nil {
            defaults.removeObject(forKey: legacyMigrationKey)
            defaults.set(true, forKey: defaultsMigrationKey)
            return
        }
        defer { defaults.set(true, forKey: defaultsMigrationKey) }
        guard let old = defaults.persistentDomain(forName: previousDefaultsDomain),
              !old.isEmpty else { return }
        for (key, value) in old where key != defaultsMigrationKey {
            // Never overwrite a value the new identifier has already written.
            if defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }

    static let sshDirectoryKey = "sshDirectory"
    static let javaPathKey = "javaPath"
    static let autosaveTabsKey = "autosaveTabs"
    static let editorFontSizeKey = "editorFontSize"
    static let resultFontNameKey = "resultFontName"
    static let resultFontSizeKey = "resultFontSize"
    static let autoColumnWidthsKey = "autoColumnWidths"
    static let maxAutoColumnWidthKey = "maxAutoColumnWidth"
    static let pageSizeKey = "pageSize"
    static let historyRetentionDaysKey = "historyRetentionDays"
    static let showTypeInHeaderKey = "showTypeInColumnHeader"
    static let showTypeOnHeaderHoverKey = "showTypeOnHeaderHover"
    static let smartSelectionKey = "smartSelection"
    static let smartSelectionOnlyInSearchKey = "smartSelectionOnlyInSearch"
    static let commentByMarkerKey = "commentByMarker"
    static let commentMarkerSuffixKey = "commentMarkerSuffix"
    /// The `--` prefix is fixed; this is the part after it.
    static let defaultCommentMarkerSuffix = "!#"
    static let timeZoneKey = "displayTimeZone"
    static let checkExternalChangesKey = "checkExternalChanges"
    static let selectedProfileIDKey = "selectedProfileID"
    static func treeExpandedKey(_ id: UUID) -> String { "treeExpanded.\(id.uuidString)" }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            sshDirectoryKey: "/Users/silver/.ssh",
            javaPathKey: "/usr/bin/java",
            autosaveTabsKey: true,
            editorFontSizeKey: 14.0,
            resultFontNameKey: "",
            resultFontSizeKey: 12.0,
            autoColumnWidthsKey: true,
            maxAutoColumnWidthKey: 280.0,
            pageSizeKey: 200,
            historyRetentionDaysKey: 30,
            showTypeInHeaderKey: false,
            showTypeOnHeaderHoverKey: true,
            smartSelectionKey: false,
            smartSelectionOnlyInSearchKey: false,
            commentByMarkerKey: true,
            commentMarkerSuffixKey: "!#",
            timeZoneKey: "",
            checkExternalChangesKey: false
        ])
    }

    static var autoColumnWidths: Bool {
        // The property initializer of AppModel runs before registerDefaults(),
        // so an unset key must still mean "on".
        get { UserDefaults.standard.object(forKey: autoColumnWidthsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoColumnWidthsKey) }
    }

    static var maxAutoColumnWidth: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: maxAutoColumnWidthKey)
            return value > 0 ? CGFloat(value) : 280
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: maxAutoColumnWidthKey) }
    }

    static var pageSize: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: pageSizeKey)
            return value > 0 ? value : 200
        }
        set { UserDefaults.standard.set(newValue, forKey: pageSizeKey) }
    }

    /// Days of query history to keep; 0 means forever. An unset key means the
    /// default of one month, because property initializers run before
    /// `registerDefaults()`.
    static var historyRetentionDays: Int {
        get {
            guard let value = UserDefaults.standard.object(forKey: historyRetentionDaysKey) as? Int else {
                return 30
            }
            return max(0, value)
        }
        set { UserDefaults.standard.set(max(0, newValue), forKey: historyRetentionDaysKey) }
    }

    static var showTypeInColumnHeader: Bool {        // Unset means "off": the type is shown on hover by default.
        get { UserDefaults.standard.object(forKey: showTypeInHeaderKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: showTypeInHeaderKey) }
    }

    static var showTypeOnHeaderHover: Bool {
        // Unset means "on".
        get { UserDefaults.standard.object(forKey: showTypeOnHeaderHoverKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showTypeOnHeaderHoverKey) }
    }

    /// Whether the separate shortcut comments lines ending with the marker.
    /// On by default: it only touches lines the user explicitly marked.
    static var commentByMarker: Bool {
        get { UserDefaults.standard.object(forKey: commentByMarkerKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: commentByMarkerKey) }
    }

    /// The editable part of the marker; `--` is always prepended.
    static var commentMarkerSuffix: String {
        get { UserDefaults.standard.string(forKey: commentMarkerSuffixKey) ?? defaultCommentMarkerSuffix }
        set { UserDefaults.standard.set(newValue, forKey: commentMarkerSuffixKey) }
    }

    static var resultFontName: String {
        get { UserDefaults.standard.string(forKey: resultFontNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: resultFontNameKey) }
    }

    /// Time zone used to display timestamp columns. Empty means the system
    /// zone; an unset key must also mean the system zone, because property
    /// initializers run before `registerDefaults()`.
    static var timeZoneIdentifier: String {
        get { UserDefaults.standard.string(forKey: timeZoneKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: timeZoneKey) }
    }

    /// Whether open files are compared with their disk contents. Off by
    /// default: the comparison reads files every couple of seconds and can
    /// interrupt with a conflict dialog.
    static var checkExternalChanges: Bool {
        get { UserDefaults.standard.object(forKey: checkExternalChangesKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: checkExternalChangesKey) }
    }

    static var resultFontSize: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: resultFontSizeKey)
            return value > 0 ? CGFloat(value) : 12
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: resultFontSizeKey) }
    }

    static var editorFontSize: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: editorFontSizeKey)
            return value > 0 ? CGFloat(value) : 14
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: editorFontSizeKey) }
    }

    static var autosaveTabs: Bool {
        UserDefaults.standard.bool(forKey: autosaveTabsKey)
    }

    static var selectedProfileID: UUID? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: selectedProfileIDKey) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: selectedProfileIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedProfileIDKey)
            }
        }
    }

    static func expandedTreeItems(for profileID: UUID) -> Set<String> {
        let raw = UserDefaults.standard.stringArray(forKey: treeExpandedKey(profileID)) ?? []
        return Set(raw)
    }

    /// False until the user expands or collapses something for this profile.
    /// The tree then opens connections by default instead of staying collapsed.
    static func hasTreeState(for profileID: UUID) -> Bool {
        UserDefaults.standard.object(forKey: treeExpandedKey(profileID)) != nil
    }

    static func setExpandedTreeItems(_ items: Set<String>, for profileID: UUID) {
        UserDefaults.standard.set(Array(items), forKey: treeExpandedKey(profileID))
    }

    static func treeCollapsedConnectionsKey(_ id: UUID) -> String {
        "treeCollapsedConnections.\(id.uuidString)"
    }

    /// Connections the user explicitly closed. Kept separately from the
    /// expanded-item set: an empty expanded set alone cannot distinguish
    /// "never opened" from "deliberately collapsed".
    static func collapsedConnections(for profileID: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: treeCollapsedConnectionsKey(profileID)) ?? [])
    }

    static func setCollapsedConnections(_ items: Set<String>, for profileID: UUID) {
        UserDefaults.standard.set(Array(items), forKey: treeCollapsedConnectionsKey(profileID))
    }

    static func markConnectionCollapsed(_ nodeID: String, for profileID: UUID) {
        var items = collapsedConnections(for: profileID)
        items.insert(nodeID)
        setCollapsedConnections(items, for: profileID)
    }

    static func markConnectionExpanded(_ nodeID: String, for profileID: UUID) {
        var items = collapsedConnections(for: profileID)
        guard items.remove(nodeID) != nil else { return }
        setCollapsedConnections(items, for: profileID)
    }

    static var sshDirectory: String {
        get { UserDefaults.standard.string(forKey: sshDirectoryKey) ?? "/Users/silver/.ssh" }
        set { UserDefaults.standard.set(newValue, forKey: sshDirectoryKey) }
    }

    static var javaPath: String {
        get { UserDefaults.standard.string(forKey: javaPathKey) ?? "/usr/bin/java" }
        set { UserDefaults.standard.set(newValue, forKey: javaPathKey) }
    }

    /// ssh config file: explicit path if it is a file, otherwise <dir>/config when present.
    static var sshConfigPath: String? {
        let dir = (sshDirectory as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
            if isDir.boolValue {
                let candidate = (dir as NSString).appendingPathComponent("config")
                return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
            }
            return dir
        }
        return nil
    }
}

/// Passwords are encrypted with AES-256-GCM and stored in `secrets.json`.
/// The 256-bit master key lives in the macOS Keychain, so a copy of the data
/// folder is useless without the login keychain. Entries record the key id
/// (`enc2:<id>:…`), so a stale key is reported instead of silently failing.
enum SecretStoreError: LocalizedError {
    case keychainUnavailable(OSStatus)
    case accessDenied
    case cancelled
    case keyMissing
    case wrongKey
    case corrupted

    var errorDescription: String? {
        switch self {
        case .keychainUnavailable(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            return L10n.fmt("Не удалось открыть связку ключей macOS: %@", detail)
        case .accessDenied:
            return L10n.tr("Доступ к сохранённым паролям не разрешён")
        case .cancelled:
            return L10n.tr("Ввод пароля отменён")
        case .keyMissing:
            return L10n.tr("Мастер-ключ не найден в связке ключей — введите пароли заново")
        case .wrongKey:
            return L10n.tr("Пароль сохранён другим мастер-ключом — введите его заново")
        case .corrupted:
            return L10n.tr("Не удалось расшифровать сохранённый пароль — введите его заново")
        }
    }
}

enum SecretStore {
    private static let keychainService = "silver.dbooyvol.secret-store"
    private static let keychainAccount = "master-key-v2"
    private static let prefix = "enc2:"
    private static let lock = NSRecursiveLock()
    private static var cachedMaster: SymmetricKey?
    private static var cachedSecrets: [String: String]?
    /// One Touch ID / login-password confirmation per app run.
    private static var authenticated = false
    private static let authLock = NSLock()

    // MARK: - Touch ID / system authentication

    /// Asks macOS to confirm the user's presence once per run. On a Mac with
    /// Touch ID this is the fingerprint prompt; otherwise macOS falls back to
    /// the login password. The Keychain item keeps its own protection, so a
    /// copy of the data folder is still useless without the login keychain.
    static func authenticate(reason: String) async throws {
        if isAuthenticated() { return }

        let context = LAContext()
        context.localizedCancelTitle = L10n.tr("Отмена")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No Touch ID and no password set: do not block the app.
            markAuthenticated()
            return
        }
        do {
            let ok = try await evaluate(context, reason: reason)
            guard ok else { throw SecretStoreError.accessDenied }
            markAuthenticated()
        } catch {
            if let la = error as? LAError,
               [.userCancel, .appCancel, .systemCancel].contains(la.code) {
                throw SecretStoreError.cancelled
            }
            throw SecretStoreError.accessDenied
        }
    }

    private static func isAuthenticated() -> Bool {
        authLock.lock()
        defer { authLock.unlock() }
        return authenticated
    }

    private static func markAuthenticated() {
        authLock.lock()
        authenticated = true
        authLock.unlock()
    }

    private static func evaluate(_ context: LAContext, reason: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    // MARK: - master key (Keychain)

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private enum KeychainRead {
        case success(Data)
        case notFound
        case failed(OSStatus)
    }

    private static func keychainLoad(interactive: Bool) -> KeychainRead {
        var query = baseQuery()
        let context = LAContext()
        if interactive {
            context.localizedReason = L10n.tr("Разрешить DBooyvol доступ к сохранённым паролям")
        } else {
            context.interactionNotAllowed = true
        }
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess else { return .failed(status) }
        guard let data = item as? Data, data.count == 32 else { return .failed(errSecDecode) }
        return .success(data)
    }

    private static func keychainAdd(_ raw: Data) -> OSStatus {
        var add = baseQuery()
        add[kSecValueData as String] = raw
        add[kSecAttrLabel as String] = "DBooyvol master key"
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// Only an explicit rotation may replace an existing key. Normal access
    /// never overwrites the item: a failed read must ask the user, not destroy
    /// the key that still decrypts the saved passwords.
    private static func keychainReplace(_ raw: Data) -> OSStatus {
        let attrs: [String: Any] = [kSecValueData as String: raw]
        return SecItemUpdate(baseQuery() as CFDictionary, attrs as CFDictionary)
    }

    private static func isAuthFailure(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed
            || status == errSecInteractionNotAllowed
            || status == errSecUserCanceled
            || status == errSecNotAvailable
    }

    private static func masterKey(createIfMissing: Bool) throws -> SymmetricKey {
        if let cachedMaster { return cachedMaster }

        let raw: Data
        switch keychainLoad(interactive: true) {
        case .success(let data):
            raw = data
        case .notFound:
            guard createIfMissing else { throw SecretStoreError.keyMissing }
            let key = SymmetricKey(size: .bits256)
            let newRaw = key.withUnsafeBytes { Data($0) }
            let status = keychainAdd(newRaw)
            if status == errSecSuccess {
                cachedMaster = key
                return key
            }
            if status == errSecDuplicateItem {
                // Another instance created it between the read and the add.
                switch keychainLoad(interactive: true) {
                case .success(let data): raw = data
                case .notFound: throw SecretStoreError.keyMissing
                case .failed(let readStatus):
                    throw isAuthFailure(readStatus)
                        ? SecretStoreError.accessDenied
                        : SecretStoreError.keychainUnavailable(readStatus)
                }
            } else if isAuthFailure(status) {
                throw SecretStoreError.accessDenied
            } else {
                throw SecretStoreError.keychainUnavailable(status)
            }
        case .failed(let status):
            if isAuthFailure(status) { throw SecretStoreError.accessDenied }
            if status == errSecDecode { throw SecretStoreError.corrupted }
            throw SecretStoreError.keychainUnavailable(status)
        }

        let key = SymmetricKey(data: raw)
        cachedMaster = key
        return key
    }

    private static func keyID(_ key: SymmetricKey) -> String {
        let raw = key.withUnsafeBytes { Data($0) }
        let digest = SHA256.hash(data: raw)
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - files

    private static func secrets() -> [String: String] {
        if let cachedSecrets { return cachedSecrets }
        var map: [String: String] = [:]
        if let data = try? Data(contentsOf: AppPaths.secrets),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            map = decoded
        }
        cachedSecrets = map
        return map
    }

    private static func persist(_ map: [String: String]) throws {
        let data = try JSONEncoder().encode(map)
        try PrivateFile.write(data, to: AppPaths.secrets)
        PrivateFile.excludeFromBackup(AppPaths.secrets)
        cachedSecrets = map
    }

    // MARK: - crypto

    private static func encrypt(_ plaintext: String, using key: SymmetricKey) throws -> String {
        guard !plaintext.isEmpty else { return "" }
        guard let data = plaintext.data(using: .utf8),
              let sealed = try? AES.GCM.seal(data, using: key),
              let combined = sealed.combined else { throw SecretStoreError.corrupted }
        return prefix + keyID(key) + ":" + combined.base64EncodedString()
    }

    private static func decrypt(_ stored: String, using key: SymmetricKey) throws -> String {
        guard stored.hasPrefix(prefix) else { throw SecretStoreError.corrupted }
        let rest = stored.dropFirst(prefix.count)
        guard let separator = rest.firstIndex(of: ":") else { throw SecretStoreError.corrupted }
        let storedID = String(rest[..<separator])
        guard storedID == keyID(key) else { throw SecretStoreError.wrongKey }
        let payload = String(rest[rest.index(after: separator)...])
        guard let data = Data(base64Encoded: payload),
              let box = try? AES.GCM.SealedBox(combined: data),
              let clear = try? AES.GCM.open(box, using: key),
              let text = String(data: clear, encoding: .utf8) else {
            throw SecretStoreError.corrupted
        }
        return text
    }

    // MARK: - public

    static func save(_ password: String, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var map = secrets()
        if password.isEmpty {
            map.removeValue(forKey: account)
        } else {
            // Create the master key only on the very first save. If other
            // passwords already exist, a missing key means the ciphertext is
            // stale: ask the user to re-enter instead of silently replacing
            // the key and making every other password unreadable.
            let key = try masterKey(createIfMissing: map.isEmpty)
            map[account] = try encrypt(password, using: key)
        }
        try persist(map)
    }

    static func load(_ account: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = secrets()[account], !stored.isEmpty else { return "" }
        return try decrypt(stored, using: try masterKey(createIfMissing: false))
    }

    // MARK: - stale key detection

    private static func storedKeyID(_ stored: String) -> String? {
        guard stored.hasPrefix(prefix) else { return nil }
        let rest = stored.dropFirst(prefix.count)
        guard let separator = rest.firstIndex(of: ":") else { return nil }
        return String(rest[..<separator])
    }

    /// Accounts whose ciphertext was written with a key that is not the
    /// current master key. Used to show one bulk re-entry dialog instead of a
    /// separate failure for every connection.
    static func staleAccounts(_ accounts: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let map = secrets()
        let key: SymmetricKey
        do {
            key = try masterKey(createIfMissing: false)
        } catch SecretStoreError.keyMissing {
            return accounts.filter { account in
                guard let stored = map[account] else { return false }
                return stored.hasPrefix(prefix)
            }
        } catch {
            // Access denied or keychain unavailable: do not claim the data is
            // stale; the normal load path will ask for access.
            return []
        }
        let current = keyID(key)
        return accounts.filter { account in
            guard let stored = map[account], let storedID = storedKeyID(stored) else { return false }
            return storedID != current
        }
    }

    static func hasStaleSecrets(_ accounts: [String]) -> Bool {
        !staleAccounts(accounts).isEmpty
    }

    /// Diagnostics for the `--secrets-status` dev aid. Never returns key bytes.
    static func diagnostics(accounts: [String]) -> (keyID: String?, stale: [String], error: String?) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let key = try masterKey(createIfMissing: false)
            return (keyID(key), staleAccounts(accounts), nil)
        } catch {
            return (nil, [], error.localizedDescription)
        }
    }

    static func delete(_ account: String) {
        lock.lock()
        defer { lock.unlock() }
        var map = secrets()
        guard map.removeValue(forKey: account) != nil else { return }
        try? persist(map)
    }

    /// Removes data from the old machine-UUID scheme. Passwords are expected to
    /// be re-entered once after the switch to the Keychain master key.
    static func purgeLegacy() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: AppPaths.masterKey)
        purgeLegacyKeychain()
        let map = secrets()
        let kept = map.filter { $0.value.hasPrefix(prefix) }
        guard kept.count != map.count else { return }
        try? persist(kept)
    }

    /// Removes items written under the old service name. They held plaintext
    /// passwords, so they must not stay in the login keychain. The automatic
    /// attempt never shows a dialog; the Settings button retries with one.
    @discardableResult
    static func deleteLegacyKeychain(interactive: Bool = true) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ru.evotor.sqldesk"
        ]
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func purgeLegacyKeychain() {
        deleteLegacyKeychain(interactive: false)
    }

    /// Re-encrypts every stored password with a fresh random master key. The
    /// old key is restored if writing the new file fails.
    static func rotateMasterKey() throws {
        lock.lock()
        defer { lock.unlock() }
        let oldKey = try masterKey(createIfMissing: false)
        var plain: [String: String] = [:]
        for (account, stored) in secrets() where !stored.isEmpty {
            plain[account] = try decrypt(stored, using: oldKey)
        }
        let newKey = SymmetricKey(size: .bits256)
        var reencrypted: [String: String] = [:]
        for (account, password) in plain {
            reencrypted[account] = try encrypt(password, using: newKey)
        }
        let oldRaw = oldKey.withUnsafeBytes { Data($0) }
        let newRaw = newKey.withUnsafeBytes { Data($0) }
        var status = keychainReplace(newRaw)
        if status == errSecItemNotFound { status = keychainAdd(newRaw) }
        guard status == errSecSuccess else {
            throw isAuthFailure(status)
                ? SecretStoreError.accessDenied
                : SecretStoreError.keychainUnavailable(status)
        }
        do {
            try persist(reencrypted)
        } catch {
            _ = keychainReplace(oldRaw)
            throw error
        }
        cachedMaster = newKey
    }
}

final class ProfilesStore {
    static var backupURL: URL {
        AppPaths.support.appendingPathComponent("profiles.bak.json")
    }

    static func load() -> [ConnectionProfile] {
        if let data = try? Data(contentsOf: AppPaths.profiles),
           let profiles = try? JSONDecoder().decode([ConnectionProfile].self, from: data) {
            return profiles
        }
        // fall back to the previous version if the main file is missing or broken
        if let data = try? Data(contentsOf: backupURL),
           let profiles = try? JSONDecoder().decode([ConnectionProfile].self, from: data) {
            try? PrivateFile.write(data, to: AppPaths.profiles)
            return profiles
        }
        return []
    }

    static func save(_ profiles: [ConnectionProfile]) {
        // keep the previous revision, so a bad save never loses every connection
        if let existing = try? Data(contentsOf: AppPaths.profiles) {
            try? PrivateFile.write(existing, to: backupURL)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(profiles) else { return }
        try? PrivateFile.write(data, to: AppPaths.profiles)
    }
}

/// Ready-made depths for the history retention setting. A custom value is
/// still possible in UserDefaults, but the UI only offers sensible steps.
enum HistoryRetention: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90
    case halfYear = 180
    case year = 365
    case forever = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .week: return L10n.tr("1 неделя")
        case .month: return L10n.tr("1 месяц")
        case .quarter: return L10n.tr("3 месяца")
        case .halfYear: return L10n.tr("6 месяцев")
        case .year: return L10n.tr("1 год")
        case .forever: return L10n.tr("Бессрочно")
        }
    }
}

/// Append-only history file with a retention period. Old entries are dropped
/// from memory on load and the file is compacted in the background, so a long
/// history does not keep deleted rows on disk.
final class HistoryStore {
    private let queue = DispatchQueue(label: "history.store")
    private(set) var entries: [HistoryEntry] = []
    private var retentionDays: Int

    init(retentionDays: Int = AppSettings.historyRetentionDays) {
        self.retentionDays = retentionDays
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.history),
              let text = String(data: data, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var loaded: [HistoryEntry] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let e = try? dec.decode(HistoryEntry.self, from: d) else { continue }
            loaded.append(e)
        }
        entries = loaded.suffix(2000).reversed()
        if pruneMemory() {
            rewriteFile()
        }
    }

    func append(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 2000 { entries.removeLast(entries.count - 2000) }
        queue.async { [entry] in
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(entry),
                  let line = String(data: data, encoding: .utf8) else { return }
            try? PrivateFile.append(Data((line + "\n").utf8), to: AppPaths.history)
        }
    }

    /// Applies a new depth immediately. Shortening the period deletes old
    /// entries right away; lengthening it cannot bring deleted ones back.
    func setRetention(days: Int) {
        retentionDays = max(0, days)
        if pruneMemory() {
            rewriteFile()
        }
    }

    func clear() {
        entries = []
        queue.async {
            try? FileManager.default.removeItem(at: AppPaths.history)
        }
    }

    /// Returns true when anything was removed.
    private func pruneMemory() -> Bool {
        guard retentionDays > 0 else { return false }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let before = entries.count
        entries.removeAll { $0.date < cutoff }
        return entries.count != before
    }

    /// Replaces the append-only file with the retained entries, oldest first,
    /// so the next append still goes to the end.
    private func rewriteFile() {
        let snapshot = Array(entries.reversed())
        queue.async {
            guard !snapshot.isEmpty else {
                try? FileManager.default.removeItem(at: AppPaths.history)
                return
            }
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            var text = ""
            for entry in snapshot {
                guard let data = try? enc.encode(entry),
                      let line = String(data: data, encoding: .utf8) else { continue }
                text += line + "\n"
            }
            try? PrivateFile.write(text, to: AppPaths.history)
        }
    }
}

struct TabsSnapshot: Codable {
    var tabs: [QueryTab]
    var activeID: UUID?
}

final class TabsStore {    static func load() -> TabsSnapshot? {
        guard let data = try? Data(contentsOf: AppPaths.tabs) else { return nil }
        return try? JSONDecoder().decode(TabsSnapshot.self, from: data)
    }

    static func save(_ snapshot: TabsSnapshot) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(snapshot) else { return }
        try? PrivateFile.write(data, to: AppPaths.tabs)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: AppPaths.tabs)
    }
}

/// Fixed-pitch fonts offered for the result grid.
enum ResultFontCatalog {
    /// One selectable entry per installed font family. The stored value is the
    /// PostScript name of the family's regular face.
    struct Entry: Identifiable, Hashable {
        let family: String
        let postScriptName: String

        var id: String { postScriptName }
    }

    /// Every font family installed on this Mac, alphabetically. Each family is
    /// represented by its regular face (or its first face when there is no
    /// explicit regular style).
    static let entries: [Entry] = {
        let manager = NSFontManager.shared
        var seen = Set<String>()
        var result: [Entry] = []
        for family in manager.availableFontFamilies {
            guard let members = manager.availableMembers(ofFontFamily: family) else { continue }
            let regular = members.first { member in
                guard member.count > 1, let style = member[1] as? String else { return false }
                return style.caseInsensitiveCompare("Regular") == .orderedSame
                    || style.caseInsensitiveCompare("Book") == .orderedSame
            }
            guard let chosen = regular ?? members.first,
                  let name = chosen.first as? String,
                  NSFont(name: name, size: 12) != nil,
                  !seen.contains(name) else { continue }
            seen.insert(name)
            result.append(Entry(family: family, postScriptName: name))
        }
        return result.sorted {
            $0.family.localizedCaseInsensitiveCompare($1.family) == .orderedAscending
        }
    }()

    /// PostScript names in the same order as `entries`.
    static let names: [String] = entries.map(\.postScriptName)

    static func displayName(_ postScriptName: String) -> String {
        if let entry = entries.first(where: { $0.postScriptName == postScriptName }) {
            return entry.family
        }
        let font = NSFont(name: postScriptName, size: 12)
        return font?.familyName ?? font?.displayName ?? postScriptName
    }
}

/// Column widths remembered per query name. New columns are added to an existing
/// record; columns that are no longer in the result stay in the file.
final class ColumnWidthStore {
    static let shared = ColumnWidthStore()

    private var records: [String: [String: CGFloat]] = [:]
    private var saveWork: DispatchWorkItem?

    private init() {
        guard let data = try? Data(contentsOf: AppPaths.columnWidths),
              let decoded = try? JSONDecoder().decode([String: [String: Double]].self, from: data) else {
            return
        }
        records = decoded.mapValues { $0.mapValues { CGFloat($0) } }
    }

    func widths(for query: String) -> [String: CGFloat] {
        guard !query.isEmpty else { return [:] }
        return records[query] ?? [:]
    }

    func set(_ width: CGFloat, for column: String, query: String) {
        guard !query.isEmpty, !column.isEmpty, width.isFinite, width > 0 else { return }
        var record = records[query] ?? [:]
        guard abs((record[column] ?? -1) - width) > 0.5 else { return }
        record[column] = width
        records[query] = record
        scheduleSave()
    }

    /// Renaming a query keeps its remembered widths.
    func rename(from old: String, to new: String) {
        guard !old.isEmpty, !new.isEmpty, old != new, let record = records.removeValue(forKey: old) else { return }
        records[new] = (records[new] ?? [:]).merging(record) { current, _ in current }
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes pending width changes immediately (called on app termination).
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        save()
    }

    private func save() {
        let encodable = records.mapValues { $0.mapValues { Double($0) } }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        try? PrivateFile.write(data, to: AppPaths.columnWidths)
    }
}
