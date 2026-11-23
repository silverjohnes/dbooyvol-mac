import Foundation
import Security
import LocalAuthentication
import CryptoKit
import IOKit
import AppKit

enum AppPaths {
    /// Created once. On the first launch after a rename, the previous data
    /// folder is moved so profiles, tabs, history and secrets survive.
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("DBooyvol", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            for legacyName in ["DBuiwol", "SQLDesk"] {
                let legacy = base.appendingPathComponent(legacyName, isDirectory: true)
                if fm.fileExists(atPath: legacy.path) {
                    try? fm.moveItem(at: legacy, to: dir)
                    break
                }
            }
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var profiles: URL { support.appendingPathComponent("profiles.json") }
    static var tabs: URL { support.appendingPathComponent("tabs.json") }
    static var columnWidths: URL { support.appendingPathComponent("columnWidths.json") }
    static var history: URL { support.appendingPathComponent("history.jsonl") }
    static var exports: URL { support.appendingPathComponent("exports", isDirectory: true) }
    /// Encrypted passwords (id → enc1:…), nothing readable.
    static var secrets: URL { support.appendingPathComponent("secrets.json") }
    /// Master key, itself encrypted with a key derived from this Mac's hardware UUID.
    static var masterKey: URL { support.appendingPathComponent(".master.key") }
}

enum AppSettings {
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
            showTypeOnHeaderHoverKey: true
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

    static var resultFontName: String {
        get { UserDefaults.standard.string(forKey: resultFontNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: resultFontNameKey) }
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

enum Keychain {
    private static let service = "ru.evotor.sqldesk"

    /// Reads an item without ever showing the system "wants to access key" dialog.
    /// Used only to migrate data written by older builds; new builds never touch the Keychain.
    static func getSilently(_ account: String) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Never show the access dialog; fail with errSecInteractionNotAllowed instead.
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum MachineID {
    private static var cached: String?

    /// Stable per-machine identifier (IOPlatformUUID); falls back to the host name.
    static var hardwareUUID: String {
        if let cached { return cached }
        var value = ProcessInfo.processInfo.hostName
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let property = IORegistryEntryCreateCFProperty(
                service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
            ), let uuid = property.takeRetainedValue() as? String, !uuid.isEmpty {
                value = uuid
            }
        }
        cached = value
        return value
    }
}

/// Passwords are encrypted with AES-256-GCM and stored in `secrets.json`.
/// The master key lives in `.master.key`, encrypted with a key derived from this Mac's
/// hardware UUID — so the files are useless on another machine. The Keychain is not used
/// anymore, which removes the "DBooyvol wants to access your keychain" prompt after rebuilds.
enum SecretStore {
    private static let legacyMasterAccount = "__master_key_v1__"
    private static let prefix = "enc1:"
    private static let lock = NSRecursiveLock()
    private static var cachedMaster: SymmetricKey?
    private static var cachedSecrets: [String: String]?
    private static var legacyChecked: Set<String> = []

    // MARK: - files

    private static func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func machineKey() -> SymmetricKey {
        let material = Data("ru.evotor.sqldesk|secret-store|v1|\(MachineID.hardwareUUID)".utf8)
        return SymmetricKey(data: Data(SHA256.hash(data: material)))
    }

    private static func masterKey() -> SymmetricKey {
        if let cachedMaster { return cachedMaster }

        if let blob = try? Data(contentsOf: AppPaths.masterKey),
           let box = try? AES.GCM.SealedBox(combined: blob),
           let clear = try? AES.GCM.open(box, using: machineKey()),
           clear.count == 32 {
            let key = SymmetricKey(data: clear)
            cachedMaster = key
            return key
        }

        // One-time migration from the old Keychain item (silent: fails instead of prompting).
        if let legacy = Keychain.getSilently(legacyMasterAccount),
           let data = Data(base64Encoded: legacy), data.count == 32 {
            let key = SymmetricKey(data: data)
            persistMaster(key)
            cachedMaster = key
            return key
        }

        let key = SymmetricKey(size: .bits256)
        persistMaster(key)
        cachedMaster = key
        return key
    }

    private static func persistMaster(_ key: SymmetricKey) {
        let raw = key.withUnsafeBytes { Data($0) }
        guard let sealed = try? AES.GCM.seal(raw, using: machineKey()).combined else { return }
        write(sealed, to: AppPaths.masterKey)
    }

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

    private static func persist(_ map: [String: String]) {
        cachedSecrets = map
        guard let data = try? JSONEncoder().encode(map) else { return }
        write(data, to: AppPaths.secrets)
    }

    // MARK: - crypto

    private static func encrypt(_ plaintext: String) -> String {
        guard !plaintext.isEmpty else { return "" }
        guard let data = plaintext.data(using: .utf8),
              let sealed = try? AES.GCM.seal(data, using: masterKey()),
              let combined = sealed.combined else { return "" }
        return prefix + combined.base64EncodedString()
    }

    private static func decrypt(_ stored: String) -> String {
        guard stored.hasPrefix(prefix) else { return stored }
        let payload = String(stored.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: payload),
              let box = try? AES.GCM.SealedBox(combined: data),
              let clear = try? AES.GCM.open(box, using: masterKey()),
              let text = String(data: clear, encoding: .utf8) else { return "" }
        return text
    }

    // MARK: - public

    static func save(_ password: String, for account: String) {
        lock.lock()
        defer { lock.unlock() }
        var map = secrets()
        if password.isEmpty {
            map.removeValue(forKey: account)
        } else {
            map[account] = encrypt(password)
        }
        persist(map)
    }

    static func load(_ account: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let stored = secrets()[account], !stored.isEmpty {
            return decrypt(stored)
        }

        // Legacy item written by an older build: import it silently, if allowed.
        if !legacyChecked.contains(account) {
            legacyChecked.insert(account)
            if let legacy = Keychain.getSilently(account), !legacy.isEmpty {
                let plain = legacy.hasPrefix(prefix) ? decrypt(legacy) : legacy
                if !plain.isEmpty {
                    var map = secrets()
                    map[account] = encrypt(plain)
                    persist(map)
                    return plain
                }
            }
        }
        return ""
    }

    static func delete(_ account: String) {
        lock.lock()
        defer { lock.unlock() }
        var map = secrets()
        map.removeValue(forKey: account)
        persist(map)
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
            try? data.write(to: AppPaths.profiles, options: .atomic)
            return profiles
        }
        return []
    }

    static func save(_ profiles: [ConnectionProfile]) {
        // keep the previous revision, so a bad save never loses every connection
        if let existing = try? Data(contentsOf: AppPaths.profiles) {
            try? existing.write(to: backupURL, options: .atomic)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(profiles) else { return }
        try? data.write(to: AppPaths.profiles, options: .atomic)
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
            if !FileManager.default.fileExists(atPath: AppPaths.history.path) {
                try? line.appending("\n").write(to: AppPaths.history, atomically: true, encoding: .utf8)
            } else if let handle = try? FileHandle(forWritingTo: AppPaths.history) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            }
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
            try? text.write(to: AppPaths.history, atomically: true, encoding: .utf8)
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
        try? data.write(to: AppPaths.tabs, options: .atomic)
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
        try? data.write(to: AppPaths.columnWidths, options: .atomic)
    }
}
